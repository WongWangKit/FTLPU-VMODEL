`timescale 1ns/1ps
// Consecutive Compute waves, independently checked on every physical lane.
// Four input rows arrive in four successive cycles; all tiles contribute +8.
module lpu_mxm_vector_overlap_tb #(parameter T=2);
  bit clk;always #5 clk=!clk;
  bit rst_n,run;
  logic [3:0] valid,fmt;logic [191:0] words;logic [127:0] ev;
  logic [8191:0] ed;logic [32767:0] weights;logic [31:0] cells;
  wire [127:0] consumed,wv;wire [8191:0] wd;wire busy,fault;
  lpu_mxm_vector_array #(.T(T),.ACC_BLOCKS(4)) dut(
    .clk_i(clk),.rst_ni(rst_n),.run_i(run),.discard_partial_sums_i(1'b0),.issue_valid_i(1'b0),.issue_word_i(49'd0),
    .valid_i(valid),.bf16_i(fmt),.words_i(words),
    .east_valid_i(ev),.east_data_i(ed),.weights_i(weights),.cell_valid_i(cells),
    .consumed_o(consumed),.west_valid_o(wv),.west_data_o(wd),.busy_o(busy),.fault_o(fault));
  initial begin
    integer checks;
    checks=0;valid=0;fmt=0;words=0;ev=0;ed=0;weights={2048{16'h3f80}};cells='1;
    repeat(3)@(negedge clk);rst_n=1;run=1;
    for(integer tick=0;tick<4+2*T;tick++)begin
      valid=0;fmt='1;ev=0;
      for(integer r=0;r<T;r++)begin
        if(tick>=r && tick<r+4)begin
          valid[r]=1;ev[32*r+:2]=3;
          words[48*r+:48]=(48'd1<<45)|(48'd1<<44)|(48'd1<<28)|1;
          // 1,2,4,8: a wrong row-order produces a distinct BF16 result.
          ed[(32*r+1)*64+:64]={8{8'('h3f+(tick-r+1)/2)}};
          ed[32*r*64+:64]={8{(tick-r)%2==0?8'h80:8'h00}};
        end
      end
      #1;
      if(consumed!==ev || fault)$fatal(1,"input/flags T=%d t=%d",T,tick);
      for(integer c=0;c<T;c++)begin
        integer n;logic [15:0] expected;
        n=tick-(T-1)-c;
        if(wv[c*32+:32] !== ((n>=0 && n<4)?32'h3:0))$fatal(1,"valid T=%d c=%d tick=%d",T,c,tick);
        expected=(T==2?16'h4180:16'h4200)+(n<<7);
        if(n>=0 && n<4)for(integer lane=0;lane<8;lane++)begin
          if({wd[(c*32+1)*64+8*lane+:8],wd[c*32*64+8*lane+:8]}!==expected)
            $fatal(1,"wrong sum T=%d c=%d row=%d lane=%d",T,c,n,lane);
          checks++;
        end
      end
      @(negedge clk);
    end
    if(busy || fault || checks!=T*8*4)$fatal(1,"did not drain");
    // Accumulate an all-ones row into SRAM without producing SR data, then
    // read the same cell as FP32, BF16+clear, and once more after clear.
    for(integer t=0;t<2*T;t++)begin
      words=0;valid=0;ev=0;
      if(t<T)begin
        valid[t]=1;ev[t*32+:2]=3;ed[t*2048+:64]='0;
        ed[t*2048+:64]={8{8'h80}};ed[t*2048+64+:64]={8{8'h3f}};
        words[t*48+:48]=(48'd1<<45)|(48'd1<<28)|(48'd2<<15)|1;
      end
      #1;if(wv!='0 || fault)$fatal(1,"SRAM compute produced stream or fault");
      @(negedge clk);
    end
    for(integer phase=0;phase<3;phase++)for(integer c=0;c<T;c++)begin
      valid=0;valid[c]=1;fmt=phase==0?0:'1;words=0;
      words[c*48+:48]=(48'd1<<44)|(48'd2<<15)|2;
      words[c*48+28]=(phase==1);
      #1;
      if(fault || wv[c*32+:32] !== (phase==0?15:3))$fatal(1,"ACC_READ mask");
      for(integer n=0;n<8;n++)begin
        logic [31:0] bits;
        bits='0;
        for(integer b=0;b<(phase==0?4:2);b++) bits[b*8+:8]=wd[(32*c+b)*64+n*8+:8];
        if(bits !== (phase==0?(T==2?32'h41800000:32'h42000000):
                     phase==1?(T==2?32'h4180:32'h4200):0))$fatal(1,"ACC_READ address/format/clear");
      end
      @(negedge clk);
    end
    $display("PASS matrix overlap T=%d BF16 checks=%d",T,checks);$finish;
  end
endmodule
