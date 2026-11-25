// Standalone composition BEFORE integration. One ordered READ client of the
// existing shared manager, one native MEM/SR wave request. Do not instantiate
// a second data channel in the product beside its ordinary LOAD/STORE channel.
module lpu_dma_scheduled_weight_load #(parameter T=4,F=52,ROWS=2048,RT=128,Q=384)(
 input logic clk_i,rst_ni,enable_i,isolated_i,cancel_i,
 input logic [63:0] generation_i,cycle_i,input logic image_activate_i,output logic image_activate_ready_o,
 output logic [63:0] image_id_o,input logic valid_i,input logic [543:0] cmd_i,
 output logic ready_o,reject_o,
 output logic result_valid_o,result_error_o,input logic result_ready_i,
 output logic [31:0] result_tag_o,output logic [63:0] result_generation_o,result_page_o,
 output logic slot_o,first_seg_o,last_seg_o,
 output logic arvalid,input logic arready,output logic [63:0] araddr,output logic [7:0] arlen,
 input logic rvalid,output logic rready,input logic [T*64-1:0] rdata,input logic [1:0] rresp,input logic rlast,
 output logic r_expected,last_expected,
 output logic native_req_o,input logic native_ready_i,output logic native_hem_o,
 output logic [6:0] native_bank_o,output logic [2:0] native_lane_o,output logic [4:0] native_stream_o,
 output logic [14:0] native_row_o,output logic [T*64-1:0] native_data_o,input logic native_ret_i,native_err_i
);
 wire dv,dr,hem,mem_req,mem_ready,abort_channel,channel_result;
 assign result_valid_o=channel_result && !isolated_i;
 wire [6:0] bank;wire [2:0] lane;wire [4:0] stream;
 wire [14:0] row,step;wire [31:0] count,stride,tag;wire [63:0] addr;
 lpu_dma_weight_schedule_port #(.T(T),.F(F)) issuer(
   .clk_i,.rst_ni,.cancel_i,.generation_i,.cycle_i,.image_generation_i(generation_i),.image_activate_i,.image_activate_ready_o,.image_id_o,
   .valid_i,.cmd_i,.ready_o,.reject_o,
   .desc_valid_o(dv),.desc_ready_i(dr),.hem_o(hem),.bank_o(bank),.lane_o(lane),.stream_o(stream),
   .row_o(row),.row_stride_o(step),.count_o(count),.ddr_stride_o(stride),.tag_o(tag),.addr_o(addr),
   .mem_req_i(mem_req),.mem_hem_i(native_hem_o),.mem_bank_i(native_bank_o),.mem_lane_i(native_lane_o),
   .mem_stream_i(native_stream_o),.native_ready_i,.native_req_o,.mem_ready_o(mem_ready),
   .channel_cancel_o(abort_channel),.result_valid_i(result_valid_o),.result_ready_i,
   .result_generation_o,.result_page_o,.slot_o,.first_seg_o,.last_seg_o);
 lpu_dma_data_channel #(.W(64*T),.RT(RT),.Q(Q),.ROWS(ROWS),.BANKS(2*F),.EXPLICIT_MEM_LAYOUT(1)) data(
   .clk_i,.rst_ni,.enable_i,.isolated_i,.cancel_i(abort_channel),
   .desc_valid_i(dv),.desc_ready_o(dr),.store_i(1'b0),.hem_i(hem),.bank_i(bank),.lane_i(lane),
   .row_i(row),.row_stride_i(step),.fabric_stream_i(stream),.addr_i(addr),.count_i(count),.stride_i(stride),.tag_i(tag),
   .result_valid_o(channel_result),.result_error_o,.result_ready_i(result_ready_i && !isolated_i),.result_tag_o,
   .mem_req,.mem_ready,.mem_hem(native_hem_o),.mem_bank(native_bank_o),.mem_lane(native_lane_o),
   .mem_row(native_row_o),.mem_stream(native_stream_o),.mem_data(native_data_o),
   .mem_ret(native_ret_i),.mem_err(native_err_i),.mem_q({(64*T){1'b0}}),
   .arvalid,.arready,.araddr,.arlen,.rvalid,.rready,.rdata,.rresp,.rlast,.r_expected,.last_expected,
   .awready(1'b0),.wready(1'b0),.bvalid(1'b0),.bresp(2'b0));
endmodule
