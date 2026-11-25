// Decode the existing 96-bit ICU sequential ABI; no new software-visible bits.
module lpu_vxm_sequential_decoder #(
	parameter integer QUEUE_ID = 0
) (
	input logic [95:0] word_i,
	output logic legal_o,
	output logic supported_o,
	output logic nop_o,
	output logic [29:0] nop_cycles_o,
	output logic [6:0] local_o,
	output logic [14:0] global_o,
	output logic [31:0] repeat_count_o,
	output logic [3:0] repeat_phase_o,
	output logic immediate_valid_o,
	output logic [31:0] immediate_o
);
	import lpu_vxm_math_pkg::*;
	logic [53:0] control;
	logic [3:0] opcode, lhs, rhs;
	logic [2:0] native_opcode;
	logic [1:0] lhs_code, rhs_code, chain;
	logic head, tail, source_supported;
	integer chain_size;
	logic [15:0] half_immediate;

	assign control = word_i[55:2];
	assign opcode = control[3:0];
	assign lhs = {control[52], control[6:4]};
	assign rhs = {control[53], control[9:7]};
	assign chain = control[18:17];
	assign repeat_count_o = control[50:19];
	assign nop_o = word_i[1:0] == 2'b01;
	assign nop_cycles_o = word_i[31:2];
	assign immediate_valid_o = (lhs == 6) || (rhs == 6);

	// An immediate is an IEEE FP32 number in the ABI, not a truncated native half.
	always_comb begin
		half_immediate = fp32_to_fp16(word_i[87:56]);
		if(half_immediate[14:10] == 0)begin
			half_immediate[9:0] = '0;
		end
		immediate_o = {16'b0, half_immediate};
	end

	// Translate each logical Stage's heterogeneous opcode and operand layout.
	// Q0/Q2/Q4/Q6 have explicit LHS fields; odd Stages inherit Previous.
	always_comb begin
		chain_size = (chain == 0) ? 2 : ((chain == 1) ? 4 : 8);
		head = (QUEUE_ID % chain_size) == 0;
		tail = (QUEUE_ID % chain_size) == chain_size-1;
		native_opcode = opcode[2:0];
		if(opcode == 7)begin
			native_opcode = 6;
		end
		if(opcode == 8)begin
			native_opcode = 7;
		end
		if(opcode == 9)begin
			native_opcode = 6;
		end
		lhs_code = 0;
		rhs_code = 0;
		source_supported = 1'b1;
		if(head)begin
			case(lhs)
				4: lhs_code = 0;
				6: lhs_code = 1;
				7: lhs_code = 2;
				default: source_supported = 1'b0;
			endcase
			case(rhs)
				4: rhs_code = 0;
				6: rhs_code = 1;
				default: source_supported = 1'b0;
			endcase
		end
		else begin
			if(lhs != 0)begin
				source_supported = 1'b0;
			end
			case(rhs)
				1: rhs_code = 0;
				2: rhs_code = 1;
				6: rhs_code = 2;
				3: begin
					rhs_code = 3;
					if(QUEUE_ID % 2 == 0)begin
						source_supported = 1'b0;
					end
				end
				default: source_supported = 1'b0;
			endcase
		end
		local_o = '0;
		if(QUEUE_ID == 0)begin
			local_o[5:0] = {rhs_code[0], lhs_code, native_opcode};
		end
		else if(QUEUE_ID % 2 == 0)begin
			local_o = {rhs_code, lhs_code, native_opcode};
		end
		else begin
			local_o[4:0] = {rhs_code, native_opcode};
			if(opcode == 9)begin
				// LOG is unary: its unused compact RHS does not become native
				// reserved bits. Q3/Q7 require the canonical six-bit 0x26 word.
				local_o = 7'h26;
			end
		end
	end

	// Legal ABI fields and native capability are separate decisions. The native
	// scalar Global ABI currently implements uniform FP16, left-to-right chains.
	// Precision/cast conversions, BF16/FP32 stream packing and scalar writes must
	// not be silently approximated by truncating their compact fields.
	always_comb begin
		legal_o = (word_i[1:0] == 0) && (word_i[95:88] == 0) &&
			(opcode <= 9) && (lhs <= 8) && (rhs <= 8) &&
			(chain < 3) && (repeat_count_o != 0);
		if(opcode == 6 && !(QUEUE_ID == 1 || QUEUE_ID == 5))begin
			legal_o = 1'b0;
		end
		if(opcode >= 7 && !(QUEUE_ID == 3 || QUEUE_ID == 7))begin
			legal_o = 1'b0;
		end
		// Match the compact producer's semantic checks, including fields that
		// the native adapter would otherwise ignore on a non-tail Stage.
		if((control[13] && !tail) || (control[14] && !control[15]) ||
			(control[51] && (control[15] || QUEUE_ID % 2 == 0)) ||
			(control[15] && (QUEUE_ID % 2 == 0 || rhs != 3 ||
			(opcode != 1 && opcode != 5))))begin
			legal_o = 1'b0;
		end
		if(head)begin
			if(!((lhs == 4) || (lhs == 5) || (lhs == 6) || (lhs == 7) || (lhs == 8)) ||
				!((rhs == 4) || (rhs == 5) || (rhs == 6) || (rhs == 8)))begin
				legal_o = 1'b0;
			end
		end
		else begin
			if(lhs != 0 || !((rhs == 1) || (rhs == 2) || (rhs == 6) ||
				(rhs == 3 && QUEUE_ID % 2 == 1)))begin
				legal_o = 1'b0;
			end
		end
		if(nop_o)begin
			legal_o = (word_i[95:32] == 0) && (nop_cycles_o != 0);
		end
		global_o = '0;
		global_o[13:12] = chain;
		repeat_phase_o = {control[13], control[15], control[14], !control[15] || control[16]};
		supported_o = legal_o && (nop_o ||
			(source_supported && !control[10] && (control[12:11] == 1) &&
			 !control[51] && (!control[15] || (tail && rhs == 3 &&
			 (opcode == 1 || opcode == 5)))));
	end
endmodule
