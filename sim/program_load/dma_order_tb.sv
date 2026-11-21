`timescale 1ns/1ps
module dma_order_tb #(parameter W=128,RT=19,Q=9);
 bit clk_i=0,rst_ni=0;always #1 clk_i=~clk_i;
 bit ar_fire,beat,last,pop;logic [7:0] len=0,id,rid=0;logic admit,expected,last_expected,valid,tail;
 logic [W-1:0] data=0,payload;logic [1:0] resp=0,error;
 lpu_dma_return_order #(.W(W),.RT(RT),.Q(Q)) dut(.*);
 int base[8],size[8];byte issued[7];
 initial begin
   int ordinal=0,deliver=0,n=0;
   repeat(3)@(negedge clk_i);rst_ni=1;
   for(int epoch=0;epoch<91;epoch++) begin
     n=0;
     for(int j=0;j<7;j++)begin
       @(negedge clk_i);len=1+((epoch+j)%2);#0.1;if(!admit)$fatal(1,"required window unavailable");
       issued[j]=id;base[id]=ordinal;size[id]=int'(len)+1;ordinal+=size[id];n+=size[id];
       ar_fire=1;@(negedge clk_i);ar_fire=0;
     end
     // Exact reservation, including non-power-of-two wrap, before a response.
     len=RT-n;#0.1;if(admit)$fatal(1,"ring overbooking");
     for(int j=6;j>=0;j--) for(int k=0;k<size[issued[j]];k++)begin
       @(negedge clk_i);rid=issued[j];last=(k==size[rid]-1);
       data=W'(base[rid]+k);resp=(k==1)?2:0;#0.1;
       if(!expected||last_expected!=last)$fatal(1,"AXI burst ownership");
       beat=1;@(negedge clk_i);beat=0;
     end
     for(int j=0;j<7;j++) for(int k=0;k<size[issued[j]];k++)begin
       @(negedge clk_i);if(!valid || payload!=W'(deliver) || error!=(k==1?2:0) || tail!=(k==size[issued[j]]-1))$fatal(1,"ordered retirement");
       deliver++;pop=1;@(negedge clk_i);pop=0;
     end
     if(valid||dut.live||dut.used)$fatal(1,"leak");
   end
   $display("PASS return ring W=%0d RT=%0d Q=%0d vectors=%0d reverse IDs, capacity, wrap, RESP/LAST",W,RT,Q,deliver);$finish;
 end
endmodule
