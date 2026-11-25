module lpu_mxm_slice #(
  parameter integer TILES=4,
  parameter bit STREAMING_VECTOR=0,
  parameter integer LOCAL_MXM_INDEX = 0,
  parameter integer ACCUMULATOR_BLOCK_COUNT =
    lpu_pkg::MXM_ACCUMULATOR_BLOCK_COUNT
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic discard_partial_sums_i,
  input  logic run_i,
  input  logic load_issue_valid_i,
  input  logic [47:0] load_issue_instruction_i,
  input  logic dequant_issue_valid_i,
  input  logic [15:0] dequant_issue_instruction_i,
  input  logic compute_issue_valid_i,
  input  logic [48:0] compute_issue_instruction_i,
  input  logic [4*32-1:0] east_from_sxm_valid_i,
  input  logic [4*32*64-1:0] east_from_sxm_data_i,
  input  logic [4*32-1:0] external_west_valid_i,
  input  logic [4*32*64-1:0] external_west_data_i,
  output logic [4*32-1:0] east_external_valid_o,
  output logic [4*32*64-1:0] east_external_data_o,
  output logic [4*32-1:0] west_to_sxm_valid_o,
  output logic [4*32*64-1:0] west_to_sxm_data_o,
  output logic fault_o,
  output logic conflict_o,
  output logic execution_busy_o
);
  logic [TILES-1:0] load_row_valid;
  logic [TILES*48-1:0] load_row_instruction;
  logic [TILES-1:0] dequant_row_valid;
  logic [TILES*16-1:0] dequant_row_instruction;
  wire [3:0] compute_row_valid;
  wire [TILES-1:0] native_compute_valid;
  assign compute_row_valid=4'(native_compute_valid);
  logic [4*48-1:0] compute_row_instruction;
  logic [TILES*49-1:0] compute_wave;
  wire [3:0] row_bf16;
  wire result_bf16;
  for(genvar t=0;t<4;t++) begin : gen_format
    if(t<TILES) begin
      assign compute_row_instruction[t*48+:48]=compute_wave[t*49+:48];
      assign row_bf16[t]=compute_wave[t*49+48];
    end else begin
      assign compute_row_instruction[t*48+:48]='0;
      assign row_bf16[t]=1'b0;
    end
  end
  logic [4*32-1:0] load_consumed;
  logic [4*32-1:0] compute_consumed, scalar_consumed, vector_consumed;
  wire [127:0] vector_wvalid, scalar_wvalid;
  wire [8191:0] vector_wdata, scalar_wdata;
  wire [3:0] scalar_row_valid;
  logic [2*4*4*8*8*16-1:0] weight_bits;
  logic [2*4*4-1:0] cell_valid;
  wire vector_fault,vector_busy;
  for(genvar i=0;i<4;i++)begin
    assign scalar_row_valid[i]=compute_row_valid[i] && (!STREAMING_VECTOR || compute_row_instruction[48*i+46]);
  end
  if(STREAMING_VECTOR)begin : gen_vector
    lpu_mxm_vector_array #(.T(TILES),.ACC_BLOCKS(ACCUMULATOR_BLOCK_COUNT)) u_array(
      .issue_valid_i(compute_issue_valid_i),.issue_word_i(compute_issue_instruction_i),
      .clk_i,.rst_ni,.run_i,.discard_partial_sums_i,.valid_i(compute_row_valid),.bf16_i(row_bf16),.words_i(compute_row_instruction),
      .east_valid_i(east_from_sxm_valid_i),.east_data_i(east_from_sxm_data_i),
      .weights_i(weight_bits),.cell_valid_i(cell_valid),.consumed_o(vector_consumed),
      .west_valid_o(vector_wvalid),.west_data_o(vector_wdata),.busy_o(vector_busy),.fault_o(vector_fault));
  end else begin
    assign {vector_consumed,vector_wvalid,vector_wdata,vector_busy,vector_fault}='0;
  end
  assign compute_consumed=scalar_consumed|vector_consumed;
  logic result_valid;
  logic [8*32*32-1:0] result_values;
  logic [12:0] result_address;
  logic [5:0] result_stream_base;
  logic result_stream_destination;
  logic result_clear;
  logic result_block_mode;
  logic result_ready;
  logic [4*32-1:0] accumulator_produced_valid;
  logic [4*32*64-1:0] accumulator_produced_data;
  logic load_fault;
  logic compute_fault;
  logic accumulator_fault;
  logic accumulator_pending;
  logic conflict_d;

  // Legacy datapath cannot consume overlapping batch commands. Keep its
  // compatibility control isolated; the new array uses lpu_mxm_frontend.
  lpu_mxm_legacy_control #(.TILES(TILES)) u_control (
    .clk_i,
    .rst_ni,
    .load_valid_i(load_issue_valid_i),
    .load_instruction_i(load_issue_instruction_i),
    .dequant_valid_i(dequant_issue_valid_i),
    .dequant_instruction_i(dequant_issue_instruction_i),
    .compute_valid_i(compute_issue_valid_i),
    .compute_instruction_i(compute_issue_instruction_i),
    .load_row_valid_o(load_row_valid),
    .load_row_instruction_o(load_row_instruction),
    .dequant_row_valid_o(dequant_row_valid),
    .dequant_row_instruction_o(dequant_row_instruction),
    .compute_row_valid_o(native_compute_valid),
    .compute_row_instruction_o(compute_wave)
  );

  lpu_mxm_weight_buffer #(
    .TILES(TILES),
    .LOCAL_MXM_INDEX(LOCAL_MXM_INDEX)
  ) u_weight_buffer (
    .clk_i,
    .rst_ni,
    .run_i,
    .load_row_valid_i(load_row_valid),
    .load_row_instruction_i(load_row_instruction),
    .dequant_row_valid_i(dequant_row_valid),
    .dequant_row_instruction_i(dequant_row_instruction),
    .east_valid_i(east_from_sxm_valid_i),
    .east_data_i(east_from_sxm_data_i),
    .east_consumed_o(load_consumed),
    .weight_bits_o(weight_bits),
    .cell_valid_o(cell_valid),
    .fault_o(load_fault)
  );

  lpu_mxm_compute #(
    .TILES(TILES),
    .ACCUMULATOR_BLOCK_COUNT(ACCUMULATOR_BLOCK_COUNT)
  ) u_compute (
    .clk_i,
    .rst_ni,
    .run_i,
    .row_bf16_i(row_bf16), .result_bf16_o(result_bf16),
    .compute_row_valid_i(scalar_row_valid),
    .compute_row_instruction_i(compute_row_instruction),
    .east_valid_i(east_from_sxm_valid_i),
    .east_data_i(east_from_sxm_data_i),
    .weight_bits_i(weight_bits),
    .cell_valid_i(cell_valid),
    .east_consumed_o(scalar_consumed),
    .result_valid_o(result_valid),
    .result_values_o(result_values),
    .result_address_o(result_address),
    .result_stream_base_o(result_stream_base),
    .result_stream_destination_o(result_stream_destination),
    .result_clear_o(result_clear),
    .result_block_mode_o(result_block_mode),
    .result_ready_i(result_ready),
    .fault_o(compute_fault)
  );

  if(STREAMING_VECTOR)begin: gen_block_only
    // Vector storage is owned by the array. Only block-mode requests are
    // routed to this distinct block accumulator; no duplicate vector SRAM.
    lpu_mxm_block_accumulator #(.BLOCKS(TILES),.ACCUMULATOR_BLOCK_COUNT(ACCUMULATOR_BLOCK_COUNT)) u_block(
      .clk_i,.rst_ni,.run_i,.discard_partial_sums_i,.write_valid_i(result_valid && result_block_mode),
      .write_bf16_i(result_bf16),.read_bf16_i(row_bf16),.write_values_i(result_values),
      .write_address_i(result_address),.write_stream_base_i(result_stream_base),.write_clear_i(result_clear),
      .write_stream_destination_i(result_stream_destination),.write_ready_o(result_ready),
      .read_row_valid_i(scalar_row_valid),.read_row_instruction_i(compute_row_instruction),
      .west_valid_o(scalar_wvalid),.west_data_o(scalar_wdata),.fault_o(accumulator_fault),.pending_o(accumulator_pending));
  end else
  lpu_mxm_shared_accumulator #(
    .BLOCKS(TILES),
    .ACCUMULATOR_BLOCK_COUNT(ACCUMULATOR_BLOCK_COUNT)
  ) u_accumulator (
    .clk_i,
    .rst_ni,
    .run_i,
    .write_bf16_i(result_bf16), .read_bf16_i(row_bf16),
    .write_valid_i(result_valid),
    .write_block_mode_i(result_block_mode),
    .write_values_i(result_values),
    .write_address_i(result_address),
    .write_stream_base_i(result_stream_base),
    .write_stream_destination_i(result_stream_destination),
    .write_clear_i(result_clear),
    .write_ready_o(result_ready),
    .read_row_valid_i(scalar_row_valid),
    .read_row_instruction_i(compute_row_instruction),
    .west_valid_o(scalar_wvalid),
    .west_data_o(scalar_wdata),
    .fault_o(accumulator_fault), .pending_o(accumulator_pending)
  );

  assign accumulator_produced_valid=scalar_wvalid|vector_wvalid;
  for(genvar k=0;k<128;k++)assign accumulator_produced_data[k*64+:64]=
    vector_wvalid[k]?vector_wdata[k*64+:64]:scalar_wdata[k*64+:64];
  always_comb begin
    east_external_valid_o = east_from_sxm_valid_i &
      ~(load_consumed | compute_consumed);
    east_external_data_o = east_from_sxm_data_i;
    west_to_sxm_valid_o = external_west_valid_i;
    west_to_sxm_data_o = external_west_data_i;
    conflict_d = |(scalar_wvalid & vector_wvalid);
    if (|(load_consumed & compute_consumed))
      conflict_d = 1'b1;
    for (integer cell_index = 0; cell_index < 4*32; cell_index++) begin
      if (accumulator_produced_valid[cell_index]) begin
        if (west_to_sxm_valid_o[cell_index])
          conflict_d = 1'b1;
        else begin
          west_to_sxm_valid_o[cell_index] = 1'b1;
          west_to_sxm_data_o[cell_index*64 +: 64] =
            accumulator_produced_data[cell_index*64 +: 64];
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      conflict_o <= 1'b0;
    else if (!run_i)
      conflict_o <= 1'b0;
    else
      conflict_o <= conflict_o | conflict_d;
  end

  assign fault_o = vector_fault | load_fault | compute_fault | accumulator_fault;
  assign execution_busy_o = vector_busy || load_issue_valid_i || dequant_issue_valid_i ||
    compute_issue_valid_i || (|load_row_valid) || (|dequant_row_valid) ||
    (|compute_row_valid) || result_valid || accumulator_pending ||
    (|accumulator_produced_valid);
endmodule
