`timescale 1ns/1ps
module lpu_mxm_acc_bank_replay_tb #(parameter DEPTH=512);
  bit clk;always #5 clk=!clk;
  bit rst,pre,wr;logic [$clog2(DEPTH)-1:0] pa,wa;logic [255:0] wd;wire [255:0] q;
  lpu_mxm_vector_acc_bank #(.DEPTH(DEPTH)) dut(.clk_i(clk),.rst_ni(rst),.pre_i(pre),
    .write_i(wr),.pre_addr_i(pa),.write_addr_i(wa),.write_data_i(wd),.read_data_o(q));
  logic [255:0] refdata[DEPTH];bit [DEPTH-1:0] valid;
  int traffic,hits,parallel_ops,synthetic,checked;
  task automatic step(bit req,int addr,bit write_data,int waddr,logic[255:0] data);
    logic [255:0] expected;bit compare;
    pre=req;pa=addr;wr=write_data;wa=waddr;wd=data;
    expected=(wr && pa==wa)?wd:refdata[pa];compare=pre && (valid[pa] || (wr && pa==wa));
    #1;
    if(wr && pre)begin
      if(pa==wa)begin if(dut.hit!==1)$fatal(1,"RAW not forwarded");hits++;end
      else begin if(dut.rb===dut.wb)$fatal(1,"physical 1RW collision");parallel_ops++;end
    end
    @(posedge clk);#1;
    if(compare)begin if(q!==expected)$fatal(1,"old/wrong data at row %0d",pa);checked++;end
    if(wr)begin refdata[wa]=wd;valid[wa]=1;end
    @(negedge clk);
  endtask
  integer fd,n,req,addr,wreq,waddr;logic [255:0] data;
  initial begin
    rst=0;pre=0;wr=0;repeat(2)@(negedge clk);rst=1;
    fd=$fopen("bank.trace","r");if(!fd)$fatal(1,"missing trace");
    while($fscanf(fd,"%d %d %d %d %h",req,addr,wreq,waddr,data)==5)begin
      step(req,addr,wreq,waddr,data);traffic++;
    end
    if(!$feof(fd) || traffic==0)$fatal(1,"bad trace");$fclose(fd);
    // Adversarial equal and even-strided addresses, including depth extension.
    for(int i=0;i<256;i++)begin
      int a,b;a=(DEPTH-2*i-2)%DEPTH;b=(i%3==0)?a:(a+4)%DEPTH;
      step(1,b,1,a,{8{32'(i+1)}});step(1,a,1,b,{8{32'(i+900)}});
      synthetic+=2;
    end
    if(!hits || !parallel_ops || !checked)$fatal(1,"missing path");
    $display("PASS bank replay depth=%0d trace=%0d synthetic=%0d RAW=%0d independentRW=%0d checked=%0d",DEPTH,traffic,synthetic,hits,parallel_ops,checked);
    $finish;
  end
endmodule
