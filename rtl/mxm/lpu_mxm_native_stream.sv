// One native array per local MXM. Weight bytes and BF16 activation planes
// enter on east-going streams. West-going result planes start at stream 0.
module lpu_mxm_native_stream #(parameter T=4)(
 input wire clk_i,rst_ni,run_i,input wire [4:0] enqueue_i,launch_i,
 input wire [5*128-1:0] payload_i,output wire [4:0] enqueue_ready_o,launch_ready_o,
 input wire [T*32-1:0] east_valid_i,west_valid_i,input wire [T*32*64-1:0] east_data_i,west_data_i,
 output logic [T*32-1:0] east_valid_o,west_valid_o,output logic [T*32*64-1:0] east_data_o,west_data_o,
 output wire fault_o,output logic conflict_o,output wire busy_o);
 wire [T-1:0] cv,rv,bf,lv,pv,dv;
 wire [7*T-1:0] cmd; wire [T*256-1:0] result;
 wire [T*256-1:0] wvalid,wconsume;wire [T*128-1:0] activation;
 wire [T-1:0] av;wire [T*32-1:0] consumed;wire [T-1:0] bad;
 wire [T*32-1:0] read_clash;
 for(genvar t=0;t<T;t++)begin
   wire [5:0] base=cmd[t*7+1+:6];
   assign av[t]=base<31 && east_valid_i[t*32+base[4:0]] && east_valid_i[t*32+5'(base+1)];
   assign bad[t]=cv[t]&&!av[t];
   for(genvar l=0;l<8;l++)assign activation[t*128+l*16+:16]=
     {east_data_i[(t*32+5'(base+1))*64+l*8+:8],east_data_i[(t*32+base[4:0])*64+l*8+:8]};
   for(genvar s=0;s<32;s++)begin
     assign wvalid[(t*32+s)*8+:8]={8{east_valid_i[t*32+s]}};
     wire read_act=cv[t] && av[t] && (s==base || s==base+1);
     assign consumed[t*32+s]=(|wconsume[(t*32+s)*8+:8]) || read_act;
     assign read_clash[t*32+s]=(|wconsume[(t*32+s)*8+:8]) && read_act;
   end
 end
 wire core_fault; wire [2*T-1:0] bank_write,load_word;
 wire [16*T-1:0] load_index; wire [T-1:0] returned;
 lpu_mxm_core #(.ROWS(T),.COLS(T)) u_core(
   .clk_i,.rst_ni,.run_i,.load_enqueue_valid_i(enqueue_i[0]),.load_launch_i(launch_i[0]),.load_instruction_i(payload_i[1:0]),
   .load_enqueue_ready_o(enqueue_ready_o[0]),.load_launch_ready_o(launch_ready_o[0]),
   .param_load_enqueue_valid_i(enqueue_i[1]),.param_load_launch_i(launch_i[1]),.param_load_instruction_i(payload_i[128]),
   .param_load_enqueue_ready_o(enqueue_ready_o[1]),.param_load_launch_ready_o(launch_ready_o[1]),
   .dequant_enqueue_valid_i(enqueue_i[2]),.dequant_launch_i(launch_i[2]),.dequant_instruction_i(payload_i[256]),
   .dequant_enqueue_ready_o(enqueue_ready_o[2]),.dequant_launch_ready_o(launch_ready_o[2]),
   .compute_enqueue_valid_i(enqueue_i[3]),.compute_launch_i(launch_i[3]),.compute_instruction_i(payload_i[384+:7]),
   .compute_enqueue_ready_o(enqueue_ready_o[3]),.compute_launch_ready_o(launch_ready_o[3]),
   .backend_enqueue_valid_i(enqueue_i[4]),.backend_launch_i(launch_i[4]),
   .backend_instruction_i(payload_i[512+:lpu_mxm_backend_isa_pkg::BACKEND_INSTRUCTION_BITS]),
   .backend_enqueue_ready_o(enqueue_ready_o[4]),.backend_launch_ready_o(launch_ready_o[4]),
   .compute_row_valid_o(cv),.compute_row_instruction_o(cmd),.load_row_valid_o(lv),.load_row_index_o(load_index),
   .load_row_instruction_o(load_word),.returned_valid_o(returned),.dequant_row_valid_o(dv),.param_load_row_valid_o(pv),
   .weight_stream_valid_i(wvalid),.weight_stream_i(east_data_i[T*2048-1:0]),.weight_stream_consume_o(wconsume),
   .activation_i(activation),.activation_valid_i(av),.bank_write_o(bank_write),.result_valid_o(rv),.result_bf16_o(bf),.result_o(result),.fault_o(core_fault));
 assign fault_o=core_fault || (|bad);
 always_comb begin
   east_valid_o=east_valid_i & ~consumed;east_data_o=east_data_i;
   west_valid_o=west_valid_i;west_data_o=west_data_i;conflict_o=|read_clash;
   for(int t=0;t<T;t++)for(int p=0;p<4;p++)if(rv[t] && (!bf[t]||p<2))begin
     if(west_valid_o[t*32+p])conflict_o=1;
     else begin west_valid_o[t*32+p]=1;
       for(int l=0;l<8;l++)west_data_o[(t*32+p)*64+l*8+:8]=result[t*256+l*32+p*8+:8];
     end
   end
 end
 // Account for issued work until the last row/column reaches its actual endpoint.
 wire load_finished=lv[T-1] && (load_word[2*(T-1)] || load_index[(T-1)*16+:16]==T*8-1);
 wire [3:0] front_finished={returned[T-1],dv[T-1],pv[T-1],load_finished};
 wire [3*T-1:0] back_finished={rv,bank_write};
 logic [15:0] outstanding;
 always_ff @(posedge clk_i or negedge rst_ni)
   if(!rst_ni)outstanding<=0;
   else outstanding<=outstanding+$countones(launch_i[3:0])+(launch_i[4]?T:0)
                               -$countones(front_finished)-$countones(back_finished);
 // Last dequant beat still crosses the D stages and up to T-1 horizontal links.
 localparam DQ_TAIL=lpu_mxm_config_pkg::WEIGHT_DEQUANT_STAGES+T-1;
 logic [DQ_TAIL-1:0] weight_tail;
 always_ff @(posedge clk_i or negedge rst_ni)
   if(!rst_ni)weight_tail<='0;
   else weight_tail<={weight_tail[DQ_TAIL-2:0],dv[T-1]};
 assign busy_o=outstanding!=0 || (|weight_tail) || (|launch_i);
endmodule
