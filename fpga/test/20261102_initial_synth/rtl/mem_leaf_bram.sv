`timescale 1ns/1ps

// One physical MEM storage leaf for a fixed
// (hemisphere, mem_slice, bank, superlane) coordinate.
//
// The SRAM array is single-port: at most one complete-row Read or Write is
// accepted in a cycle. Reset clears only control/output state; SRAM contents
// are intentionally not reset.
module mem_bank_superlane_leaf #(
    parameter P_MEM_BANK_DEPTH_ROWS = 32768,
    parameter P_LANES_PER_TILE      = 8,
    parameter P_MEM_ELEMENT_BITS    = 8,
    parameter P_MEM_READ_TO_SR_CYCLES = 1,
    parameter P_MEM_FAULT_BITS      = 2,
    parameter P_MEM_ACTIVE_ROWS     = P_MEM_BANK_DEPTH_ROWS
) (
    input  wire                             clk_i,
    input  wire                             rst_ni,

    input  wire                             cmd_valid_i,
    input  wire [2:0]                       cmd_opcode_i,
    input  wire [14:0]                      cmd_row_i,
    input  wire                             cmd_stream_dir_i,
    input  wire [4:0]                       cmd_stream_idx_i,
    input  wire                             cmd_preserve_i,

    input  wire                             stream_valid_i,
    input  wire [P_LANES_PER_TILE*P_MEM_ELEMENT_BITS-1:0] stream_data_i,

    output reg                              stream_consume_o,

    output reg                              read_valid_o,
    output wire [P_LANES_PER_TILE*P_MEM_ELEMENT_BITS-1:0] read_data_o,
    output reg                              read_stream_dir_o,
    output reg  [4:0]                       read_stream_idx_o,

    output reg                              fault_valid_o,
    output reg  [P_MEM_FAULT_BITS-1:0]      fault_code_o
);

    // FPGA-only experimental backend. Never substituted into repository RTL.
    // Split RAM from async-reset control while preserving the leaf pin contract.
    localparam ROW_BITS = P_LANES_PER_TILE * P_MEM_ELEMENT_BITS;
    (* ram_style = "block" *) reg [ROW_BITS-1:0] mem_array [0:P_MEM_BANK_DEPTH_ROWS-1];
    reg [ROW_BITS-1:0] ram_q;
    reg have_read_q;
    wire address_ok = cmd_row_i < P_MEM_BANK_DEPTH_ROWS && cmd_row_i < P_MEM_ACTIVE_ROWS;
    wire do_read = rst_ni && cmd_valid_i && cmd_opcode_i==0 && !cmd_preserve_i && address_ok;
    wire do_write = rst_ni && cmd_valid_i && cmd_opcode_i==1 && stream_valid_i && address_ok;
    integer i;
    initial begin
        for(i=0;i<P_MEM_BANK_DEPTH_ROWS;i=i+1) mem_array[i]=0;
    end
    always @(posedge clk_i) begin
        if(do_write) mem_array[cmd_row_i] <= stream_data_i;
        else if(do_read) ram_q <= mem_array[cmd_row_i];
    end
    assign read_data_o = have_read_q ? ram_q : {ROW_BITS{1'b0}};
    always @(posedge clk_i or negedge rst_ni) begin
        if(!rst_ni) begin
            stream_consume_o<=0; read_valid_o<=0; have_read_q<=0;
            read_stream_dir_o<=0; read_stream_idx_o<=0;
            fault_valid_o<=0; fault_code_o<=0;
        end else begin
            stream_consume_o<=0; read_valid_o<=0; fault_valid_o<=0; fault_code_o<=0;
            if(cmd_valid_i) begin
                if((cmd_opcode_i==0 || cmd_opcode_i==1) && !(cmd_opcode_i==0 && cmd_preserve_i) && !address_ok) begin
                    fault_valid_o<=1; fault_code_o<=1;
                end else if(cmd_opcode_i==0) begin
                    if(cmd_preserve_i) begin fault_valid_o<=1; fault_code_o<=2; end
                    else begin
                        have_read_q<=1; read_valid_o<=1;
                        read_stream_dir_o<=cmd_stream_dir_i; read_stream_idx_o<=cmd_stream_idx_i;
                    end
                end else if(cmd_opcode_i==1) begin
                    if(!cmd_preserve_i) begin
                        if(stream_valid_i) stream_consume_o<=1;
                        else begin fault_valid_o<=1; fault_code_o<=3; end
                    end
                end else begin fault_valid_o<=1; fault_code_o<=1; end
            end
        end
    end
endmodule
