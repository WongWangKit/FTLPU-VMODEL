`timescale 1ns/1ps
// Public ports only. Check every occupied link against an analytic source/time
// calendar, including two unrelated payloads at each simultaneous crossing.
module lpu_mxm_result_return_tb #(
  parameter integer ROWS=4,COLS=ROWS,LANES=8
);
  localparam integer W=LANES*32,T=16;
  logic clk=0,rst_n=0,run=0;
  logic [COLS-1:0] valid;
  logic [COLS*W-1:0] data;
  logic [COLS*T-1:0] tag;
  wire [ROWS-1:0] out_valid;
  wire [ROWS*W-1:0] out_data;
  wire [ROWS*T-1:0] out_tag;
  wire [ROWS*COLS-1:0] dv,lv;
  wire [ROWS*COLS*W-1:0] dd,ld;
  wire [ROWS*COLS*T-1:0] dt,lt;
  integer drive_index=-1,checks=0,crossings=0,outputs=0;
  always #5 clk=~clk;
  lpu_mxm_result_return #(.ROWS(ROWS),.COLS(COLS),.LANES(LANES)) dut (
    .clk_i(clk),.rst_ni(rst_n),.run_i(run),.top_valid_i(valid),.top_i(data),.top_tag_i(tag),
    .left_valid_o(out_valid),.left_o(out_data),.left_tag_o(out_tag),
    .down_valid_o(dv),.left_link_valid_o(lv),.down_o(dd),.left_link_o(ld),.down_tag_o(dt),.left_link_tag_o(lt));
  function automatic bit occupied(input integer c,t);
    // A long full-rate phase, column-skewed bursts, then independent bubbles.
    occupied=t>=0 && t<160 && (t<80 || (t>=c && (t-c)%17!=3 && (t*3+c)%13!=2));
  endfunction
  function automatic logic [15:0] tag_at(input integer c,t);
    tag_at=16'(c*1024+t);
  endfunction
  function automatic logic [W-1:0] payload(input integer c,t);
    logic [W-1:0] value;
    begin
      for(integer g=0;g<LANES;g++) value[g*32+:32]=32'h80000000^(32'(c)<<24)^(32'(g)<<16)^32'(t*997+g*37+c);
      payload=value;
    end
  endfunction
  always_comb begin
    valid='0;data='0;tag='0;
    for(integer c=0;c<COLS;c++) begin
      valid[c]=occupied(c,drive_index);
      data[c*W+:W]=payload(c,drive_index);tag[c*T+:T]=tag_at(c,drive_index);
    end
  end
  always @(posedge clk) begin
    #1;
    if(!rst_n || !run) begin
      if(out_valid!=='0 || dv!=='0 || lv!=='0) $fatal(1,"return reset/run flush failed");
    end else begin
      for(integer r=0;r<ROWS;r++) begin
        integer source_time;
        source_time=drive_index-ROWS+1;
        if(out_valid[r]!==occupied(r,source_time)) $fatal(1,"return endpoint phase r=%0d t=%0d",r,drive_index);
        if(out_valid[r]) begin
          if(out_data[r*W+:W]!==payload(r,source_time) || out_tag[r*T+:T]!==tag_at(r,source_time))
            $fatal(1,"return endpoint payload/tag mismatch");
          outputs=outputs+1;
        end
        for(integer c=0;c<COLS;c++) begin
          integer pos,down_time,left_time;
          bit expected_down,expected_left;
          pos=r*COLS+c;down_time=drive_index-ROWS+r+1;left_time=drive_index-ROWS+c+1;
          expected_down=r>c && occupied(c,down_time);
          expected_left=r>=c && occupied(r,left_time);
          if(dv[pos]!==expected_down || lv[pos]!==expected_left) $fatal(1,"return link phase/unused-position mismatch");
          if(expected_down && (dd[pos*W+:W]!==payload(c,down_time) || dt[pos*T+:T]!==tag_at(c,down_time)))
            $fatal(1,"downward stream payload/tag mismatch");
          if(expected_left && (ld[pos*W+:W]!==payload(r,left_time) || lt[pos*T+:T]!==tag_at(r,left_time)))
            $fatal(1,"leftward stream payload/tag mismatch");
          if(r<=c && (dd[pos*W+:W]!=='0 || dt[pos*T+:T]!=='0)) $fatal(1,"inactive downward link not zero");
          if(r<c && (ld[pos*W+:W]!=='0 || lt[pos*T+:T]!=='0)) $fatal(1,"inactive leftward link not zero");
          if(expected_down && expected_left) crossings=crossings+1;
          checks=checks+1;
        end
      end
    end
  end
  task automatic send_epoch(input integer count);
    begin
      // Every epoch restarts after reset/run flush; negative source times must
      // stay invalid until the fixed-length pipeline has filled again.
      for(integer t=0;t<count;t++) begin @(negedge clk);drive_index=t;run=1;end
      for(integer t=count;t<count+ROWS+2;t++) begin @(negedge clk);drive_index=t;end
    end
  endtask
  initial begin
    repeat(2) @(negedge clk);rst_n=1;
    send_epoch(160);
    @(negedge clk);run=0;drive_index=-1;
    repeat(2) @(negedge clk);
    send_epoch(7);
    // Cancel while valid data remains in flight; no old token may reappear.
    @(negedge clk);run=0;drive_index=-1;
    repeat(2) @(negedge clk);
    send_epoch(160);
    @(negedge clk);rst_n=0;run=0;drive_index=-1;
    repeat(2) @(negedge clk);rst_n=1;
    send_epoch(160);
    @(negedge clk);run=0;drive_index=-1;
    #2;
    if(outputs<ROWS*300 || (ROWS>1 && crossings<100)) $fatal(1,"insufficient return coverage");
    $display("MXM_RETURN_PASS rows=%0d lanes=%0d stages=%0d link_checks=%0d crossing_pairs=%0d outputs=%0d",ROWS,LANES,ROWS,checks,crossings,outputs);
    $finish;
  end
  initial begin #50000;$fatal(1,"return timeout");end
endmodule
