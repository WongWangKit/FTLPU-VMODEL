// Transport owns a reserved native MEM/SR window. One handshake reserves
// the complete vector and its return slot. Never stall a launched tile wave.
module lpu_dma_mem_wave #(parameter T=4,F=52)(
 input logic clk_i,rst_ni,req,write_i,input logic [6:0] bank_i,input logic [4:0] stream_i,
 input logic [14:0] row_i,input logic [T*64-1:0] vector_i,
 output logic ready,ret,err,output logic [T*64-1:0] vector_o,
 output logic [F*2-1:0] cmd_valid,output logic [31:0] cmd,
 input logic [F*2*T-1:0] normal_write_committed,
 input logic [T*32-1:0] east_valid,input logic [T*32*64-1:0] east_data,
 output logic [T*32-1:0] west_valid,output logic [T*32*64-1:0] west_data,
 input logic native_fault,input logic collision
);
 logic live,write_q,issued;logic [6:0] bank;logic [4:0] stream;
 logic [14:0] row;logic [T*64-1:0] payload;
 logic [$clog2(T+1)-1:0] sent;
 logic [T-1:0] hits;
 logic [4:0] travel_left;
 logic [T-1:0] expected_tile;
 logic wave_fault;
 // Fire at edge 0; injection enters SR column 15 on edge 1. Native tile 0
 // samples at edge 17-boundary, then one tile per edge (command bit 30=0).
 assign ready=!live && !ret;
 always_comb begin
   cmd_valid='0;west_valid='0;west_data='0;hits='0;
   cmd={2'b00,row,6'b0,write_q,stream,2'b0,write_q};
   if(live)begin
     if(write_q && sent<T)begin
       west_valid[sent*32+stream]=1;
       west_data[(sent*32+stream)*64+:64]=payload[sent*64+:64];
     end
     if(!issued && (!write_q || travel_left==1))cmd_valid[bank]=1;
     for(integer t=0;t<T;t++)begin
       hits[t]=write_q?normal_write_committed[bank*T+t]:east_valid[t*32+stream];
     end
   end
 end
 always_ff @(posedge clk_i or negedge rst_ni)
 if(!rst_ni)begin live<=0;ret<=0;err<=0;write_q<=0;issued<=0;row<=0;bank<=0;
    stream<=0;sent<=0;payload<=0;vector_o<=0;travel_left<=0;expected_tile<='0;wave_fault<=0;end
 else begin
   ret<=0;
   if(req&&ready)begin live<=1;issued<=0;sent<=0;err<=0;wave_fault<=0;expected_tile<='0;
     travel_left<=5'd16-bank_i[6:3];
     write_q<=write_i;bank<=bank_i;row<=row_i;stream<=stream_i;payload<=vector_i;end
   if(live)begin
     if(sent<T)sent<=sent+1'b1;
     if(|cmd_valid)issued<=1;
     if(travel_left!=0)travel_left<=travel_left-1'b1;
     expected_tile<=(expected_tile<<1) | T'(travel_left==1);
     // LOAD observes the registered leaf commit. STORE issues its command
     // on edge 1: R1, East injection, passive hops to column 15. Its first
     // sample is on the same edge as LOAD's registered commit observation.
     // Ignore unrelated traffic before the return window. Once the reserved
     // gather opens, missing/repeated tiles fault; never forward stale data.
     if(!write_q)for(integer t=0;t<T;t++)if(expected_tile[t] && hits[t])
       vector_o[t*64+:64]<=east_data[(t*32+stream)*64+:64];
     if(native_fault || collision || (|(expected_tile & ~hits)) ||
        (!write_q && (|expected_tile) && hits!=expected_tile))wave_fault<=1;
     if(expected_tile[T-1])begin
       live<=0;ret<=1;err<=wave_fault || native_fault || collision || !hits[T-1] ||
         (!write_q && hits!=expected_tile);
     end
   end
 end
endmodule
