`timescale 1ns/1ps
module srf_leaf_tb;
  reg clk_i=0,rst_ni=0;
  always #5 clk_i=~clk_i;
  reg [255:0] upstream_valid_i=0;
  reg [2047:0] upstream_data_i=0;
  reg [511:0] consume_i=0,inject_valid_i=0;
  reg [4095:0] inject_data_i=0;
  wire [255:0] state_valid_o,downstream_valid_o;
  wire [2047:0] state_data_o,downstream_data_o;
  wire collision_o,invalid_consume_o;
  ftlpu_sr_superlane_col_dir_lane dut(.*);
  reg [255:0] ev=0,nv;
  reg [2047:0] ed=0,nd;
  reg col,bad;
  reg [31:0] rng=32'h5ee12345;
  integer checks=0,count;
  reg [7:0] chosen;
  task automatic tick;
    begin
      nv=0;nd=0;col=0;bad=0;
      for(integer c=0;c<256;c++) begin
        count=0;chosen=0;
        if(upstream_valid_i[c]) begin count=count+1;chosen=upstream_data_i[c*8+:8];end
        for(integer p=0;p<2;p++) if(inject_valid_i[p*256+c]) begin
          count=count+1; chosen=inject_data_i[(p*256+c)*8+:8];
        end
        if(count==1) begin nv[c]=1;nd[c*8+:8]=chosen;end
        if(count>1) col=1;
        if((consume_i[c] || consume_i[256+c]) && !ev[c]) bad=1;
      end
      #1;
      if(collision_o!==col || invalid_consume_o!==bad) $fatal(1,"SRF fault mismatch");
      if(downstream_valid_o!==(ev & ~(consume_i[255:0]|consume_i[511:256]))) $fatal(1,"SRF consume mask mismatch");
      // RTL exposes raw state data downstream regardless of consume validity.
      if(state_valid_o!==ev || state_data_o!==ed || downstream_data_o!==ed) $fatal(1,"SRF old-state mismatch");
      @(posedge clk_i);#1;ev=nv;ed=nd;
      if(state_valid_o!==ev || state_data_o!==ed) $fatal(1,"SRF next-state mismatch");
      checks++;
    end
  endtask
  initial begin
    #200;@(negedge clk_i);rst_ni=1;
    // Exhaust every stream/lane coordinate with distinct data.
    for(integer c=0;c<256;c++) begin
      upstream_valid_i=0;upstream_data_i=0;inject_valid_i=0;consume_i=0;
      upstream_valid_i[c]=1;upstream_data_i[c*8+:8]=c;tick();@(negedge clk_i);
    end
    for(integer t=0;t<2048;t++) begin
      for(integer c=0;c<256;c++) begin
        rng=rng*32'd1664525+32'd1013904223;
        upstream_valid_i[c]=rng[31];inject_valid_i[c]=rng[30];inject_valid_i[256+c]=rng[29];
        consume_i[c]=rng[28];consume_i[256+c]=rng[27];
        upstream_data_i[c*8+:8]=rng[7:0];inject_data_i[c*8+:8]=rng[15:8];inject_data_i[(256+c)*8+:8]=rng[23:16];
      end
      tick();@(negedge clk_i);
    end
    upstream_valid_i=0;inject_valid_i=0;consume_i=0;tick();@(negedge clk_i);
    rst_ni=0;#1;
    if(state_valid_o!==0 || state_data_o!==0) $fatal(1,"SRF reset mismatch");
    $display("PASS srf_leaf checks=%0d all_cells randomized_disjoint_and_conflict consume reset",checks);$finish;
  end
  initial begin #100000;$fatal(1,"SRF timeout");end
endmodule
