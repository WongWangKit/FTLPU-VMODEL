// Transport owns a reserved native MEM/SR window. One handshake reserves
// the complete vector and its return slot. Never stall a launched tile wave.
module lpu_dma_mem_wave #(parameter T=4,F=52)(
 input logic clk_i,rst_ni,req,write_i,input logic [6:0] bank_i,input logic [2:0] lane_i,
 input logic [14:0] row_i,input logic [T*64-1:0] vector_i,
 output logic ready,ret,err,output logic [T*64-1:0] vector_o,
 output logic [F*2-1:0] cmd_valid,output logic [31:0] cmd,
 input logic [2*16*T*32-1:0] sr_valid,
 input logic [(F/4+1)*2*32*T-1:0] consumed,
 input logic [T*32-1:0] east_valid,input logic [T*32*64-1:0] east_data,
 output logic [T*32-1:0] west_valid,output logic [T*32*64-1:0] west_data,
 input logic native_fault,input logic collision
);
 logic live,write_q,issued;logic [6:0] bank;logic [4:0] stream;
 logic [14:0] row;logic [T*64-1:0] payload;
 logic [$clog2(T+1)-1:0] sent;
 logic [T-1:0] seen,hits;
 wire [3:0] boundary=(bank>>3)+1;
 assign ready=!live && !ret;
 always_comb begin
   cmd_valid='0;west_valid='0;west_data='0;hits='0;
   cmd={2'b00,row,6'b0,write_q,stream,2'b0,write_q};
   if(live)begin
     if(write_q && sent<T)begin
       west_valid[sent*32+stream]=1;
       west_data[(sent*32+stream)*64+:64]=payload[sent*64+:64];
     end
     if(!issued && (!write_q || sr_valid[((16+boundary)*T)*32+stream]))cmd_valid[bank]=1;
     for(integer t=0;t<T;t++)begin
       hits[t]=write_q?consumed[boundary*2*32*T+(32+stream)*T+t]:east_valid[t*32+stream];
     end
   end
 end
 always_ff @(posedge clk_i or negedge rst_ni)
 if(!rst_ni)begin live<=0;ret<=0;err<=0;write_q<=0;issued<=0;row<=0;bank<=0;
    stream<=0;sent<=0;seen<=0;payload<=0;vector_o<=0;end
 else begin
   ret<=0;
   if(req&&ready)begin live<=1;issued<=0;seen<=0;sent<=0;err<=0;
     write_q<=write_i;bank<=bank_i;row<=row_i;stream<=write_i?5'd24+lane_i:5'(lane_i);payload<=vector_i;end
   if(live)begin
     if(sent<T)sent<=sent+1'b1;
     if(|cmd_valid)issued<=1;
     seen<=seen|hits;
     for(integer t=0;t<T;t++)if(!write_q && hits[t])vector_o[t*64+:64]<=east_data[(t*32+stream)*64+:64];
     if(&(seen|hits) || native_fault || collision)begin
       live<=0;ret<=1;err<=native_fault || collision || (|(seen&hits));
     end
   end
 end
endmodule
