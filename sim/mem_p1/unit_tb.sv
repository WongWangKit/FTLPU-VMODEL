`timescale 1ns/1ps

module mem_p1_unit_tb;
  logic clk=0, rst_n=0, valid=0;
  logic [2:0] op=0;
  logic [14:0] row=0;
  logic direction=0, tap=0, segment_valid=0;
  logic [4:0] stream=0;
  logic [63:0] data='x;
  integer selected=0, which=0;
  wire [5:0] consume, read_valid, read_direction, fault;
  wire [63:0] read_data[0:5];
  wire [4:0] read_stream[0:5];
  wire [1:0] fault_code[0:5];
  integer checks=0, masks_checked=0;

  for(genvar n=0;n<6;n=n+1)begin:gen_leaf
    localparam integer P=n<2?64:n==2?8192:n==3?32768:n==4?16:32;
    localparam integer E=n==1?32:n==2?64:P;
    mem_bank_superlane_leaf #(.P_MEM_BANK_DEPTH_ROWS(P),.P_MEM_ACTIVE_ROWS(E)) dut(
      .clk_i(clk),.rst_ni(rst_n),.cmd_valid_i(valid && selected==n),.cmd_opcode_i(op),.cmd_row_i(row),
      .cmd_stream_dir_i(direction),.cmd_stream_idx_i(stream),.cmd_preserve_i(tap),
      .stream_valid_i(segment_valid),.stream_data_i(data),.stream_consume_o(consume[n]),
      .read_valid_o(read_valid[n]),.read_data_o(read_data[n]),.read_stream_dir_o(read_direction[n]),
      .read_stream_idx_o(read_stream[n]),.fault_valid_o(fault[n]),.fault_code_o(fault_code[n]));
  end

  task automatic command(input integer n,o,r,d,s,p,v,input logic[63:0] payload,
                         input integer rv,fc,c,input logic[63:0] expected);
    selected=n;valid=o>=0;op=3'(o);row=15'(r);direction=1'(d);stream=5'(s);tap=1'(p);
    segment_valid=1'(v);data=payload;
    #4;clk=1;#1;
    for(integer q=0;q<6;q=q+1)begin
      if(read_valid[q] !== (q==n && rv!=0) || consume[q] !== (q==n && c!=0) ||
         fault[q] !== (q==n && fc!=0))
        $fatal(1,"MEM leaf flags n=%0d q=%0d op=%0d row=%0d rv=%b fault=%b consume=%b",n,q,o,r,read_valid,fault,consume);
    end
    if(fc!=0 && fault_code[n]!==2'(fc))$fatal(1,"MEM leaf fault class");
    if(rv && (read_data[n]!==expected || read_direction[n]!==1'(d) || read_stream[n]!==5'(s)))
      $fatal(1,"MEM leaf data/metadata n=%0d row=%0d expected=%h actual=%h",n,r,expected,read_data[n]);
    clk=0;#1;checks=checks+1;
  endtask

  integer fd,rc,mode,kind,efault;
  logic[7:0] mask,consumed;
  logic[63:0] stored;
  string mask_path;
  initial begin
    if(!$value$plusargs("CASE=%d",which))which=0;
    #1;clk=1;#1;clk=0;rst_n=1;#1;
    if(which!=0)begin
      valid=1;op=1;row=1;segment_valid=1;data=64'h1234;
      case(which)
        1:force gen_leaf[0].dut.cmd_valid_i=1'bx;
        2:op='x;
        3:row='z;
        4:segment_valid=1'bx;
        5:data='x;
        6:rst_n=1'bz;
        7:force gen_leaf[0].dut.cmd_valid_i=1'bz;
        8:segment_valid=1'bz;
        9:data='z;
      endcase
      #4;clk=1;#1;$fatal(1,"UNEXPECTED_UNKNOWN_SUCCESS case=%0d",which);
    end
    for(integer n=0;n<6;n=n+1)begin
      command(n,0,0,0,0,0,0,'x,1,0,0,0);
      command(n,0,n==3?32767:n==4?15:(n==1||n==5)?31:63,1,31,0,0,'x,1,0,0,0);
      command(n,1,2,0,3,0,1,64'hf1e2d3c4b5a69788,0,0,1,0);
      command(n,0,2,1,7,0,0,'x,1,0,0,64'hf1e2d3c4b5a69788);
      // An immediately following write cannot alter the already sampled read.
      command(n,1,2,0,9,0,1,64'h0123456789abcdef,0,0,1,0);
      command(n,0,2,0,10,0,0,'x,1,0,0,64'h0123456789abcdef);
      command(n,1,2,0,0,1,0,'x,0,0,0,0);
      command(n,0,2,0,0,0,0,'x,1,0,0,64'h0123456789abcdef);
      command(n,1,2,1,31,1,1,64'h1020304050607080,0,0,0,0);
      rst_n=0;#1;rst_n=1;
      command(n,0,2,1,31,0,0,'x,1,0,0,64'h1020304050607080);
      command(n,0,3,0,0,0,0,'x,1,0,0,0);
      command(n,0,1,0,0,1,0,'x,0,2,0,0);
      for(integer bad=2;bad<8;bad=bad+1)command(n,bad,1,0,0,0,0,'x,0,1,0,0);
      if(n!=3)begin
        for(integer k=0;k<3;k=k+1)begin
          command(n,k==0?0:1,n==4?16:(n==1||n==5)?32:64,0,0,k==2,0,'x,0,1,0,0);
        end
        command(n,0,2,0,0,0,0,'x,1,0,0,64'h1020304050607080);
      end
    end
    if(!$value$plusargs("MASKS=%s",mask_path))$fatal(1,"MASKS missing");
    fd=$fopen(mask_path,"r");if(!fd)$fatal(1,"cannot open masks");
    while(!$feof(fd))begin
      rc=$fscanf(fd,"%d %d %h %d %h %h",mode,kind,mask,efault,consumed,stored);
      if(rc==-1)break;
      if(rc!=6)$fatal(1,"truncated mask vector");
      // The frozen c7 file contains both policies; hardware implements Error only.
      if(mode==1)continue;
      if(mode!=0)$fatal(1,"unsupported mask reference policy");
      command(mode,1,1,0,0,0,1,64'h8877665544332211,0,0,1,0);
      command(mode,1,1,0,0,kind==2,mask==8'hff,mask==8'hff ? 64'hfedcba9876543210 : 64'bx,
              0,efault?3:0,consumed!=0,0);
      command(mode,0,1,0,0,0,0,'x,1,0,0,stored);
      masks_checked=masks_checked+1;
    end
    $fclose(fd);
    if(masks_checked!=512)$fatal(1,"mask coverage count");
    // Invalid commands/payload are allowed to be X when command valid is zero.
    valid=0;op='x;row='x;stream='x;data='x;#4;clk=1;#1;clk=0;
    $display("MEM_UNIT TEST_PASS profiles=6 mask_cases=%0d checks=%0d",masks_checked,checks);
    $finish;
  end
endmodule
