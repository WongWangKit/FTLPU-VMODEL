`timescale 1ns/1ps

// Standalone MEM boundary fixture. No RTL SRF, ICU, SXM, C2C or DMA instance.
module mem_p1_full_tb #(
  parameter integer DEPTH = 8192,
  parameter integer ACTIVE = DEPTH,
  parameter integer TILES = 4
);
  localparam integer H = 2, SLICES = 52, LEAVES = H*SLICES*2*TILES;
  localparam integer N=64*TILES, M=SLICES*2*TILES;
  logic clk = 0, rst_n = 0;
  logic [103:0] issue_valid [0:1];
  logic [3327:0] issue [0:1];
  logic [14*N-1:0] boundary_valid [0:1];
  logic [14*N*64-1:0] boundary_data [0:1];
  logic [14*M-1:0] feedback [0:1];
  wire [14*N-1:0] consume [0:1];
  wire [M-1:0] response_valid [0:1], response_dir [0:1], collision [0:1];
  wire [M*64-1:0] response_data [0:1];
  wire [M*5-1:0] response_stream [0:1];
  wire [M*4-1:0] response_boundary [0:1];
  wire [103:0] fault [0:1];
  wire busy [0:1];
  wire [207:0] bank_busy, north_valid;
  wire [6655:0] north_command;
  integer probe_row [0:LEAVES-1];
  wire [63:0] observed [0:LEAVES-1];
  logic [63:0] signature [0:LEAVES-1];
  logic audit_toggle = 0;

  for (genvar h = 0; h < H; h = h + 1) begin : gen_hemi
    mem_hemisphere #(.P_MEM_BANK_DEPTH_ROWS(DEPTH), .P_MEM_ACTIVE_ROWS(ACTIVE), .P_TILE_ROWS(TILES)) dut (
      .clk_i(clk), .rst_ni(rst_n), .bank_issue_valid_i(issue_valid[h]), .bank_issue_i(issue[h]),
      .boundary_state_valid_i(boundary_valid[h]), .boundary_state_data_i(boundary_data[h]),
      .external_producer_collision_i(feedback[h]), .boundary_consume_o(consume[h]),
      .producer_valid_o(response_valid[h]), .producer_data_o(response_data[h]),
      .producer_stream_dir_o(response_dir[h]), .producer_stream_idx_o(response_stream[h]),
      .producer_boundary_o(response_boundary[h]), .internal_mem_collision_o(collision[h]),
      .bank_fault_valid_o(fault[h]), .hemisphere_busy_o(busy[h])
    );
    for (genvar g = 0; g < 13; g = g + 1) begin : observe_group
      for (genvar s = 0; s < 4; s = s + 1) begin : observe_slice
        for (genvar b = 0; b < 2; b = b + 1) begin : observe_bank
          localparam integer BANK = (h*52+g*4+s)*2+b;
          assign bank_busy[BANK] = dut.gen_group[g].u_group.gen_slice[s].u_slice.bank_pipeline_busy_o[b];
          assign north_valid[BANK] = dut.gen_group[g].u_group.gen_slice[s].u_slice.bank_north_cmd_valid_o[b];
          assign north_command[BANK*32 +: 32] = dut.gen_group[g].u_group.gen_slice[s].u_slice.bank_north_cmd_o[b*32 +: 32];
          for (genvar t = 0; t < TILES; t = t + 1) begin : observe_tile
            localparam integer ID = BANK*TILES+t;
            assign observed[ID] = dut.gen_group[g].u_group.gen_slice[s].u_slice.gen_bank[b].u_logical_bank.gen_leaf[t].u_leaf.mem_array[probe_row[ID]];
            integer row;
            reg [63:0] digest;
            always @(audit_toggle) begin
              digest = 64'hcbf29ce484222325;
              for (row = 0; row < DEPTH; row = row + 1)
                digest = (digest ^ dut.gen_group[g].u_group.gen_slice[s].u_slice.gen_bank[b].u_logical_bank.gen_leaf[t].u_leaf.mem_array[row]) * 64'h100000001b3;
              signature[ID] = digest;
            end
          end
        end
      end
    end
  end

  integer fd, rc, version, p, active_rows, mode, cycles;
  integer seq, reset, ni, ns, ne, h, s, b, t, d, stream, boundary, cell_index, id;
  integer e_h[0:LEAVES-1], e_s[0:LEAVES-1], e_b[0:LEAVES-1], e_t[0:LEAVES-1], e_op[0:LEAVES-1];
  integer e_row[0:LEAVES-1], e_dir[0:LEAVES-1], e_stream[0:LEAVES-1];
  logic [7:0] e_mask[0:LEAVES-1], mask;
  logic [63:0] e_input[0:LEAVES-1], e_read[0:LEAVES-1], e_mem[0:LEAVES-1], e_lo[0:LEAVES-1], e_hi[0:LEAVES-1];
  logic [31:0] word;
  logic [63:0] data, expected_signature;
  logic [14*N-1:0] expected_consume[0:1];
  logic [M-1:0] expected_valid[0:1];
  logic [207:0] expected_busy, expected_north;
  logic [6655:0] expected_north_command;
  integer compared_cycles = 0, compared_reads = 0, memory_checks = 0;
  string path, magic;

  initial begin
    for (integer q = 0; q < LEAVES; q = q + 1) probe_row[q] = 0;
    for (integer q = 0; q < H; q = q + 1) begin
      issue_valid[q] = 0; issue[q] = 0; boundary_valid[q] = 0; boundary_data[q] = 'x; feedback[q] = 0;
    end
    if (!$value$plusargs("VECTORS=%s", path)) $fatal(1, "VECTORS missing");
    fd = $fopen(path, "r");
    if (!fd) $fatal(1, "cannot open vectors");
    rc = $fscanf(fd, "%s %d %d %d %d %d", magic, version, p, active_rows, mode, cycles);
    if (version == 2) begin
      rc = $fscanf(fd, "%d", t);
      if(rc!=1 || t!=TILES)$fatal(1,"MEM tile identity mismatch");
    end else if(TILES!=4)$fatal(1,"legacy vector requires T4");
    if ((version!=1 && version!=2) || magic != "MEM_P1" || p != DEPTH || active_rows != ACTIVE || mode != 0)
      $fatal(1, "MEM vector/config identity mismatch");
    for (integer cycle = 0; cycle < cycles; cycle = cycle + 1) begin
      rc = $fscanf(fd, "%d %d %d %d %d", seq, reset, ni, ns, ne);
      if (rc != 5 || seq != cycle || ne > LEAVES) $fatal(1, "MEM truncated frame cycle=%0d", cycle);
      rst_n = !reset;
      for (integer q = 0; q < H; q = q + 1) begin
        issue_valid[q] = 0; issue[q] = 0; boundary_valid[q] = 0; boundary_data[q] = 'x;
        expected_consume[q] = 0; expected_valid[q] = 0;
      end
      expected_busy = 0; expected_north = 0; expected_north_command = 0;
      for (integer q = 0; q < ni; q = q + 1) begin
        rc = $fscanf(fd, "%d %d %d %h", h, s, b, word);
        if (rc != 4) $fatal(1, "MEM truncated issue");
        issue_valid[h][s*2+b] = 1; issue[h][(s*2+b)*32 +: 32] = word;
      end
      for (integer q = 0; q < ns; q = q + 1) begin
        rc = $fscanf(fd, "%d %d %d %d %d %h %h", h, boundary, d, stream, t, mask, data);
        if (rc != 7) $fatal(1, "MEM truncated stimulus");
        cell_index = boundary*N+(d*32+stream)*TILES+t;
        // Deliberate MEM-only fixture projection; not a tested RTL lane adapter.
        boundary_valid[h][cell_index] = &mask;
        if (&mask) boundary_data[h][cell_index*64 +: 64] = data;
      end
      for (integer q = 0; q < ne; q = q + 1) begin
        rc = $fscanf(fd, "%d %d %d %d %d %d %d %d %h %h %h %h %h %h",
          e_h[q],e_s[q],e_b[q],e_t[q],e_op[q],e_row[q],e_dir[q],e_stream[q],
          e_mask[q],e_input[q],e_read[q],e_mem[q],e_lo[q],e_hi[q]);
        if (rc != 14) $fatal(1, "MEM truncated event");
        h=e_h[q]; s=e_s[q]; b=e_b[q]; t=e_t[q]; d=e_dir[q]; stream=e_stream[q];
        expected_busy[(h*52+s)*2+b] = 1;
        if (e_op[q] == 0) expected_valid[h][s*2*TILES+b*TILES+t] = 1;
        if (e_op[q] == 1 && e_mask[q] == 8'hff) begin
          boundary = s/4+d;
          expected_consume[h][boundary*N+(d*32+stream)*TILES+t] = 1;
        end
        if (t == TILES-1) begin
          id=(h*52+s)*2+b; expected_north[id]=1;
          expected_north_command[id*32 +: 32] = ((e_op[q]==2)<<31) | (e_row[q]<<15) |
                                                ((d*32+stream)<<3) | (e_op[q]!=0);
        end
        probe_row[((h*52+s)*2+b)*TILES+t] = e_row[q];
      end
      #4;
      if (bank_busy !== expected_busy) $fatal(1, "MEM bank busy cycle=%0d",cycle);
      for (integer q = 0; q < H; q = q + 1)
        if (consume[q] !== expected_consume[q]) $fatal(1, "MEM consume cycle=%0d h=%0d",cycle,q);
      clk = 1; #1;
      if (north_valid !== expected_north) $fatal(1, "MEM north valid cycle=%0d",cycle);
      for (integer q = 0; q < 208; q = q + 1)
        if (expected_north[q] && north_command[q*32 +: 32] !== expected_north_command[q*32 +: 32])
          $fatal(1, "MEM north payload cycle=%0d bank=%0d",cycle,q);
      for (integer q = 0; q < H; q = q + 1) begin
        if (response_valid[q] !== expected_valid[q]) $fatal(1, "MEM response valid cycle=%0d h=%0d",cycle,q);
        if (fault[q] !== 104'b0 || collision[q] !== '0) $fatal(1, "MEM unexpected fault cycle=%0d",cycle);
      end
      for (integer q = 0; q < ne; q = q + 1) begin
        h=e_h[q]; s=e_s[q]; b=e_b[q]; t=e_t[q]; d=e_dir[q]; stream=e_stream[q];
        id=((h*52+s)*2+b)*TILES+t;
        if (observed[id] !== e_mem[q]) $fatal(1, "MEM storage cycle=%0d h=%0d s=%0d b=%0d t=%0d row=%0d expected=%h actual=%h",cycle,h,s,b,t,e_row[q],e_mem[q],observed[id]);
        memory_checks = memory_checks+1;
        if (e_op[q] == 0) begin
          if (response_data[h][(s*2*TILES+b*TILES+t)*64 +: 64] !== e_read[q] ||
              response_dir[h][s*2*TILES+b*TILES+t] !== (d!=0) ||
              response_stream[h][(s*2*TILES+b*TILES+t)*5 +: 5] !== 5'(stream) ||
              response_boundary[h][(s*2*TILES+b*TILES+t)*4 +: 4] !== 4'(s/4+1-d))
            $fatal(1, "MEM response metadata/byte cycle=%0d h=%0d s=%0d b=%0d t=%0d",cycle,h,s,b,t);
          compared_reads = compared_reads+1;
        end
        probe_row[id] = (e_row[q]+ACTIVE-1)%ACTIVE;
      end
      #1;
      for (integer q = 0; q < ne; q = q + 1) begin
        id=((e_h[q]*52+e_s[q])*2+e_b[q])*TILES+e_t[q];
        if (observed[id] !== e_lo[q]) $fatal(1, "MEM lower neighbor cycle=%0d event=%0d",cycle,q);
        probe_row[id] = (e_row[q]+1)%ACTIVE;
      end
      #1;
      for (integer q = 0; q < ne; q = q + 1) begin
        id=((e_h[q]*52+e_s[q])*2+e_b[q])*TILES+e_t[q];
        if (observed[id] !== e_hi[q]) $fatal(1, "MEM upper neighbor cycle=%0d event=%0d",cycle,q);
      end
      clk=0; #1; compared_cycles=compared_cycles+1;
    end
    rc=$fscanf(fd, "%s %d",magic,ne);
    if (rc!=2 || magic!="END" || ne!=LEAVES) $fatal(1,"MEM missing full-storage audit");
    audit_toggle=~audit_toggle; #1;
    for (integer q=0;q<ne;q=q+1) begin
      rc=$fscanf(fd,"%d %d %d %d %h",h,s,b,t,expected_signature);
      id=((h*52+s)*2+b)*TILES+t;
      if(rc!=5 || signature[id]!==expected_signature)
        $fatal(1,"MEM full-storage hash h=%0d s=%0d b=%0d t=%0d expected=%h actual=%h",h,s,b,t,expected_signature,signature[id]);
    end
    $fclose(fd);
    $display("MEM_FULL TEST_PASS cycles=%0d reads=%0d memory_checks=%0d signatures=%0d H=2 slices=52 P=%0d E=%0d policy=Error L1_ONLY",
      compared_cycles,compared_reads,memory_checks,LEAVES,DEPTH,ACTIVE);
    $finish;
  end
endmodule

module mem_p1_full_error_tb; mem_p1_full_tb test(); endmodule
module mem_p1_full_64_tb; mem_p1_full_tb #(.DEPTH(64)) test(); endmodule
module mem_p1_full_32768_tb; mem_p1_full_tb #(.DEPTH(32768)) test(); endmodule
module mem_p1_full_active64_tb; mem_p1_full_tb #(.ACTIVE(64)) test(); endmodule
