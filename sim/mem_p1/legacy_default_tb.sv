`timescale 1ns/1ps

module mem_p1_legacy_default_tb;
  logic clk = 0;
  logic rst_n = 0;
  logic [1:0] issue_valid;
  logic [63:0] issue;
  logic [255:0] stream_valid;
  logic [16383:0] stream_data;
  wire [511:0] consume [0:1];
  wire [7:0] read_valid [0:1];
  wire [511:0] read_data [0:1];
  wire [7:0] read_dir [0:1];
  wire [39:0] read_stream [0:1];
  wire [1:0] fault [0:1], busy [0:1], north_valid [0:1];
  wire [5:0] fault_code [0:1];
  wire [63:0] north [0:1];
  integer cycle, fd;
  string trace;

  for (genvar n = 0; n < 2; n = n + 1) begin : gen_depth
    mem_slice #(.P_MEM_BANK_DEPTH_ROWS(32768)) dut (
      .clk_i(clk), .rst_ni(rst_n), .bank_issue_valid_i(issue_valid), .bank_issue_i(issue),
      .sr_state_valid_i(stream_valid), .sr_state_data_i(stream_data), .producer_collision_i(8'b0),
      .sr_consume_o(consume[n]), .sr_inject_valid_o(read_valid[n]), .sr_inject_data_o(read_data[n]),
      .sr_inject_stream_dir_o(read_dir[n]), .sr_inject_stream_idx_o(read_stream[n]),
      .mem_fault_valid_o(fault[n]), .mem_fault_code_o(fault_code[n]),
      .bank_pipeline_busy_o(busy[n]), .bank_north_cmd_valid_o(north_valid[n]), .bank_north_cmd_o(north[n])
    );
  end

  function automatic [31:0] command(input integer op, row, stream, tap);
    command = (tap << 31) | (row << 15) | (stream << 3) | op;
  endfunction

  task automatic tick(input bit record_trace);
    #4;
    if (record_trace)
      for (integer n = 0; n < 2; n = n + 1)
        $fwrite(fd, "%0d %0d PRE %h %h\n", cycle, n, consume[n], busy[n]);
    clk = 1;
    #1;
    if (record_trace)
      for (integer n = 0; n < 2; n = n + 1) begin
        $fwrite(fd, "%0d %0d POST %h %h %h %h %h %h\n", cycle, n, read_valid[n],
                read_dir[n], read_stream[n], fault[n], fault_code[n], north_valid[n]);
        for (integer p = 0; p < 8; p = p + 1)
          if (read_valid[n][p]) $fwrite(fd, "BYTE %0d %h\n", p, read_data[n][p*64 +: 64]);
      end
    #1; clk = 0; #1;
  endtask

  initial begin
    if (!$value$plusargs("TRACE=%s", trace)) $fatal(1, "TRACE missing");
    fd = $fopen(trace, "w");
    issue_valid = 0; issue = 0; stream_valid = '1;
    for (integer c = 0; c < 256; c = c + 1)
      stream_data[c*64 +: 64] = 64'h0123456789abcdef ^ (64'h102030405060708 * (c+1));
    tick(0); rst_n = 1;
    // Observe the known cold-storage gap separately, not as a passing zero test.
    issue_valid = 1; issue[31:0] = command(0, 32767, 0, 0); tick(0);
    $display("BASELINE_COLD_OBSERVATION unknown=%0d data=%h", $isunknown(read_data[0][63:0]), read_data[0][63:0]);
    issue_valid = 0; repeat (5) tick(0);
    for (cycle = 0; cycle < 64; cycle = cycle + 1) begin
      issue_valid = 0; issue = 0;
      if (cycle < 12) begin
        issue_valid = 3;
        issue[31:0] = command(1, (32764 + cycle % 4), cycle % 64, cycle % 2);
        issue[63:32] = command(1, (32764 + cycle % 4), (cycle+32) % 64, 0);
      end else if (cycle >= 18 && cycle < 42) begin
        issue_valid = 3;
        issue[31:0] = command(0, (32764 + cycle % 4), (cycle*3) % 64, 0);
        issue[63:32] = command(0, (32764 + cycle % 4), (cycle*7) % 64, 0);
      end
      if (cycle == 48) rst_n = 0;
      if (cycle == 49) rst_n = 1;
      if (cycle >= 52 && cycle < 56) begin
        issue_valid = 3;
        issue[31:0] = command(0, (32764 + cycle % 4), cycle % 64, 0);
        issue[63:32] = command(0, (32764 + cycle % 4), (cycle+32) % 64, 0);
      end
      tick(1);
    end
    $fclose(fd);
    $display("MEM_BASELINE TEST_PASS cycles=64 depths=32768,32768");
    $finish;
  end
endmodule
