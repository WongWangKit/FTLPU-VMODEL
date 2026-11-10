`timescale 1ns/1ps
// Raw instruction words and public ports; no hierarchical DUT references.
module lpu_mxm_backend_config_tb;
  parameter integer DEPTH=1000;
  localparam integer AB=$clog2(DEPTH),IB=AB+13,RB=DEPTH/2>1?$clog2(DEPTH/2):1;
  import lpu_mxm_backend_isa_pkg::*;
  logic clk=0,rst_n=0,run=0,enqueue=0,launch=0,pv=0;
  logic [IB-1:0] instruction=0;
  logic [31:0] pd=32'h3f800000;
  logic [15:0] pt=16'hcafe;
  wire ready,launch_ready,fault,iv,iq,sv,sq,rv,rq,av;
  wire [15:0] ia,sa,ra,rt,aa,at;
  wire [1:0] io,so;
  wire [1:0] bv,bw;
  wire [2*RB-1:0] ba;
  wire [63:0] bd;
  wire [31:0] rd,opa,opb;
  always #5 clk=~clk;
  lpu_mxm_backend #(.COLS(1),.LANES(1),.DEPTH(DEPTH),.QUEUE_DEPTH(2)) dut (
    .clk_i(clk),.rst_ni(rst_n),.run_i(run),.enqueue_valid_i(enqueue),.enqueue_ready_o(ready),
    .instruction_i(instruction),.launch_i(launch),.launch_ready_o(launch_ready),
    .partial_valid_i(pv),.partial_i(pd),.partial_tag_i(pt),
    .issue_valid_o(iv),.issue_address_o(ia),.issue_operation_o(io),.issue_bf16_o(iq),
    .slot_valid_o(sv),.slot_address_o(sa),.slot_operation_o(so),.slot_bf16_o(sq),
    .result_valid_o(rv),.result_bf16_o(rq),.result_o(rd),.result_address_o(ra),.result_tag_o(rt),
    .bank_request_valid_o(bv),.bank_write_o(bw),.bank_address_o(ba),.bank_write_data_o(bd),
    .alu_valid_o(av),.operand_a_o(opa),.operand_b_o(opb),.alu_address_o(aa),.alu_tag_o(at),.fault_o(fault));
  function automatic logic [IB-1:0] pack_word(input integer op,count,base,input bit bf16);
    pack_word=(IB'(bf16)<<(IB-1)) | (IB'(count-1)<<(AB+2)) | (IB'(base)<<2) | IB'(op);
  endfunction
  task automatic reset_backend;
    @(negedge clk);rst_n=0;run=0;enqueue=0;launch=0;pv=0;
    repeat(2) @(negedge clk);rst_n=1;
  endtask
  integer outputs=0,reads=0,writes=0,issues=0;
  task automatic execute(input integer op,count,base,input bit bf16,legal);
    integer expected_address;
    begin
      outputs=0;reads=0;writes=0;issues=0;
      @(negedge clk);instruction=pack_word(op,count,base,bf16);enqueue=1;
      #1;if(!ready) $fatal(1,"config enqueue blocked");
      @(negedge clk);enqueue=0;run=1;
      @(negedge clk);launch=1;
      #1;if(!launch_ready) $fatal(1,"config launch blocked");
      // Tick 0 is launch; requests/operands are sampled before their edge.
      for(integer tick=0;tick<count+9;tick++) begin
        if(tick>0) begin @(negedge clk);launch=0;end
        pv=legal && tick>=3 && tick<count+3;
        #1;
        if(iv) begin
          if(!legal || tick<1 || tick>count || ia!==16'(base+tick-1) || io!==2'(op) || iq!==bf16)
            $fatal(1,"config issue phase/address depth=%0d tick=%0d",DEPTH,tick);
          issues++;
        end
        for(integer bank=0;bank<2;bank++) if(bv[bank]) begin
          if(bw[bank]) begin
            expected_address=base+tick-6;
            if(op!=1 || tick<6 || tick>=count+6 || bd[bank*32+:32]!==32'h3f800000)
              $fatal(1,"config STORE phase/data mismatch");
            writes++;
          end else begin
            expected_address=base+tick-1;
            if(op!=3 || tick<1 || tick>count) $fatal(1,"config read phase mismatch");
            reads++;
          end
          if(bank!=expected_address%2 || ba[bank*RB+:RB]!==RB'(expected_address/2))
            $fatal(1,"config bank address truncated depth=%0d address=%0d",DEPTH,expected_address);
        end
        if(sv && (tick<3 || tick>=count+3 || sa!==16'(base+tick-3) || so!==2'(op) || sq!==bf16))
          $fatal(1,"config slot metadata mismatch");
        if(av && (opa!==32'h3f800000 || opb!==32'h3f800000 || aa!==sa || at!==pt))
          $fatal(1,"config SRAM/add operand mismatch");
        @(posedge clk);#2;
        if(legal && fault) $fatal(1,"legal config fault depth=%0d op=%0d tick=%0d",DEPTH,op,tick);
        if(rv) begin
          if(!legal || (op!=0 && op!=3) || tick<6 || tick>=count+6 ||
             ra!==16'(base+tick-6) || rt!==pt || rq!==bf16 ||
             rd!==(bf16?32'h00003f80:32'h40000000))
            $fatal(1,"config output metadata/data mismatch depth=%0d tick=%0d",DEPTH,tick);
          outputs++;
        end
      end
      @(negedge clk);pv=0;
      if(legal) begin
        if(issues!=count || writes!=(op==1?count:0) || reads!=(op==3?count:0) ||
           outputs!=((op==0 || op==3)?count:0)) $fatal(1,"config transaction count mismatch");
      end else if(!fault || issues || writes || reads || outputs)
        $fatal(1,"invalid config command executed");
    end
  endtask
  integer patterns=0,base;
  bit expected;
  logic [IB-1:0] word;
  initial begin
    if(backend_address_bits(DEPTH)!=AB || backend_instruction_bits(DEPTH)!=IB)
      $fatal(1,"compact backend width mismatch");
    // All count/op/format combinations at five representative boundaries.
    for(integer sample=0;sample<5;sample++) begin
      case(sample)
        0:base=0;1:base=1;2:base=DEPTH-2;3:base=DEPTH-1;default:base=(1<<AB)-1;
      endcase
      for(integer count=1;count<=1024;count++)
        for(integer op=0;op<4;op++) for(integer format=0;format<2;format++) begin
          expected=base+count<=DEPTH && (!format || op==0 || op==3);
          word=pack_word(op,count,base,1'(format));
          if(backend_fields_legal(DEPTH,base,count,2'(op),1'(format))!==expected ||
             backend_duration(word[AB+2+:10])!==11'(count))
            $fatal(1,"compact decoder mismatch depth=%0d count=%0d base=%0d",DEPTH,count,base);
          if(DEPTH==1024 && backend_legal(word)!==expected) $fatal(1,"default packed decoder mismatch");
          patterns++;
        end
    end
    reset_backend();execute(1,2,DEPTH-2,0,1);execute(3,2,DEPTH-2,0,1);
    execute(0,1,DEPTH-1,1,1);
    reset_backend();execute(0,2,DEPTH-1,0,0);
    reset_backend();execute(1,2,DEPTH-1,0,0);
    reset_backend();execute(1,1,0,1,0);
    if(DEPTH!=(1<<AB)) begin
      reset_backend();execute(0,1,(1<<AB)-1,0,0);
    end
    $display("MXM_BACKEND_CONFIG_PASS depth=%0d address_bits=%0d instruction_bits=%0d patterns=%0d tail_sram=1 direct_bounds=1",DEPTH,AB,IB,patterns);
    $finish;
  end
  initial begin #100000;$fatal(1,"backend config timeout");end
endmodule
