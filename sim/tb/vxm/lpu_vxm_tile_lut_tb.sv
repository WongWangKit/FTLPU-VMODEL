`timescale 1ns/1ps

module lpu_vxm_tile_lut_tb;
  localparam integer FUNCTIONS = 4;
  localparam integer LANES = 8;
  localparam integer TILES = 2;
  localparam integer ADDRESS_WIDTH = 6;
  localparam integer STAGE_WIDTH = 4;
  localparam integer TILE_REQUESTS = FUNCTIONS*LANES;

  logic clk;
  logic rst_n;
  logic config_valid;
  logic [1:0] config_function;
  logic [15:0] config_input_min;
  logic [15:0] config_segment_width;
  logic write_valid;
  logic [1:0] write_function;
  logic [ADDRESS_WIDTH-1:0] write_address;
  logic [15:0] write_k;
  logic [15:0] write_b;
  logic [TILES*TILE_REQUESTS-1:0] request_valid;
  logic [TILES*TILE_REQUESTS*ADDRESS_WIDTH-1:0] request_address;
  logic [TILES*TILE_REQUESTS*STAGE_WIDTH-1:0] request_stage;
  wire [TILES*TILE_REQUESTS-1:0] response_valid;
  wire [TILES*TILE_REQUESTS*STAGE_WIDTH-1:0] response_stage;
  wire [TILES*TILE_REQUESTS*16-1:0] response_k;
  wire [TILES*TILE_REQUESTS*16-1:0] response_b;
  wire [TILES*FUNCTIONS-1:0] configured;
  wire [TILES*FUNCTIONS*16-1:0] input_min;
  wire [TILES*FUNCTIONS*16-1:0] segment_width;
  logic [49:0] write_log;
  wire [TILES*TILE_REQUESTS*50-1:0] response_log;
  wire [TILES-1:0] fault;

  always #5 clk = ~clk;

  // Independent Superlane stores receive the same programming broadcast.
  for (genvar tile = 0; tile < TILES; tile++) begin : g_tile
    lpu_vxm_tile_lut #(.FUNCTION_COUNT(FUNCTIONS), .LANES(LANES)) dut (
      .clk_i(clk), .rst_ni(rst_n),
      .config_valid_i(config_valid), .config_function_i(config_function),
      .config_input_min_i(config_input_min),
      .config_segment_width_i(config_segment_width),
      .write_valid_i(write_valid), .write_function_i(write_function),
      .write_address_i(write_address), .write_k_i(write_k), .write_b_i(write_b),
      .write_log_i(write_log),
      .request_valid_i(request_valid[tile*TILE_REQUESTS +: TILE_REQUESTS]),
      .request_address_i(request_address[tile*TILE_REQUESTS*ADDRESS_WIDTH +: TILE_REQUESTS*ADDRESS_WIDTH]),
      .request_stage_i(request_stage[tile*TILE_REQUESTS*STAGE_WIDTH +: TILE_REQUESTS*STAGE_WIDTH]),
      .response_valid_o(response_valid[tile*TILE_REQUESTS +: TILE_REQUESTS]),
      .response_stage_o(response_stage[tile*TILE_REQUESTS*STAGE_WIDTH +: TILE_REQUESTS*STAGE_WIDTH]),
      .response_k_o(response_k[tile*TILE_REQUESTS*16 +: TILE_REQUESTS*16]),
      .response_b_o(response_b[tile*TILE_REQUESTS*16 +: TILE_REQUESTS*16]),
      .response_log_o(response_log[tile*TILE_REQUESTS*50 +: TILE_REQUESTS*50]),
      .configured_o(configured[tile*FUNCTIONS +: FUNCTIONS]),
      .input_min_o(input_min[tile*FUNCTIONS*16 +: FUNCTIONS*16]),
      .segment_width_o(segment_width[tile*FUNCTIONS*16 +: FUNCTIONS*16]),
      .fault_o(fault[tile])
    );
  end

  function automatic logic [49:0] expected_log(input integer address);
    expected_log = {28'h9abcdef, 22'h2aaaaa} ^ (50'(address) << 24) ^ 50'(address);
  endfunction

  function automatic logic [15:0] expected_k(
    input integer function_id,
    input integer address
  );
    // EXP transports the high UQ1.25 half in 13 bits; RECIP and RSQRT use
    // UQ1.15 coefficient containers.
    expected_k = function_id == 0 ? 16'h1000 + address :
      (function_id == 1 ? 16'h8000 + address :
       16'h1000 + function_id*16'h0100 + address);
  endfunction

  function automatic logic [15:0] expected_b(
    input integer function_id,
    input integer address
  );
    expected_b = function_id == 0 ? 16'h0100 + address :
      (function_id == 1 ? 16'h4000 + address :
       16'h8000 + function_id*16'h0100 + address);
  endfunction

  function automatic integer request_index(
    input integer tile,
    input integer function_id,
    input integer lane
  );
    request_index = tile*TILE_REQUESTS + function_id*LANES + lane;
  endfunction

  task automatic configure(input integer function_id);
    begin
      @(negedge clk);
      config_valid = 1'b1;
      config_function = function_id[1:0];
      config_input_min = 16'hbc00 + function_id;
      config_segment_width = 16'h3800;
      @(posedge clk);
      @(negedge clk);
      config_valid = 1'b0;
    end
  endtask

  task automatic write_row(
    input integer function_id,
    input integer address
  );
    begin
      @(negedge clk);
      write_valid = 1'b1;
      write_function = function_id[1:0];
      write_address = address[ADDRESS_WIDTH-1:0];
      write_k = expected_k(function_id, address);
      write_b = expected_b(function_id, address);
      write_log = expected_log(address);
      @(posedge clk);
      @(negedge clk);
      write_valid = 1'b0;
    end
  endtask

  task automatic drive_lane_group(
    input integer tile,
    input integer function_id,
    input integer stage_base
  );
    begin
      for (integer lane = 0; lane < LANES; lane++) begin
        integer index;
        index = request_index(tile, function_id, lane);
        request_valid[index] = 1'b1;
        request_address[index*ADDRESS_WIDTH +: ADDRESS_WIDTH] =
          ADDRESS_WIDTH'(lane + tile*LANES);
        request_stage[index*STAGE_WIDTH +: STAGE_WIDTH] =
          stage_base + lane;
      end
    end
  endtask

  initial begin
    clk = 1'b0;
    rst_n = 1'b0;
    config_valid = 1'b0;
    config_function = '0;
    config_input_min = '0;
    config_segment_width = '0;
    write_valid = 1'b0;
    write_function = '0;
    write_address = '0;
    write_k = '0;
    write_b = '0;
    write_log = '0;
    request_valid = '0;
    request_address = '0;
    request_stage = '0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;

    for (integer function_id = 0;
         function_id < FUNCTIONS; function_id++) begin
      configure(function_id);
      for (integer address = 0; address < TILES*LANES; address++)
        write_row(function_id, address);
    end
    if (configured !== {TILES*FUNCTIONS{1'b1}})
      $fatal(1, "all private function banks must be configured");
    for (integer tile=0; tile<TILES; tile++)
      for (integer f=0; f<FUNCTIONS; f++)
        if (input_min[(tile*FUNCTIONS+f)*16 +: 16] !== 16'(16'hbc00+f) ||
            segment_width[(tile*FUNCTIONS+f)*16 +: 16] !== 16'h3800)
          $fatal(1, "configuration broadcast mismatch");

    // Every cycle both Superlanes access every function and every Lane.
    // Same function/Lane requests use different addresses and Stage tags.
    // Alternate the address groups on consecutive cycles to catch stale returns.
    @(negedge clk);
    for (integer cycle=0; cycle<4; cycle++) begin
      request_valid = '0;
      for (integer tile=0; tile<TILES; tile++)
        for (integer f=0; f<FUNCTIONS; f++) begin
          drive_lane_group(tile, f, tile*8 + cycle);
          for (integer lane=0; lane<LANES; lane++)
            request_address[request_index(tile,f,lane)*ADDRESS_WIDTH +: ADDRESS_WIDTH] =
              ADDRESS_WIDTH'(lane + ((tile+cycle)%TILES)*LANES);
        end
      @(posedge clk);
      @(negedge clk);
      if (response_valid !== '1 || (|fault))
        $fatal(1, "simultaneous private SRAM reads failed");
      for (integer tile=0; tile<TILES; tile++)
        for (integer f=0; f<FUNCTIONS; f++) begin
          for (integer lane=0; lane<LANES; lane++) begin
            integer index, address;
            index=request_index(tile,f,lane);
            address=lane+((tile+cycle)%TILES)*LANES;
            if (response_stage[index*STAGE_WIDTH +: STAGE_WIDTH] !== STAGE_WIDTH'(tile*8+lane+cycle))
              $fatal(1, "private response Stage tag mismatch");
            if (f==3) begin
              if (response_log[index*50 +: 50] !== expected_log(address) ||
                  response_k[index*16 +: 16] !== 16'b0 || response_b[index*16 +: 16] !== 16'b0)
                $fatal(1, "private Log response mismatch");
            end else if (response_k[index*16 +: 16] !== expected_k(f,address) ||
                         response_b[index*16 +: 16] !== expected_b(f,address) ||
                         response_log[index*50 +: 50] !== 50'b0)
              $fatal(1, "private coefficient response mismatch");
          end
        end
    end
    request_valid='0;
    @(posedge clk);
    @(negedge clk);
    if (response_valid !== '0) $fatal(1, "response valid did not clear");

    // EXP stores two packed 13-bit halves. RECIP uses the complete 16-bit
    // containers as UQ1.15, so only EXP has unused upper container bits.
    @(negedge clk);
    write_valid = 1'b1;
    write_function = 2'd0;
    write_address = 6'd9;
    write_k = 16'h2000;
    write_b = 16'h0400;
    @(posedge clk);
    @(negedge clk);
    if (fault !== '1)
      $fatal(1, "EXP packed UQ1.25 half wider than 13 bits did not fault");
    write_valid = 1'b0;
    write_k = '0;
    write_b = '0;
    @(posedge clk);
    @(negedge clk);
    write_valid = 1'b1;
    write_function = 2'd1;
    write_address = 6'd9;
    write_k = 16'h8000;
    write_b = 16'h6000;
    @(posedge clk);
    @(negedge clk);
    if (|fault)
      $fatal(1, "legal full-width RECIP UQ1.15 coefficients faulted");
    write_valid = 1'b0;
    write_k = '0;
    write_b = '0;

    // A reset clears all private configuration and outstanding read tags.
    @(negedge clk);
    drive_lane_group(0, 3, 0);
    drive_lane_group(1, 3, 8);
    rst_n=1'b0;
    #1;
    if (response_valid !== '0 || configured !== '0)
      $fatal(1, "private LUT state survived reset");

    $display("LPU_VXM_TILE_LUT_TB_PASS");
    $finish;
  end

  initial begin #100000; $fatal(1, "private LUT test timeout"); end
endmodule
