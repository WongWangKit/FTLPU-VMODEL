// Native image v1: two consecutive 128-bit words per event.
// First: FU payload. Second: {reserved[63:0], auxiliary[31:0], launch_cycle[31:0]}.
module lpu_native_issue_calendar #(
 parameter integer DEPTH=lpu_program_load_pkg::NATIVE_EVENT_DEPTH, PAYLOAD_BITS=128, AUX_BITS=0,
 parameter bit QUEUED=0)(
 input wire clk_i,rst_ni,clear_i,write_i,prime_i,start_i,run_i,
 input wire [16:0] addr_i,input wire [127:0] data_i,input wire [3:0] strb_i,input wire last_i,
 input wire [31:0] cycle_i,input wire enqueue_ready_i,launch_ready_i,
 output wire [127:0] payload_o,output wire [31:0] aux_o,
 output wire enqueue_o,launch_o,ready_o,idle_o,output logic fault_o);
 localparam AW=$clog2(DEPTH);
 logic [PAYLOAD_BITS-1:0] payload[DEPTH]; logic [63:0] schedule[DEPTH];
 logic [AW:0] count,enq,head;
 logic half,sealed_q,primed;
 logic [31:0] previous;
 wire [AW-1:0] ei=enq[AW-1:0],hi=head[AW-1:0];
 assign payload_o=payload[QUEUED?ei:hi];
 assign aux_o=schedule[hi][63:32];
 assign ready_o=(!half && count==0)||primed;
 assign idle_o=!half && head==count;
 // Push the first FIFO entry on accepted START, so cycle zero may launch.
 wire prefetch=QUEUED && primed && (start_i || run_i) && enq<count;
 assign enqueue_o=prefetch && enqueue_ready_i && !fault_o;
 wire due=primed && run_i && head<count && cycle_i==schedule[hi][31:0];
 assign launch_o=due && (!QUEUED || enq>head) && launch_ready_i && !fault_o;
 always_ff @(posedge clk_i or negedge rst_ni)begin
   if(!rst_ni)begin count<=0;enq<=0;head<=0;half<=0;sealed_q<=0;primed<=0;previous<=0;fault_o<=0;end
   else if(clear_i)begin count<=0;enq<=0;head<=0;half<=0;sealed_q<=0;primed<=0;previous<=0;fault_o<=0;end
   else begin
     if(write_i)begin
       if(primed||sealed_q||count==DEPTH||strb_i!=15||addr_i!={count,half}||
          (!half && (last_i || (|(data_i >> PAYLOAD_BITS)))) ||
          (half && ((|(data_i >> (32+AUX_BITS))) || (count!=0 && data_i[31:0]<=previous))))fault_o<=1;
       else if(!half)begin payload[count[AW-1:0]]<=data_i[PAYLOAD_BITS-1:0];half<=1;end
       else begin schedule[count[AW-1:0]]<=data_i[63:0];count<=count+1'b1;half<=0;sealed_q<=last_i;previous<=data_i[31:0];end
     end
     if(prime_i)begin if(!sealed_q || primed)fault_o<=1;else primed<=1;end
     if(enqueue_o)enq<=enq+1'b1;
     if(due && !launch_o)fault_o<=1;
     if(launch_o)head<=head+1'b1;
   end
 end
endmodule
