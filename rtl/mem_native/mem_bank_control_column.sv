`timescale 1ns/1ps

// One independent south-to-north command pipeline for a logical MEM bank.
// tile0 sees the current south command combinationally. Registered state is
// used only for tile1..T-1 and the north trace output.
module mem_bank_control_column #(
    parameter P_TILE_ROWS = 4,
    parameter P_MEM_CONTROL_HOP_CYCLES = 1
) (
    input  wire                         clk_i,
    input  wire                         rst_ni,

    input  wire                         south_cmd_valid_i,
    input  wire [31:0]                  south_cmd_i,

    output reg                          north_cmd_valid_o,
    output reg  [31:0]                  north_cmd_o,

    output wire [P_TILE_ROWS-1:0]       leaf_cmd_valid_o,
    output wire [P_TILE_ROWS*3-1:0]     leaf_cmd_opcode_o,
    output wire [P_TILE_ROWS*15-1:0]    leaf_cmd_row_o,
    output wire [P_TILE_ROWS-1:0]       leaf_cmd_stream_dir_o,
    output wire [P_TILE_ROWS*5-1:0]     leaf_cmd_stream_idx_o,
    output wire [P_TILE_ROWS-1:0]       leaf_cmd_preserve_o,

    output wire                         pipeline_busy_o
);

    wire [P_TILE_ROWS*32-1:0] leaf_cmd_raw;

`ifndef SYNTHESIS
    initial begin
        if (P_TILE_ROWS != 2 && P_TILE_ROWS != 4 && P_TILE_ROWS != 8) begin
            $fatal(1, "mem_bank_control_column supports P_TILE_ROWS=2/4/8 only");
        end
        if (P_MEM_CONTROL_HOP_CYCLES != 1) begin
            $fatal(1, "mem_bank_control_column supports one-cycle hops only");
        end
    end
`endif

    // tile0 executes the south command in the current cycle; there is no
    // stage0 register and therefore no accidental extra cycle of latency.
    assign leaf_cmd_valid_o[0] = south_cmd_valid_i;
    assign leaf_cmd_raw[0*32 +: 32] = south_cmd_i;

    for (genvar hop = 1; hop < P_TILE_ROWS; hop = hop + 1) begin : gen_hop
        reg valid_q;
        reg [31:0] command_q;
        always @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) begin
                valid_q <= 1'b0;
                command_q <= 32'b0;
            end else begin
                valid_q <= leaf_cmd_valid_o[hop-1];
                command_q <= leaf_cmd_raw[(hop-1)*32 +: 32];
            end
        end
        assign leaf_cmd_valid_o[hop] = valid_q;
        assign leaf_cmd_raw[hop*32 +: 32] = command_q;
    end

    // Busy describes commands currently executing at tile0..T-1. The north
    // trace register is observational and does not extend functional busy.
    assign pipeline_busy_o = |leaf_cmd_valid_o;

    genvar tile;
    generate
        for (tile = 0; tile < P_TILE_ROWS; tile = tile + 1) begin : gen_decode
            wire [31:0] tile_cmd;
            assign tile_cmd = leaf_cmd_raw[tile*32 +: 32];
            assign leaf_cmd_opcode_o[tile*3 +: 3] = tile_cmd[2:0];
            assign leaf_cmd_stream_idx_o[tile*5 +: 5] = tile_cmd[7:3];
            assign leaf_cmd_stream_dir_o[tile] = tile_cmd[8];
            assign leaf_cmd_row_o[tile*15 +: 15] = tile_cmd[29:15];
            assign leaf_cmd_preserve_o[tile] = tile_cmd[31];
        end
    endgenerate

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            north_cmd_valid_o <= 1'b0;
            north_cmd_o       <= 32'b0;
        end else begin
            // IMPLEMENTATION CHOICE: north trace is a registered copy of the
            // command presented to the last tile. It does not feed back.
            north_cmd_valid_o <= leaf_cmd_valid_o[P_TILE_ROWS-1];
            north_cmd_o <= leaf_cmd_raw[(P_TILE_ROWS-1)*32 +: 32];
        end
    end

endmodule
