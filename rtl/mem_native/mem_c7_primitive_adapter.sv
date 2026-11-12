`timescale 1ns/1ps

// Stateless c7 raw primitive to native canonical command conversion.
// This is not the legacy 47-bit packet format and adds no issue register.
// The current parameterized input ABI extends c7 with delay3 in bit 30.
// Set P_ALLOW_DELAY3=0 only when checking the frozen original c7 encoding.
module mem_c7_primitive_adapter #(
    parameter P_MEM_BANK_DEPTH_ROWS = 8192,
    parameter P_MEM_ACTIVE_ROWS     = P_MEM_BANK_DEPTH_ROWS,
    parameter P_ALLOW_DELAY3        = 1
) (
    input  wire        issue_valid_i,
    input  wire [31:0] issue_instruction_i,
    output reg         native_valid_o,
    output reg  [31:0] native_command_o,
    output reg         command_fault_o
);
    localparam [31:0] P_USED_BITS =
        32'h80007fff | ((P_MEM_BANK_DEPTH_ROWS-1) << 15) |
        (P_ALLOW_DELAY3 ? 32'h40000000 : 32'b0);

`ifndef SYNTHESIS
    initial begin : check_parameters
        if (P_MEM_BANK_DEPTH_ROWS < 64 || P_MEM_BANK_DEPTH_ROWS > 32768 ||
            (P_MEM_BANK_DEPTH_ROWS & (P_MEM_BANK_DEPTH_ROWS-1)) != 0 ||
            P_MEM_ACTIVE_ROWS <= 0 || P_MEM_ACTIVE_ROWS > P_MEM_BANK_DEPTH_ROWS ||
            (P_MEM_ACTIVE_ROWS & (P_MEM_ACTIVE_ROWS-1)) != 0)
            $fatal(1, "%m illegal c7 MEM physical/active depth");
        if (P_ALLOW_DELAY3 != 0 && P_ALLOW_DELAY3 != 1)
            $fatal(1, "%m P_ALLOW_DELAY3 must be zero or one");
    end
`endif

    always_comb begin
        native_valid_o   = 1'b0;
        native_command_o = 32'b0;
        command_fault_o  = 1'b0;
        if (issue_valid_i) begin
            if ((issue_instruction_i[2:0] == 3'b000 ||
                 issue_instruction_i[2:0] == 3'b001) &&
                !(issue_instruction_i[2:0] == 3'b000 && issue_instruction_i[31]) &&
                ((issue_instruction_i & ~P_USED_BITS) == 32'b0) &&
                (issue_instruction_i[29:15] < P_MEM_ACTIVE_ROWS)) begin
                native_valid_o   = 1'b1;
                native_command_o = issue_instruction_i;
                // Parameterized raw input accepts map bits but discards their
                // meaning. Preserve delay3 with the rest of the command.
                native_command_o[14:9] = 6'b0;
            end else begin
                command_fault_o = 1'b1;
            end
        end
    end
endmodule
