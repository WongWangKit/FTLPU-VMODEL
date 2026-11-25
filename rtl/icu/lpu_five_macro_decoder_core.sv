module lpu_five_macro_decoder_core #(
	parameter integer QUEUE_KIND = lpu_mxm_isa_pkg::MXM_QUEUE_LOAD,
	parameter integer ACCUMULATOR_ROWS = lpu_mxm_config_pkg::ACCUMULATOR_DEPTH
) (
	input  logic        clk_i,
	input  logic        rst_ni,

	// MXM packed-v1 uses one 128-bit physical Local-iMEM word per fetch.
	input  logic        word_valid_i,
	output logic        word_ready_o,
	input  logic [127:0] word_i,
	input  logic        word_last_i,

	// Normalized MXM Macro Context. All fields remain stable while ready is low.
	output logic        context_valid_o,
	input  logic        context_ready_i,
	output logic [48:0] context_instruction_o,
	output logic [31:0] context_start_cycle_o,
	output logic [31:0] context_inner_count_o,
	output logic [31:0] context_inner_interval_o,
	output logic signed [31:0] context_inner_stride_o,
	output logic [31:0] context_outer_count_o,
	output logic [31:0] context_outer_interval_o,
	output logic signed [31:0] context_outer_stride_o,
	output logic [1:0]  context_induction_target_o,
	output logic [12:0] context_operand_o,

	// Terminal status remains asserted until reset.
	output logic        done_o,
	output logic        fault_o,
	output logic [3:0]  fault_code_o
);
	localparam integer RESERVOIR_BITS = 384;
	localparam integer NATIVE_BITS = lpu_mxm_isa_pkg::macro_native_bits(QUEUE_KIND);
	localparam integer OPERAND_BITS = lpu_mxm_isa_pkg::macro_operand_bits(QUEUE_KIND);
	localparam integer INITIAL_STATE_BITS = 32 + OPERAND_BITS;
	localparam logic [8:0] INITIAL_STATE_WIDTH = INITIAL_STATE_BITS;
	localparam logic [8:0] EXTENDED_HEADER_WIDTH = 1 + NATIVE_BITS;
	localparam logic [8:0] COMPACT_HEADER_WIDTH = 1 + NATIVE_BITS + 4;
	localparam logic [1:0] TARGET_NONE = lpu_mxm_isa_pkg::MXM_INDUCTION_NONE;
	localparam logic [1:0] TARGET_OPERAND0 = lpu_mxm_isa_pkg::MXM_INDUCTION_OPERAND0;
	localparam logic [1:0] TARGET_OPERAND1 = lpu_mxm_isa_pkg::MXM_INDUCTION_OPERAND1;

	localparam logic [3:0] FAULT_NONE = 4'd0;
	localparam logic [3:0] FAULT_CONTROL = 4'd1;
	localparam logic [3:0] FAULT_RESERVED = 4'd2;
	localparam logic [3:0] FAULT_TRUNCATED = 4'd3;
	localparam logic [3:0] FAULT_DICTIONARY = 4'd4;
	localparam logic [3:0] FAULT_RUN_LENGTH = 4'd5;
	localparam logic [3:0] FAULT_NATIVE = 4'd6;
	localparam logic [3:0] FAULT_SCHEDULE = 4'd7;
	localparam logic [3:0] FAULT_DELTA = 4'd8;

	typedef enum logic [3:0] {
		IDLE_GLOBAL,
		DICT_STORE,
		INIT_GLOBAL,
		RUN_HEADER,
		TEMPLATE,
		IDLE,
		GET_DELTA,
		DICT_LOOKUP,
		ESCAPE,
		APPLY_DELTA,
		OUTPUT_CONTEXT,
		FAULT
	} state_t;

	localparam logic DICT_PHASE_COUNT = 1'b0;
	localparam logic DICT_PHASE_ENTRY = 1'b1;
	localparam logic RUN_PHASE_FLAG = 1'b0;
	localparam logic RUN_PHASE_LENGTH = 1'b1;
	localparam logic [1:0] TEMPLATE_PHASE_HEADER = 2'd0;
	localparam logic [1:0] TEMPLATE_PHASE_PAYLOAD = 2'd1;
	localparam logic [1:0] TEMPLATE_PHASE_VALIDATE = 2'd2;
	localparam logic ESCAPE_PHASE_MODE = 1'b0;
	localparam logic ESCAPE_PHASE_PAYLOAD = 1'b1;

	state_t state_q;
	state_t state_d;

	// State-local parsing phases keep the architectural FSM at the agreed granularity.
	logic dict_store_phase_q;
	logic run_header_phase_q;
	logic [1:0] template_phase_q;
	logic escape_phase_q;

	// Word input and cross-word bit reservoir. Bit zero is always consumed first.
	logic [RESERVOIR_BITS-1:0] reservoir_q;
	logic [8:0] reservoir_bits_q;
	logic input_last_q;
	logic word_fire;
	logic parser_consume_bits_w;
	logic [8:0] parser_consume_width_w;

	// Queue-level configuration, Dictionary storage and first-Macro tracking.
	logic control_received_q;
	logic first_macro_pending_q;
	logic [2:0] dictionary_count_q;
	logic [2:0] dictionary_index_q;
	logic [2:0] dictionary_lookup_index_q;
	logic [31:0] dictionary_start_q [0:6];
	logic signed [31:0] dictionary_operand_q [0:6];

	// These are the only two Macro remaining counters.
	logic [23:0] queue_macro_remaining_q;
	logic [16:0] run_macro_remaining_q;

	// Reconstructed absolute Queue state.
	logic [31:0] running_start_cycle_q;
	logic [12:0] running_operand_q;
	logic [31:0] pending_delta_start_q;
	logic signed [31:0] pending_delta_operand_q;
	logic delta_wide_q;

	// Current Run Template and its normalized two-level schedule.
	logic template_extended_q;
	logic [1:0] template_shape_q;
	logic [48:0] template_native_q;
	logic [193:0] template_payload_q;
	logic [7:0] template_payload_count_q;
	logic [7:0] template_payload_target_q;
	logic [31:0] template_inner_count_q;
	logic [31:0] template_inner_interval_q;
	logic signed [31:0] template_inner_stride_q;
	logic [31:0] template_outer_count_q;
	logic [31:0] template_outer_interval_q;
	logic signed [31:0] template_outer_stride_q;
	logic [1:0] template_target_q;

	// Context holding registers are written before entering OUTPUT_CONTEXT.
	logic [48:0] context_instruction_q;
	logic [31:0] context_start_cycle_q;
	logic [31:0] context_inner_count_q;
	logic [31:0] context_inner_interval_q;
	logic signed [31:0] context_inner_stride_q;
	logic [31:0] context_outer_count_q;
	logic [31:0] context_outer_interval_q;
	logic signed [31:0] context_outer_stride_q;
	logic [1:0] context_target_q;
	logic [12:0] context_operand_q;

	// Sticky Fault information.
	logic fault_q;
	logic [3:0] fault_code_q;

	// Pure decode and arithmetic results.
	logic control_reserved_illegal_w;
	logic control_legal_w;
	logic [16:0] run_length_value_w;
	logic [7:0] template_remaining_width_w;
	logic [7:0] template_chunk_width_w;
	logic [48:0] compact_native_w;
	logic [8:0] template_header_width_w;
	logic [1:0] header_shape_w;
	logic [1:0] header_target_w;
	logic [7:0] compact_payload_target_w;
	logic [31:0] decoded_inner_count_w;
	logic [31:0] decoded_inner_interval_w;
	logic signed [31:0] decoded_inner_stride_w;
	logic [31:0] decoded_outer_count_w;
	logic [31:0] decoded_outer_interval_w;
	logic signed [31:0] decoded_outer_stride_w;
	logic [1:0] decoded_target_w;
	logic [63:0] decoded_inner_span_w;
	logic decoded_native_illegal_w;
	logic decoded_schedule_illegal_w;
	logic delta_prefix_recognized_w;
	logic [2:0] delta_prefix_symbol_w;
	logic [2:0] delta_prefix_width_w;
	logic [32:0] delta_start_sum_w;
	logic signed [33:0] delta_operand_sum_w;
	logic delta_illegal_w;
	logic context_fire;

	// State-owned controls. Their names expose the state that authorizes each action.
	logic ctrl_idle_global_accept_control_w;
	logic ctrl_dict_store_capture_count_w;
	logic ctrl_dict_store_capture_entry_w;
	logic ctrl_init_global_capture_state_w;
	logic ctrl_run_header_capture_flag_w;
	logic ctrl_run_header_capture_length_w;
	logic ctrl_template_capture_extended_w;
	logic ctrl_template_capture_compact_w;
	logic ctrl_template_capture_payload_w;
	logic ctrl_template_latch_schedule_w;
	logic ctrl_template_load_initial_context_w;
	logic ctrl_get_delta_consume_prefix_w;
	logic ctrl_get_delta_capture_lookup_w;
	logic ctrl_get_delta_select_escape_w;
	logic ctrl_dict_lookup_select_entry_w;
	logic ctrl_escape_capture_mode_w;
	logic ctrl_escape_capture_payload_w;
	logic ctrl_apply_delta_update_state_w;
	logic ctrl_apply_delta_load_context_w;
	logic ctrl_output_context_valid_w;
	logic ctrl_idle_start_next_run_w;
	logic ctrl_set_fault_w;
	logic [3:0] ctrl_fault_code_w;

	integer reservoir_bit_index;
	integer template_bit_index;
	integer dictionary_reset_index;

	assign word_fire = word_valid_i && word_ready_o;
	assign context_fire = context_valid_o && context_ready_i;

	assign control_reserved_illegal_w = word_i[1] || (word_i[127:28] != '0);
	assign control_legal_w = word_i[0] && (word_i[3:2] == 2'b01) && !control_reserved_illegal_w;
	assign run_length_value_w = {1'b0, reservoir_q[15:0]} + 17'd1;
	assign template_remaining_width_w = template_payload_target_q - template_payload_count_q;
	assign template_chunk_width_w = template_remaining_width_w > 8'd64 ? 8'd64 : template_remaining_width_w;
	assign delta_start_sum_w = {1'b0, running_start_cycle_q} + {1'b0, pending_delta_start_q};
	assign delta_operand_sum_w = $signed({21'd0, running_operand_q}) + $signed({{2{pending_delta_operand_q[31]}}, pending_delta_operand_q});
	assign delta_illegal_w = delta_start_sum_w[32] || !mxm_operand_legal(template_target_q, delta_operand_sum_w);

	assign context_valid_o = ctrl_output_context_valid_w;
	assign context_instruction_o = context_instruction_q;
	assign context_start_cycle_o = context_start_cycle_q;
	assign context_inner_count_o = context_inner_count_q;
	assign context_inner_interval_o = context_inner_interval_q;
	assign context_inner_stride_o = context_inner_stride_q;
	assign context_outer_count_o = context_outer_count_q;
	assign context_outer_interval_o = context_outer_interval_q;
	assign context_outer_stride_o = context_outer_stride_q;
	assign context_induction_target_o = context_target_q;
	assign context_operand_o = context_operand_q;
	assign done_o = ((state_q == IDLE_GLOBAL) && control_received_q && (queue_macro_remaining_q == 24'd0)) ||
		((state_q == IDLE) && (queue_macro_remaining_q == 24'd0));
	assign fault_o = fault_q;
	assign fault_code_o = fault_code_q;

	// The Control Word is accepted directly; later words feed the bounded reservoir.
	always_comb begin
		word_ready_o = 1'b0;
		if(state_q == IDLE_GLOBAL)begin
			word_ready_o = !control_received_q && !fault_q;
		end
		else if((state_q != OUTPUT_CONTEXT) && (state_q != FAULT) && !done_o && !input_last_q && (reservoir_bits_q <= 9'd256))begin
			word_ready_o = 1'b1;
		end
	end

	// Apply only the Stream-selected induction operand; fixed opcode/mode fields remain intact.
	function automatic logic [48:0] mxm_instruction_with_operand(
		input logic [48:0] native_instruction,
		input logic [1:0] target,
		input logic [12:0] operand
	);
		begin
			mxm_instruction_with_operand = native_instruction;
			case(QUEUE_KIND)
				lpu_mxm_isa_pkg::MXM_QUEUE_LOAD: begin
					if(target == TARGET_OPERAND0)begin
						mxm_instruction_with_operand[1] = operand[0];
					end
				end
				lpu_mxm_isa_pkg::MXM_QUEUE_COMPUTE: begin
					if(target == TARGET_OPERAND0)begin
						mxm_instruction_with_operand[6:1] = operand[5:0];
					end
					else if(target == TARGET_OPERAND1)begin
						mxm_instruction_with_operand[0] = operand[0];
					end
				end
				lpu_mxm_isa_pkg::MXM_QUEUE_DEQUANT,
				lpu_mxm_isa_pkg::MXM_QUEUE_PARAM_LOAD: begin
					if(target == TARGET_OPERAND0)begin
						mxm_instruction_with_operand[0] = operand[0];
					end
				end
				lpu_mxm_isa_pkg::MXM_QUEUE_BACKEND: begin
					if(target == TARGET_OPERAND0)begin
						mxm_instruction_with_operand[2+:lpu_mxm_backend_isa_pkg::BACKEND_ADDRESS_BITS] =
							operand[lpu_mxm_backend_isa_pkg::BACKEND_ADDRESS_BITS-1:0];
					end
				end
				default: begin
				end
			endcase
		end
	endfunction

	// Operand ranges are Stream-specific and are checked both after Delta decode
	// and over the full affine schedule by the Scheduler.
	function automatic logic mxm_operand_legal(
		input logic [1:0] target,
		input logic signed [33:0] operand
	);
		begin
			mxm_operand_legal = operand >= 0;
			if(target == TARGET_NONE)begin
				mxm_operand_legal = operand == 0;
			end
			else begin
				case(QUEUE_KIND)
					lpu_mxm_isa_pkg::MXM_QUEUE_COMPUTE: begin
						if(target == TARGET_OPERAND0)begin
							mxm_operand_legal = (operand >= 0) && (operand <= 34'sd30);
						end
						else if(target == TARGET_OPERAND1)begin
							mxm_operand_legal = (operand >= 0) && (operand <= 34'sd1);
						end
						else begin
							mxm_operand_legal = 1'b0;
						end
					end
					lpu_mxm_isa_pkg::MXM_QUEUE_BACKEND: begin
						mxm_operand_legal = (target == TARGET_OPERAND0) && (operand >= 0) &&
							(operand < ACCUMULATOR_ROWS);
					end
					default: begin
						mxm_operand_legal = (target == TARGET_OPERAND0) && (operand >= 0) &&
							(operand <= 34'sd1);
					end
				endcase
			end
		end
	endfunction

	// Both Template forms carry the native Stream instruction verbatim. Compact
	// headers additionally encode Shape and induction target before the payload.
	always_comb begin
		compact_native_w = '0;
		compact_native_w[NATIVE_BITS-1:0] = reservoir_q[NATIVE_BITS:1];
		header_shape_w = reservoir_q[NATIVE_BITS+2:NATIVE_BITS+1];
		header_target_w = reservoir_q[NATIVE_BITS+4:NATIVE_BITS+3];
		template_header_width_w = reservoir_q[0] ? EXTENDED_HEADER_WIDTH : COMPACT_HEADER_WIDTH;
		case(header_shape_w)
			2'd0: compact_payload_target_w = 8'd0;
			2'd1: compact_payload_target_w = 8'd29;
			2'd2: compact_payload_target_w = 8'd36;
			default: compact_payload_target_w = 8'd65;
		endcase
	end

	// Normalize Compact and Extended schedule payloads to the common Context shape.
	always_comb begin
		decoded_inner_count_w = 32'd1;
		decoded_inner_interval_w = 32'd1;
		decoded_inner_stride_w = 32'sd0;
		decoded_outer_count_w = 32'd1;
		decoded_outer_interval_w = 32'd1;
		decoded_outer_stride_w = 32'sd0;
		decoded_target_w = TARGET_NONE;

		if(template_extended_q)begin
			decoded_inner_count_w = template_payload_q[31:0];
			decoded_inner_interval_w = template_payload_q[63:32];
			decoded_inner_stride_w = $signed(template_payload_q[95:64]);
			decoded_outer_count_w = template_payload_q[127:96];
			decoded_outer_interval_w = template_payload_q[159:128];
			decoded_outer_stride_w = $signed(template_payload_q[191:160]);
			decoded_target_w = template_payload_q[193:192];
		end
		else begin
			decoded_target_w = template_target_q;
			case(template_shape_q)
				2'd1: begin
					decoded_inner_count_w = {21'd0, template_payload_q[10:0]} + 32'd1;
					decoded_inner_interval_w = {24'd0, template_payload_q[18:11]} + 32'd1;
					decoded_inner_stride_w = {{22{template_payload_q[28]}}, template_payload_q[28:19]};
				end
				2'd2: begin
					decoded_outer_count_w = {23'd0, template_payload_q[8:0]} + 32'd1;
					decoded_outer_interval_w = {17'd0, template_payload_q[23:9]} + 32'd1;
					decoded_outer_stride_w = {{20{template_payload_q[35]}}, template_payload_q[35:24]};
				end
				2'd3: begin
					decoded_inner_count_w = {21'd0, template_payload_q[10:0]} + 32'd1;
					decoded_inner_interval_w = {24'd0, template_payload_q[18:11]} + 32'd1;
					decoded_inner_stride_w = {{22{template_payload_q[28]}}, template_payload_q[28:19]};
					decoded_outer_count_w = {23'd0, template_payload_q[37:29]} + 32'd1;
					decoded_outer_interval_w = ({17'd0, template_payload_q[52:38]} + 32'd1) +
						(({21'd0, template_payload_q[10:0]}) * ({24'd0, template_payload_q[18:11]} + 32'd1));
					decoded_outer_stride_w = {{20{template_payload_q[64]}}, template_payload_q[64:53]};
				end
				default: begin
				end
			endcase
		end

		decoded_inner_span_w = {32'd0, decoded_inner_count_w - 32'd1} * {32'd0, decoded_inner_interval_w};
		decoded_native_illegal_w = 1'b0;
		case(QUEUE_KIND)
			lpu_mxm_isa_pkg::MXM_QUEUE_COMPUTE: begin
				decoded_native_illegal_w = template_native_q[6:1] > 6'd30;
			end
			lpu_mxm_isa_pkg::MXM_QUEUE_BACKEND: begin
				decoded_native_illegal_w = !lpu_mxm_backend_isa_pkg::backend_legal(
					template_native_q[lpu_mxm_backend_isa_pkg::BACKEND_INSTRUCTION_BITS-1:0]);
			end
			lpu_mxm_isa_pkg::MXM_QUEUE_LOAD,
			lpu_mxm_isa_pkg::MXM_QUEUE_DEQUANT,
			lpu_mxm_isa_pkg::MXM_QUEUE_PARAM_LOAD: begin
			end
			default: begin
				decoded_native_illegal_w = 1'b1;
			end
		endcase

		decoded_schedule_illegal_w = (decoded_inner_count_w == 32'd0) || (decoded_inner_interval_w == 32'd0) ||
			(decoded_outer_count_w == 32'd0) || (decoded_outer_interval_w == 32'd0) ||
			((decoded_outer_count_w > 32'd1) && ({32'd0, decoded_outer_interval_w} <= decoded_inner_span_w)) ||
			((decoded_target_w == TARGET_NONE) && ((decoded_inner_stride_w != 32'sd0) ||
				(decoded_outer_stride_w != 32'sd0))) ||
			!mxm_operand_legal(decoded_target_w, $signed({1'b0, running_operand_q}));
		if(QUEUE_KIND == lpu_mxm_isa_pkg::MXM_QUEUE_COMPUTE)begin
			decoded_schedule_illegal_w = decoded_schedule_illegal_w ||
				!((decoded_target_w == TARGET_NONE) || (decoded_target_w == TARGET_OPERAND0) ||
				(decoded_target_w == TARGET_OPERAND1));
		end
		else begin
			decoded_schedule_illegal_w = decoded_schedule_illegal_w ||
				!((decoded_target_w == TARGET_NONE) || (decoded_target_w == TARGET_OPERAND0));
		end
	end

	// Delta symbols use the packed-v1 LSB-first prefix tree; symbol seven is Escape.
	always_comb begin
		delta_prefix_recognized_w = 1'b0;
		delta_prefix_symbol_w = 3'd0;
		delta_prefix_width_w = 3'd0;

		if((reservoir_bits_q >= 9'd1) && !reservoir_q[0])begin
			delta_prefix_recognized_w = 1'b1;
			delta_prefix_symbol_w = 3'd0;
			delta_prefix_width_w = 3'd1;
		end
		else if((reservoir_bits_q >= 9'd2) && !reservoir_q[1])begin
			delta_prefix_recognized_w = 1'b1;
			delta_prefix_symbol_w = 3'd1;
			delta_prefix_width_w = 3'd2;
		end
		else if((reservoir_bits_q >= 9'd4) && !reservoir_q[2])begin
			delta_prefix_recognized_w = 1'b1;
			delta_prefix_symbol_w = reservoir_q[3] ? 3'd3 : 3'd2;
			delta_prefix_width_w = 3'd4;
		end
		else if((reservoir_bits_q >= 9'd5) && reservoir_q[2])begin
			delta_prefix_recognized_w = 1'b1;
			if(!reservoir_q[3])begin
				delta_prefix_symbol_w = reservoir_q[4] ? 3'd5 : 3'd4;
			end
			else begin
				delta_prefix_symbol_w = reservoir_q[4] ? 3'd7 : 3'd6;
			end
			delta_prefix_width_w = 3'd5;
		end
	end

	// Moore output decode. Parser actions are suppressed during a reservoir refill,
	// so one cycle never appends and consumes the same storage simultaneously.
	always_comb begin
		parser_consume_bits_w = 1'b0;
		parser_consume_width_w = '0;
		ctrl_idle_global_accept_control_w = 1'b0;
		ctrl_dict_store_capture_count_w = 1'b0;
		ctrl_dict_store_capture_entry_w = 1'b0;
		ctrl_init_global_capture_state_w = 1'b0;
		ctrl_run_header_capture_flag_w = 1'b0;
		ctrl_run_header_capture_length_w = 1'b0;
		ctrl_template_capture_extended_w = 1'b0;
		ctrl_template_capture_compact_w = 1'b0;
		ctrl_template_capture_payload_w = 1'b0;
		ctrl_template_latch_schedule_w = 1'b0;
		ctrl_template_load_initial_context_w = 1'b0;
		ctrl_get_delta_consume_prefix_w = 1'b0;
		ctrl_get_delta_capture_lookup_w = 1'b0;
		ctrl_get_delta_select_escape_w = 1'b0;
		ctrl_dict_lookup_select_entry_w = 1'b0;
		ctrl_escape_capture_mode_w = 1'b0;
		ctrl_escape_capture_payload_w = 1'b0;
		ctrl_apply_delta_update_state_w = 1'b0;
		ctrl_apply_delta_load_context_w = 1'b0;
		ctrl_output_context_valid_w = 1'b0;
		ctrl_idle_start_next_run_w = 1'b0;
		ctrl_set_fault_w = 1'b0;
		ctrl_fault_code_w = FAULT_NONE;

		case(state_q)
			IDLE_GLOBAL: begin
				ctrl_idle_global_accept_control_w = word_fire;
				if(word_fire && control_reserved_illegal_w)begin
					ctrl_set_fault_w = 1'b1;
					ctrl_fault_code_w = FAULT_RESERVED;
				end
				else if(word_fire && !control_legal_w)begin
					ctrl_set_fault_w = 1'b1;
					ctrl_fault_code_w = FAULT_CONTROL;
				end
			end

			DICT_STORE: begin
				if(!word_fire)begin
					if(dict_store_phase_q == DICT_PHASE_COUNT)begin
						if(reservoir_bits_q >= 9'd3)begin
							ctrl_dict_store_capture_count_w = 1'b1;
							parser_consume_bits_w = 1'b1;
							parser_consume_width_w = 9'd3;
						end
						else if(input_last_q)begin
							ctrl_set_fault_w = 1'b1;
							ctrl_fault_code_w = FAULT_TRUNCATED;
						end
					end
					else begin
						if(reservoir_bits_q >= 9'd36)begin
							ctrl_dict_store_capture_entry_w = 1'b1;
							parser_consume_bits_w = 1'b1;
							parser_consume_width_w = 9'd36;
						end
						else if(input_last_q)begin
							ctrl_set_fault_w = 1'b1;
							ctrl_fault_code_w = FAULT_TRUNCATED;
						end
					end
				end
			end

			INIT_GLOBAL: begin
				if(!word_fire)begin
					if(reservoir_bits_q >= INITIAL_STATE_WIDTH)begin
						ctrl_init_global_capture_state_w = 1'b1;
						parser_consume_bits_w = 1'b1;
						parser_consume_width_w = INITIAL_STATE_WIDTH;
					end
					else if(input_last_q)begin
						ctrl_set_fault_w = 1'b1;
						ctrl_fault_code_w = FAULT_TRUNCATED;
					end
				end
			end

			RUN_HEADER: begin
				if(!word_fire)begin
					if(run_header_phase_q == RUN_PHASE_FLAG)begin
						if(reservoir_bits_q >= 9'd1)begin
							ctrl_run_header_capture_flag_w = 1'b1;
							parser_consume_bits_w = 1'b1;
							parser_consume_width_w = 9'd1;
						end
						else if(input_last_q)begin
							ctrl_set_fault_w = 1'b1;
							ctrl_fault_code_w = FAULT_TRUNCATED;
						end
					end
					else begin
						if(reservoir_bits_q >= 9'd16)begin
							if({7'd0, run_length_value_w} > queue_macro_remaining_q)begin
								ctrl_set_fault_w = 1'b1;
								ctrl_fault_code_w = FAULT_RUN_LENGTH;
							end
							else begin
								ctrl_run_header_capture_length_w = 1'b1;
								parser_consume_bits_w = 1'b1;
								parser_consume_width_w = 9'd16;
							end
						end
						else if(input_last_q)begin
							ctrl_set_fault_w = 1'b1;
							ctrl_fault_code_w = FAULT_TRUNCATED;
						end
					end
				end
			end

			TEMPLATE: begin
				if(!word_fire)begin
					case(template_phase_q)
						TEMPLATE_PHASE_HEADER: begin
							if(reservoir_bits_q >= 9'd1)begin
								if(reservoir_q[0])begin
								if(reservoir_bits_q >= EXTENDED_HEADER_WIDTH)begin
										ctrl_template_capture_extended_w = 1'b1;
										parser_consume_bits_w = 1'b1;
									parser_consume_width_w = EXTENDED_HEADER_WIDTH;
									end
									else if(input_last_q)begin
										ctrl_set_fault_w = 1'b1;
										ctrl_fault_code_w = FAULT_TRUNCATED;
									end
								end
								else begin
								if(reservoir_bits_q >= COMPACT_HEADER_WIDTH)begin
										ctrl_template_capture_compact_w = 1'b1;
										parser_consume_bits_w = 1'b1;
									parser_consume_width_w = COMPACT_HEADER_WIDTH;
									end
									else if(input_last_q)begin
										ctrl_set_fault_w = 1'b1;
										ctrl_fault_code_w = FAULT_TRUNCATED;
									end
								end
							end
							else if(input_last_q)begin
								ctrl_set_fault_w = 1'b1;
								ctrl_fault_code_w = FAULT_TRUNCATED;
							end
						end

						TEMPLATE_PHASE_PAYLOAD: begin
							if(reservoir_bits_q >= {1'b0, template_chunk_width_w})begin
								ctrl_template_capture_payload_w = 1'b1;
								parser_consume_bits_w = 1'b1;
								parser_consume_width_w = {1'b0, template_chunk_width_w};
							end
							else if(input_last_q)begin
								ctrl_set_fault_w = 1'b1;
								ctrl_fault_code_w = FAULT_TRUNCATED;
							end
						end

						TEMPLATE_PHASE_VALIDATE: begin
							if(decoded_native_illegal_w)begin
								ctrl_set_fault_w = 1'b1;
								ctrl_fault_code_w = FAULT_NATIVE;
							end
							else if(decoded_schedule_illegal_w)begin
								ctrl_set_fault_w = 1'b1;
								ctrl_fault_code_w = FAULT_SCHEDULE;
							end
							else begin
								ctrl_template_latch_schedule_w = 1'b1;
								ctrl_template_load_initial_context_w = first_macro_pending_q;
							end
						end

						default: begin
							ctrl_set_fault_w = 1'b1;
							ctrl_fault_code_w = FAULT_CONTROL;
						end
					endcase
				end
			end

			GET_DELTA: begin
				if(!word_fire)begin
					if(delta_prefix_recognized_w)begin
						if(delta_prefix_symbol_w == 3'd7)begin
							ctrl_get_delta_consume_prefix_w = 1'b1;
							ctrl_get_delta_select_escape_w = 1'b1;
							parser_consume_bits_w = 1'b1;
							parser_consume_width_w = {6'd0, delta_prefix_width_w};
						end
						else if(delta_prefix_symbol_w < dictionary_count_q)begin
							ctrl_get_delta_consume_prefix_w = 1'b1;
							ctrl_get_delta_capture_lookup_w = 1'b1;
							parser_consume_bits_w = 1'b1;
							parser_consume_width_w = {6'd0, delta_prefix_width_w};
						end
						else begin
							ctrl_set_fault_w = 1'b1;
							ctrl_fault_code_w = FAULT_DICTIONARY;
						end
					end
					else if(input_last_q)begin
						ctrl_set_fault_w = 1'b1;
						ctrl_fault_code_w = FAULT_TRUNCATED;
					end
				end
			end

			DICT_LOOKUP: begin
				ctrl_dict_lookup_select_entry_w = 1'b1;
			end

			ESCAPE: begin
				if(!word_fire)begin
					if(escape_phase_q == ESCAPE_PHASE_MODE)begin
						if(reservoir_bits_q >= 9'd1)begin
							ctrl_escape_capture_mode_w = 1'b1;
							parser_consume_bits_w = 1'b1;
							parser_consume_width_w = 9'd1;
						end
						else if(input_last_q)begin
							ctrl_set_fault_w = 1'b1;
							ctrl_fault_code_w = FAULT_TRUNCATED;
						end
					end
					else begin
						if(reservoir_bits_q >= (delta_wide_q ? 9'd64 : 9'd36))begin
							ctrl_escape_capture_payload_w = 1'b1;
							parser_consume_bits_w = 1'b1;
							parser_consume_width_w = delta_wide_q ? 9'd64 : 9'd36;
						end
						else if(input_last_q)begin
							ctrl_set_fault_w = 1'b1;
							ctrl_fault_code_w = FAULT_TRUNCATED;
						end
					end
				end
			end

			APPLY_DELTA: begin
				if(delta_illegal_w)begin
					ctrl_set_fault_w = 1'b1;
					ctrl_fault_code_w = FAULT_DELTA;
				end
				else begin
					ctrl_apply_delta_update_state_w = 1'b1;
					ctrl_apply_delta_load_context_w = 1'b1;
				end
			end

			OUTPUT_CONTEXT: begin
				ctrl_output_context_valid_w = 1'b1;
			end

			IDLE: begin
				ctrl_idle_start_next_run_w = queue_macro_remaining_q != 24'd0;
			end

			FAULT: begin
			end

			default: begin
				ctrl_set_fault_w = 1'b1;
				ctrl_fault_code_w = FAULT_CONTROL;
			end
		endcase
	end

	// Next-state logic is separate from state-owned actions and functional registers.
	always_comb begin
		state_d = state_q;
		case(state_q)
			IDLE_GLOBAL: begin
				if(ctrl_set_fault_w)begin
					state_d = FAULT;
				end
				else if(ctrl_idle_global_accept_control_w && control_legal_w && (word_i[27:4] != 24'd0))begin
					state_d = DICT_STORE;
				end
			end

			DICT_STORE: begin
				if(ctrl_set_fault_w)begin
					state_d = FAULT;
				end
				else if(ctrl_dict_store_capture_count_w && (reservoir_q[2:0] == 3'd0))begin
					state_d = INIT_GLOBAL;
				end
				else if(ctrl_dict_store_capture_entry_w && ((dictionary_index_q + 1'b1) == dictionary_count_q))begin
					state_d = INIT_GLOBAL;
				end
			end

			INIT_GLOBAL: begin
				if(ctrl_set_fault_w)begin
					state_d = FAULT;
				end
				else if(ctrl_init_global_capture_state_w)begin
					state_d = RUN_HEADER;
				end
			end

			RUN_HEADER: begin
				if(ctrl_set_fault_w)begin
					state_d = FAULT;
				end
				else if(ctrl_run_header_capture_flag_w && !reservoir_q[0])begin
					state_d = TEMPLATE;
				end
				else if(ctrl_run_header_capture_length_w)begin
					state_d = TEMPLATE;
				end
			end

			TEMPLATE: begin
				if(ctrl_set_fault_w)begin
					state_d = FAULT;
				end
				else if(ctrl_template_latch_schedule_w)begin
					state_d = first_macro_pending_q ? OUTPUT_CONTEXT : GET_DELTA;
				end
			end

			GET_DELTA: begin
				if(ctrl_set_fault_w)begin
					state_d = FAULT;
				end
				else if(ctrl_get_delta_select_escape_w)begin
					state_d = ESCAPE;
				end
				else if(ctrl_get_delta_capture_lookup_w)begin
					state_d = DICT_LOOKUP;
				end
			end

			DICT_LOOKUP: begin
				state_d = APPLY_DELTA;
			end

			ESCAPE: begin
				if(ctrl_set_fault_w)begin
					state_d = FAULT;
				end
				else if(ctrl_escape_capture_payload_w)begin
					state_d = APPLY_DELTA;
				end
			end

			APPLY_DELTA: begin
				state_d = ctrl_set_fault_w ? FAULT : OUTPUT_CONTEXT;
			end

			OUTPUT_CONTEXT: begin
				if(context_fire)begin
					state_d = (run_macro_remaining_q > 17'd1) ? GET_DELTA : IDLE;
				end
			end

			IDLE: begin
				if(ctrl_idle_start_next_run_w)begin
					state_d = RUN_HEADER;
				end
			end

			FAULT: begin
				state_d = FAULT;
			end

			default: begin
				state_d = FAULT;
			end
		endcase
	end

	// Architectural FSM state register.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			state_q <= IDLE_GLOBAL;
		end
		else begin
			state_q <= state_d;
		end
	end

	// Reservoir refill and bit consumption are mutually exclusive each cycle.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			reservoir_q <= '0;
			reservoir_bits_q <= '0;
			input_last_q <= 1'b0;
		end
		else begin
			if(word_fire)begin
				if(state_q == IDLE_GLOBAL)begin
					input_last_q <= word_last_i;
				end
				else begin
					for(reservoir_bit_index = 0; reservoir_bit_index < 128; reservoir_bit_index = reservoir_bit_index + 1)begin
						reservoir_q[reservoir_bits_q + reservoir_bit_index] <= word_i[reservoir_bit_index];
					end
					reservoir_bits_q <= reservoir_bits_q + 9'd128;
					if(word_last_i)begin
						input_last_q <= 1'b1;
					end
				end
			end
			else if(parser_consume_bits_w)begin
				reservoir_q <= reservoir_q >> parser_consume_width_w;
				reservoir_bits_q <= reservoir_bits_q - parser_consume_width_w;
			end
		end
	end

	// Queue Control, the two Macro counters and first-Macro identity share the
	// Context Fire boundary so one accepted Context consumes exactly one Macro.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			control_received_q <= 1'b0;
			first_macro_pending_q <= 1'b0;
			queue_macro_remaining_q <= '0;
			run_macro_remaining_q <= '0;
		end
		else begin
			if(ctrl_idle_global_accept_control_w && control_legal_w)begin
				control_received_q <= 1'b1;
				queue_macro_remaining_q <= word_i[27:4];
				first_macro_pending_q <= word_i[27:4] != 24'd0;
			end

			if(ctrl_run_header_capture_flag_w && !reservoir_q[0])begin
				run_macro_remaining_q <= 17'd1;
			end
			else if(ctrl_run_header_capture_length_w)begin
				run_macro_remaining_q <= run_length_value_w;
			end
			else if(context_fire)begin
				queue_macro_remaining_q <= queue_macro_remaining_q - 1'b1;
				run_macro_remaining_q <= run_macro_remaining_q - 1'b1;
				first_macro_pending_q <= 1'b0;
			end
		end
	end

	// Parser subphases only sequence fields within one architectural state.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			dict_store_phase_q <= DICT_PHASE_COUNT;
			run_header_phase_q <= RUN_PHASE_FLAG;
			template_phase_q <= TEMPLATE_PHASE_HEADER;
			escape_phase_q <= ESCAPE_PHASE_MODE;
		end
		else begin
			if(ctrl_dict_store_capture_count_w && (reservoir_q[2:0] != 3'd0))begin
				dict_store_phase_q <= DICT_PHASE_ENTRY;
			end

			if(ctrl_run_header_capture_flag_w)begin
				run_header_phase_q <= reservoir_q[0] ? RUN_PHASE_LENGTH : RUN_PHASE_FLAG;
			end
			else if(ctrl_run_header_capture_length_w)begin
				run_header_phase_q <= RUN_PHASE_FLAG;
			end

			if(ctrl_template_capture_extended_w)begin
				template_phase_q <= TEMPLATE_PHASE_PAYLOAD;
			end
			else if(ctrl_template_capture_compact_w)begin
				template_phase_q <= (compact_payload_target_w == 8'd0) ? TEMPLATE_PHASE_VALIDATE : TEMPLATE_PHASE_PAYLOAD;
			end
			else if(ctrl_template_capture_payload_w && ((template_payload_count_q + template_chunk_width_w) == template_payload_target_q))begin
				template_phase_q <= TEMPLATE_PHASE_VALIDATE;
			end
			else if(ctrl_template_latch_schedule_w)begin
				template_phase_q <= TEMPLATE_PHASE_HEADER;
			end

			if(ctrl_get_delta_select_escape_w)begin
				escape_phase_q <= ESCAPE_PHASE_MODE;
			end
			else if(ctrl_escape_capture_mode_w)begin
				escape_phase_q <= ESCAPE_PHASE_PAYLOAD;
			end
			else if(ctrl_escape_capture_payload_w)begin
				escape_phase_q <= ESCAPE_PHASE_MODE;
			end
		end
	end

	// Dictionary entries are Queue-local and are written once before execution.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			dictionary_count_q <= '0;
			dictionary_index_q <= '0;
			dictionary_lookup_index_q <= '0;
			for(dictionary_reset_index = 0; dictionary_reset_index < 7; dictionary_reset_index = dictionary_reset_index + 1)begin
				dictionary_start_q[dictionary_reset_index] <= '0;
				dictionary_operand_q[dictionary_reset_index] <= '0;
			end
		end
		else begin
			if(ctrl_dict_store_capture_count_w)begin
				dictionary_count_q <= reservoir_q[2:0];
				dictionary_index_q <= 3'd0;
			end
			if(ctrl_dict_store_capture_entry_w)begin
				dictionary_start_q[dictionary_index_q] <= {10'd0, reservoir_q[21:0]};
				dictionary_operand_q[dictionary_index_q] <= {{18{reservoir_q[35]}}, reservoir_q[35:22]};
				if((dictionary_index_q + 1'b1) != dictionary_count_q)begin
					dictionary_index_q <= dictionary_index_q + 1'b1;
				end
			end
			if(ctrl_get_delta_capture_lookup_w)begin
				dictionary_lookup_index_q <= delta_prefix_symbol_w;
			end
		end
	end

	// Running state and pending Delta fields are independent of Run boundaries.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			running_start_cycle_q <= '0;
			running_operand_q <= '0;
			pending_delta_start_q <= '0;
			pending_delta_operand_q <= '0;
			delta_wide_q <= 1'b0;
		end
		else begin
			if(ctrl_init_global_capture_state_w)begin
				running_start_cycle_q <= reservoir_q[31:0];
				running_operand_q <= reservoir_q[32+:OPERAND_BITS];
			end
			else if(ctrl_apply_delta_update_state_w)begin
				running_start_cycle_q <= delta_start_sum_w[31:0];
				running_operand_q <= delta_operand_sum_w[12:0];
			end

			if(ctrl_dict_lookup_select_entry_w)begin
				pending_delta_start_q <= dictionary_start_q[dictionary_lookup_index_q];
				pending_delta_operand_q <= dictionary_operand_q[dictionary_lookup_index_q];
			end
			else if(ctrl_escape_capture_payload_w)begin
				if(delta_wide_q)begin
					pending_delta_start_q <= reservoir_q[31:0];
					pending_delta_operand_q <= $signed(reservoir_q[63:32]);
				end
				else begin
					pending_delta_start_q <= {10'd0, reservoir_q[21:0]};
					pending_delta_operand_q <= {{18{reservoir_q[35]}}, reservoir_q[35:22]};
				end
			end

			if(ctrl_escape_capture_mode_w)begin
				delta_wide_q <= reservoir_q[0];
			end
		end
	end

	// Template capture and normalized schedule registers are updated once per Run.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			template_extended_q <= 1'b0;
			template_shape_q <= '0;
			template_native_q <= '0;
			template_payload_q <= '0;
			template_payload_count_q <= '0;
			template_payload_target_q <= '0;
			template_inner_count_q <= 32'd1;
			template_inner_interval_q <= 32'd1;
			template_inner_stride_q <= 32'sd0;
			template_outer_count_q <= 32'd1;
			template_outer_interval_q <= 32'd1;
			template_outer_stride_q <= 32'sd0;
			template_target_q <= TARGET_NONE;
		end
		else begin
			if(ctrl_template_capture_extended_w)begin
				template_extended_q <= 1'b1;
				template_shape_q <= 2'd0;
				template_native_q <= '0;
				template_native_q[NATIVE_BITS-1:0] <= reservoir_q[NATIVE_BITS:1];
				template_payload_q <= '0;
				template_payload_count_q <= 8'd0;
				template_payload_target_q <= 8'd194;
			end
			else if(ctrl_template_capture_compact_w)begin
				template_extended_q <= 1'b0;
				template_shape_q <= header_shape_w;
				template_target_q <= header_target_w;
				template_native_q <= compact_native_w;
				template_payload_q <= '0;
				template_payload_count_q <= 8'd0;
				template_payload_target_q <= compact_payload_target_w;
			end
			else if(ctrl_template_capture_payload_w)begin
				for(template_bit_index = 0; template_bit_index < 64; template_bit_index = template_bit_index + 1)begin
					if(template_bit_index[7:0] < template_chunk_width_w)begin
						template_payload_q[template_payload_count_q + template_bit_index] <= reservoir_q[template_bit_index];
					end
				end
				template_payload_count_q <= template_payload_count_q + template_chunk_width_w;
			end

			if(ctrl_template_latch_schedule_w)begin
				template_inner_count_q <= decoded_inner_count_w;
				template_inner_interval_q <= decoded_inner_interval_w;
				template_inner_stride_q <= decoded_inner_stride_w;
				template_outer_count_q <= decoded_outer_count_w;
				template_outer_interval_q <= decoded_outer_interval_w;
				template_outer_stride_q <= decoded_outer_stride_w;
				template_target_q <= decoded_target_w;
			end
		end
	end

	// Context registers separate generation from delivery; OUTPUT_CONTEXT is the
	// only state that asserts valid, and backpressure cannot change these fields.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			context_instruction_q <= '0;
			context_start_cycle_q <= '0;
			context_inner_count_q <= '0;
			context_inner_interval_q <= '0;
			context_inner_stride_q <= '0;
			context_outer_count_q <= '0;
			context_outer_interval_q <= '0;
			context_outer_stride_q <= '0;
			context_target_q <= '0;
			context_operand_q <= '0;
		end
		else begin
			if(ctrl_template_load_initial_context_w)begin
				context_instruction_q <= mxm_instruction_with_operand(template_native_q, decoded_target_w, running_operand_q);
				context_start_cycle_q <= running_start_cycle_q;
				context_inner_count_q <= decoded_inner_count_w;
				context_inner_interval_q <= decoded_inner_interval_w;
				context_inner_stride_q <= decoded_inner_stride_w;
				context_outer_count_q <= decoded_outer_count_w;
				context_outer_interval_q <= decoded_outer_interval_w;
				context_outer_stride_q <= decoded_outer_stride_w;
				context_target_q <= decoded_target_w;
				context_operand_q <= running_operand_q;
			end
			else if(ctrl_apply_delta_load_context_w)begin
				context_instruction_q <= mxm_instruction_with_operand(template_native_q, template_target_q, delta_operand_sum_w[12:0]);
				context_start_cycle_q <= delta_start_sum_w[31:0];
				context_inner_count_q <= template_inner_count_q;
				context_inner_interval_q <= template_inner_interval_q;
				context_inner_stride_q <= template_inner_stride_q;
				context_outer_count_q <= template_outer_count_q;
				context_outer_interval_q <= template_outer_interval_q;
				context_outer_stride_q <= template_outer_stride_q;
				context_target_q <= template_target_q;
				context_operand_q <= delta_operand_sum_w[12:0];
			end
		end
	end

	// Fault code is captured at the failing state and remains sticky until reset.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			fault_q <= 1'b0;
			fault_code_q <= FAULT_NONE;
		end
		else if(ctrl_set_fault_w)begin
			fault_q <= 1'b1;
			fault_code_q <= ctrl_fault_code_w;
		end
	end
endmodule
