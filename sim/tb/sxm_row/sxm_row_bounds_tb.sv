`timescale 1ns/1ps
module sxm_row_bounds_tb #(parameter integer T=4);
  reg clk_i=0, rst_ni=0;
  always #5 clk_i=~clk_i;
  reg [255:0] cmd=0;
  reg [T*1024-1:0] sr_read_data_i=0;
  reg [T*16-1:0] sr_read_valid_i=0;
  wire [T*96-1:0] sr_read_req_o, sr_write_sel_o;
  wire [T*16-1:0] sr_consume_o, sr_write_valid_o;
  wire [T*1024-1:0] sr_write_data_o;
  wire [3:0] fault_o;
  wire busy_o;
  sxm_row_core #(.T(T)) dut(
    .clk_i,.rst_ni,.ctrl_valid_i(cmd[0]),.ctrl_op_i(cmd[2:1]),.ctrl_ctx_i(cmd[3]),
    .ctrl_index_i(cmd[6:4]),.ctrl_data_i(cmd[135:8]),
    .cap_valid_i(cmd[136]),.cap_ctx_i(cmd[137]),.cap_tile_i(cmd[140:138]),
    .cap_group_i(cmd[143:141]),.cap_row_i(cmd[147:144]),
    .p_valid_i(cmd[148]),.p_ctx_i(cmd[149]),.p_dest_i(cmd[152:150]),.p_source_i(cmd[155:153]),
    .p_row_i(cmd[159:156]),.p_paired_i(cmd[160]),.p_branch_i(cmd[161]),.p_sequence_i(cmd[167:162]),
    .run_valid_i(cmd[168+:T]),.run_ctx_i(cmd[176]),.run_delay_i(cmd[192:177]),
    .run_interval_i(cmd[208:193]),.run_count_i(cmd[214:209]),.run_sequence_i(cmd[220:215]),
    .sr_read_req_o,.sr_read_valid_i,.sr_read_data_i,.sr_consume_o,
    .sr_write_valid_o,.sr_write_sel_o,.sr_write_data_o,.fault_o,.busy_o,
    .compat_write_rows_i('0),.compat_write_data_i('0),.compat_read_data_o());
  integer d,r,l,p,k,j,outputs=0,control_bits,payload_bits;
  reg [127:0] cfg;
  reg [31:0] v;
  task automatic edge_step;
    begin #1;if(fault_o!=0) $fatal(1,"unexpected bounds fault=%h",fault_o);@(posedge clk_i);#1;end
  endtask
  initial begin
    control_bits=$bits(dut.context_q)+$bits(dut.tile_q)+$bits(dut.context_valid_q)+$bits(dut.tile_valid_q)
      +$bits(dut.slot_valid_q)+$bits(dut.slot_owner_q)+$bits(dut.slot_claimed_q)+$bits(dut.written_q)
      +$bits(dut.read_q)+$bits(dut.slot_dest_q)+$bits(dut.pipe_valid_q)+$bits(dut.pipe_ctx_q)
      +$bits(dut.pipe_dest_q)+$bits(dut.pipe_branches_q)+$bits(dut.pair_fill_q)+$bits(dut.pair_ready_q)
      +$bits(dut.pair_ctx_q)+$bits(dut.pair_sequence_q)+$bits(dut.run_active_q)+$bits(dut.run_ctx_q)
      +$bits(dut.high_q)+$bits(dut.timer_q)+$bits(dut.interval_q)+$bits(dut.remaining_q)+$bits(dut.sequence_q);
    payload_bits=$bits(dut.data_q)+$bits(dut.pair_data_q)+$bits(dut.pipe_data_q);
    if(payload_bits!=2048*T*T+512*T+512 || control_bits!=262+$clog2(T)+316*T+(19+$clog2(T))*T*T)
      $fatal(1,"register ledger");
    repeat(2) @(negedge clk_i); rst_ni=1;
    @(negedge clk_i);cmd=0;cfg=0;
    for(p=0;p<16;p=p+1)cfg[6*p+:6]=6'(32+p);
    cfg[114]=1;cmd[0]=1;cmd[2:1]=1;cmd[135:8]=cfg;edge_step();
    for(d=0;d<T;d=d+1)begin
      @(negedge clk_i);cmd=0;cfg=0;
      for(p=0;p<16;p=p+1)cfg[6*p+:6]=6'(p);
      for(l=0;l<8;l=l+1)cfg[96+3*l+:3]=3'(l);
      cfg[122:120]=3'(d);cmd[0]=1;cmd[2:1]=2;cmd[6:4]=3'(d);cmd[135:8]=cfg;edge_step();
    end
    @(negedge clk_i);cmd=0;cmd[0]=1;cmd[2:1]=3;edge_step();
    for(r=0;r<8;r=r+1)begin
      @(negedge clk_i);cmd=0;cmd[136]=1;cmd[147:144]=4'(r);sr_read_valid_i=15;
      for(l=0;l<8;l=l+1)for(p=0;p<4;p=p+1)begin
        v=32'h8123abcd+32'(r)*17+32'(l)*19;sr_read_data_i[p*64+l*8+:8]=v[p*8+:8];
      end
      if(r==7)begin
        // CAP succeeds, P is too early: no last-row bypass.
        cmd[148]=1;#1;
        if(fault_o!==4'b0100 || sr_consume_o!=15) $fatal(1,"last capture/P atomicity");
        @(posedge clk_i);#1;
      end else edge_step();
    end
    @(negedge clk_i);cmd=0;sr_read_valid_i=0;
    cmd[168]=1;cmd[192:177]=16'hffff;cmd[208:193]=4;cmd[214:209]=63;cmd[220:215]=1;edge_step();
    for(k=1;k<=65536+4*62;k=k+1)begin
      @(negedge clk_i);cmd=0;
      if(k>=65534 && k<=65534+4*62 && (k-65534)%4==0)begin
        cmd[148]=1;cmd[167:162]=6'(1+(k-65534)/4);
      end
      #1;
      if(fault_o!=0) $fatal(1,"timer/sequence fault k=%0d",k);
      if(k>=65536 && (k-65536)%4==0)begin
        if(sr_write_valid_o!=15) $fatal(1,"max timer due k=%0d",k);
        for(l=0;l<8;l=l+1)for(p=0;p<4;p=p+1)begin
          v=32'h8123abcd+32'(l)*17;
          if(sr_write_data_o[p*64+l*8+:8]!==v[p*8+:8]) $fatal(1,"max timer data");
        end
        outputs=outputs+1;
      end else if(sr_write_valid_o!=0) $fatal(1,"early/late timer output k=%0d",k);
      @(posedge clk_i);#1;
    end
    if(outputs!=63 || dut.run_active_q!=0 || !busy_o) $fatal(1,"counter exhaustion/retained block busy");
    @(negedge clk_i);rst_ni=0;#1;if(busy_o) $fatal(1,"reset valid state");
    $display("SXM_ROW_BOUNDS PASS T=%0d payload_bits=%0d control_bits=%0d delay_max=65535 sequence_max=63 count_max=63",T,payload_bits,control_bits);
    $finish;
  end
endmodule
