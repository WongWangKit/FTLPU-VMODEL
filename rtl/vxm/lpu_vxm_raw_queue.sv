// Compiler VXM images contain 12-byte ICU words. Keep the image intact until issue.
module lpu_vxm_raw_queue #(parameter integer DEPTH=1536)(
  input logic clk_i,rst_ni,clear_i,write_i,prime_i,last_i,run_i,
  input logic [16:0] addr_i,input logic [3:0] strb_i,input logic [95:0] data_i,
  output wire configured_o,ready_o,idle_o,fault_o,issue_o,output wire [95:0] word_o
);
  localparam A=$clog2(DEPTH), N=$clog2(DEPTH+1);
  logic [A-1:0] base_q;
  logic [N-1:0] count_q;
  logic sealed_q,primed_q,finished_q,bad_q;
  logic [29:0] delay_q;
  wire rst_n=rst_ni && !clear_i;
  wire mem_ready,request,request_ready,request_last,response,response_ready,response_last;
  wire valid,last,fetch_ready,mfault,ffault;
  wire [A-1:0] request_addr;
  wire [95:0] rdata;
  wire take=run_i && valid && delay_q==0 && !bad_q;
  wire nop=word_o[1:0]==1 && word_o[95:32]==0 && word_o[31:2]!=0;
  wire write_ok=mem_ready && !sealed_q && addr_i<DEPTH && strb_i==7 &&
                (!count_q || addr_i=={1'b0,base_q}+count_q);
  wire start=prime_i && sealed_q && !primed_q && fetch_ready;
  assign configured_o=|count_q;
  assign issue_o=take && word_o[1:0]==0;
  assign idle_o=!configured_o || (finished_q && delay_q==0);
  assign ready_o=!configured_o || (primed_q && valid);
  assign fault_o=bad_q || mfault || ffault;
  lpu_slice_imem #(.DEPTH(DEPTH)) u_imem(
    .clk_i,.rst_ni(rst_n),.load_mode_i(!primed_q),.load_valid_i(write_i && write_ok),
    .load_ready_o(mem_ready),.load_address_i(addr_i[A-1:0]),.load_data_i(data_i),
    .request_valid_i(request),.request_ready_o(request_ready),.request_address_i(request_addr),
    .request_last_i(request_last),.response_valid_o(response),.response_ready_i(response_ready),
    .response_data_o(rdata),.response_last_o(response_last),.outstanding_o(),.idle_o(),.fault_o(mfault));
  lpu_slice_imem_fetch #(.IMEM_DEPTH(DEPTH)) u_fetch(
    .clk_i,.rst_ni(rst_n),.start_valid_i(start),.start_ready_o(fetch_ready),
    .start_base_address_i(base_q),.start_word_count_i(count_q),.request_valid_o(request),
    .request_ready_i(request_ready),.request_address_o(request_addr),.request_last_o(request_last),
    .response_valid_i(response),.response_ready_o(response_ready),.response_data_i(rdata),
    .response_last_i(response_last),.word_valid_o(valid),.word_ready_i(take),.word_o,
    .word_last_o(last),.busy_o(),.done_o(),.fault_o(ffault),.fault_code_o());
  always_ff @(posedge clk_i or negedge rst_n) begin
    if(!rst_n) begin
      base_q<=0; count_q<=0; sealed_q<=0; primed_q<=0; finished_q<=0; delay_q<=0; bad_q<=0;
    end else begin
      if(write_i && write_ok) begin
        if(count_q==0)base_q<=addr_i[A-1:0];count_q<=count_q+1'b1;sealed_q<=last_i;
      end
      if(start)primed_q<=1;
      if((write_i && !write_ok)||(prime_i && !start)||
         (run_i && primed_q && !finished_q && delay_q==0 && !valid)||
         (take && !(issue_o || nop)))bad_q<=1;
      if(run_i && delay_q!=0)delay_q<=delay_q-1'b1;
      if(take && nop)delay_q<=word_o[31:2]-1'b1;
      if(take && last)finished_q<=1;
    end
  end
endmodule
