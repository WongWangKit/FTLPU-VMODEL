// Isolated scheduler -> weight LOAD issue port. Only the runtime calendar
// issuer drives cmd_i. The computation/epoch controller owns generation_i
// and the free-running physical edge number. All three share this clock.
module lpu_dma_weight_schedule_port #(parameter T=4,F=52)(
 input logic clk_i,rst_ni,cancel_i,
 input logic [63:0] generation_i,cycle_i,
 input logic image_activate_i,input logic [63:0] image_generation_i,
 output logic image_activate_ready_o,output logic [63:0] image_id_o,
 input logic valid_i,input logic [543:0] cmd_i,output logic ready_o,reject_o,
 // To EXPLICIT_MEM_LAYOUT data channel. This port never issues STORE.
 output logic desc_valid_o,input logic desc_ready_i,output logic hem_o,
 output logic [6:0] bank_o,output logic [2:0] lane_o,output logic [4:0] stream_o,
 output logic [14:0] row_o,row_stride_o,output logic [31:0] count_o,ddr_stride_o,tag_o,
 output logic [63:0] addr_o,
 // From the ACTIVE channel, not from the scheduler command input bus.
 input logic mem_req_i,mem_hem_i,input logic [6:0] mem_bank_i,
 input logic [2:0] mem_lane_i,input logic [4:0] mem_stream_i,
 input logic native_ready_i,output logic native_req_o,mem_ready_o,
 output logic channel_cancel_o,input logic result_valid_i,result_ready_i,
 output logic [63:0] result_generation_o,result_page_o,output logic slot_o,first_seg_o,last_seg_o
);
 wire [63:0] gen=cmd_i[63:0], page=cmd_i[127:64], first=cmd_i[191:128], lim=cmd_i[255:192];
 assign addr_o=cmd_i[319:256];assign count_o=cmd_i[351:320];assign ddr_stride_o=cmd_i[383:352];
 assign row_o=cmd_i[398:384];assign row_stride_o=cmd_i[414:400];
 assign bank_o=cmd_i[422:416];assign hem_o=cmd_i[423];assign lane_o=cmd_i[426:424];
 assign stream_o=cmd_i[431:427];assign tag_o=cmd_i[479:448];
 logic live,killed,h;logic [6:0] b;logic [2:0] l;logic [4:0] s;
 logic [63:0] begin_q,end_q,aborted_through,image_generation;logic [31:0] remaining;
 // The program scheduler sends this handshake only AFTER the old compute
 // image drains. This side additionally interlocks accepted LOADs/results.
 assign image_activate_ready_o=rst_ni && !live && !cancel_i &&
     image_generation_i>aborted_through && image_generation_i>=image_generation && !(&image_id_o);
 wire legal=gen!=0 && gen==generation_i && gen>aborted_through && page!=0 &&
   gen==image_generation && cmd_i[543:480]==image_id_o &&
   first<lim && cycle_i<lim && bank_o<2*F && !cmd_i[399] && !cmd_i[415] && cmd_i[447:435]==0;
 assign ready_o=rst_ni && !cancel_i && !live && !image_activate_i && (!legal || desc_ready_i);
 // Rejection consumes this command locally (no AXI, no channel completion).
 assign reject_o=valid_i && ready_o && !legal;
 assign desc_valid_o=rst_ni && !cancel_i && !live && !image_activate_i && valid_i && legal;
 wire expired=remaining!=0 && cycle_i>=end_q;
 assign channel_cancel_o=cancel_i || (live && (killed || generation_i!=result_generation_o || expired));
 wire [2*F-1:0] reserved={{(2*F-1){1'b0}},1'b1}<<b;
 wire grant;
 lpu_dma_weight_window #(.T(T),.F(F)) window_check(
   .valid_i(live && remaining!=0),.cancel_i(channel_cancel_o),.cycle_i,.first_i(begin_q),.limit_i(end_q),
   .epoch_i(generation_i),.desc_epoch_i(result_generation_o),.hem_i(mem_hem_i),.reserved_hem_i(h),
   .bank_i(mem_bank_i),.reserved_banks_i(reserved),.lane_i(mem_lane_i),.reserved_lane_i(l),
   .stream_i(mem_stream_i),.reserved_stream_i(s),.grant_o(grant));
 assign native_req_o=mem_req_i && grant;
 assign mem_ready_o=native_ready_i && grant;
 always_ff @(posedge clk_i or negedge rst_ni)
 if(!rst_ni)begin
   live<=0;killed<=0;aborted_through<=0;image_generation<=0;image_id_o<=0;remaining<=0;h<=0;b<=0;l<=0;s<=0;
   begin_q<=0;end_q<=0;result_generation_o<=0;result_page_o<=0;{last_seg_o,first_seg_o,slot_o}<=0;
 end else begin
   if(image_activate_i && image_activate_ready_o)begin image_id_o<=image_id_o+1'b1;image_generation<=image_generation_i;end
   if(cancel_i && generation_i>aborted_through)aborted_through<=generation_i;
   if(desc_valid_o && desc_ready_i)begin
     live<=1;killed<=0;begin_q<=first;end_q<=lim;remaining<=count_o;
     h<=hem_o;b<=bank_o;l<=lane_o;s<=stream_o;
     result_generation_o<=gen;result_page_o<=page;{last_seg_o,first_seg_o,slot_o}<=cmd_i[434:432];
   end
   if(native_req_o && native_ready_i)remaining<=remaining-1'b1;
   if(live && channel_cancel_o)killed<=1;
   if(result_valid_i && result_ready_i)live<=0;
 end
endmodule
