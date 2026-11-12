`timescale 1ns/1ps

// One independent south-to-north command pipeline for a logical MEM bank.
// Native command bit 30 selects a one-cycle (0) or three-cycle (1) hop.
// tile0 sees the current south command combinationally. Each later tile has
// one execution register and two extra registers used only by long commands.
module mem_bank_control_column #(
    parameter P_TILE_ROWS = 4
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
    wire [P_TILE_ROWS-1:0] relay_busy;
    assign relay_busy[0] = 1'b0;

`ifndef SYNTHESIS
    initial begin
        if (P_TILE_ROWS != 2 && P_TILE_ROWS != 4 && P_TILE_ROWS != 8) begin
            $fatal(1, "mem_bank_control_column supports P_TILE_ROWS=2/4/8 only");
        end
    end
`endif

    // tile0 executes the south command in the current cycle; there is no
    // stage0 register and therefore no accidental extra cycle of latency.
    assign leaf_cmd_valid_o[0] = south_cmd_valid_i;
    assign leaf_cmd_raw[0*32 +: 32] = south_cmd_i;

    for (genvar hop = 1; hop < P_TILE_ROWS; hop = hop + 1) begin : gen_hop
        wire source_valid = leaf_cmd_valid_o[hop-1];
        wire [31:0] source_command = leaf_cmd_raw[(hop-1)*32 +: 32];
        wire short_valid = source_valid && !source_command[30];
        wire long_valid = source_valid && source_command[30];
        reg delay1_valid_q, delay2_valid_q;
        reg [31:0] delay1_command_q, delay2_command_q;
        reg valid_q;
        reg [31:0] command_q;
        always @(posedge clk_i or negedge rst_ni) begin
            if (!rst_ni) begin
                delay1_valid_q <= 1'b0;
                delay2_valid_q <= 1'b0;
                delay1_command_q <= 32'b0;
                delay2_command_q <= 32'b0;
                valid_q <= 1'b0;
                command_q <= 32'b0;
            end else begin
                // Short commands never leave effective copies in the extra
                // stages. Each slot is replaced by the next token or a bubble.
                delay1_valid_q <= long_valid;
                delay2_valid_q <= delay1_valid_q;
                if (long_valid) delay1_command_q <= source_command;
                if (delay1_valid_q) delay2_command_q <= delay1_command_q;
                valid_q <= short_valid || delay2_valid_q;
                // Preserve the short-path invalid payload convention; only
                // valid_q enables execution. A long tail uses the same endpoint.
                command_q <= delay2_valid_q ? delay2_command_q : source_command;
            end
        end
        assign leaf_cmd_valid_o[hop] = valid_q;
        assign leaf_cmd_raw[hop*32 +: 32] = command_q;
        assign relay_busy[hop] = delay1_valid_q || delay2_valid_q;

`ifndef SYNTHESIS
        // There is no arbitration, replay, or backpressure. The compiler must
        // space a 3-to-1 transition so a short command cannot pass an older
        // long command or contend with it for this hop's execution register.
        always @(posedge clk_i) begin
            if (rst_ni && short_valid && (delay1_valid_q || delay2_valid_q))
                $fatal(1, "%m unsafe MEM 3-to-1 schedule: short command overtakes pending long command");
        end
`endif
    end

    // Include commands between execution endpoints, even when every leaf has
    // a bubble. The observational north trace does not extend functional busy.
    assign pipeline_busy_o = (|leaf_cmd_valid_o) || (|relay_busy);

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
