module lpu_mxm_macro_decoder_core #(
	parameter integer QUEUE_KIND = 0,
	parameter integer ACCUMULATOR_ROWS = 1024
) (
	input  logic        clk_i,
	input  logic        rst_ni,

	// MXM packed-v1 uses one 128-bit physical iMEM word per fetch.
	input  logic        word_valid_i,
	output logic        word_ready_o,
	input  logic [127:0] word_i,
	input  logic        word_last_i,

	// The shared core keeps the widest MXM native instruction and operand.
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

	// Terminal status is sticky until reset.
	output logic        done_o,
	output logic        fault_o,
	output logic [3:0]  fault_code_o
);
	localparam integer QUEUE_LOAD = 0;
	localparam integer QUEUE_COMPUTE = 1;
	localparam integer QUEUE_DEQUANT = 2;
	localparam integer NATIVE_BITS = QUEUE_KIND == QUEUE_LOAD ? 29 : QUEUE_KIND == QUEUE_COMPUTE ? 49 : 16;
	localparam integer OPERAND_BITS = QUEUE_KIND == QUEUE_LOAD ? 2 : QUEUE_KIND == QUEUE_COMPUTE ? 13 : 0;
	localparam integer INITIAL_STATE_BITS = 32 + OPERAND_BITS;
	localparam logic [5:0] DEFAULT_NATIVE_WIDTH = NATIVE_BITS;
	localparam logic [8:0] INITIAL_STATE_WIDTH = INITIAL_STATE_BITS;
	localparam logic [13:0] ACCUMULATOR_ROWS_LIMIT = ACCUMULATOR_ROWS;
	localparam integer RESERVOIR_BITS = 384;
	localparam logic [1:0] TARGET_NONE = 2'd0;
	localparam logic [1:0] TARGET_WEIGHT_COLUMN = 2'd2;
	localparam logic [1:0] TARGET_ACCUMULATOR_ADDRESS = 2'd3;

	localparam logic [3:0] FAULT_NONE = 4'd0;
	localparam logic [3:0] FAULT_CONTROL = 4'd1;
	localparam logic [3:0] FAULT_RESERVED = 4'd2;
	localparam logic [3:0] FAULT_TRUNCATED = 4'd3;
	localparam logic [3:0] FAULT_DICTIONARY = 4'd4;
	localparam logic [3:0] FAULT_RUN_LENGTH = 4'd5;
	localparam logic [3:0] FAULT_NATIVE = 4'd6;
	localparam logic [3:0] FAULT_SCHEDULE = 4'd7;
	localparam logic [3:0] FAULT_DELTA = 4'd8;

	// Parsing proceeds from the control word through the packed payload stream.
	typedef enum logic [3:0] {
		STATE_CONTROL,
		STATE_DICTIONARY_COUNT,
		STATE_DICTIONARY_ENTRY,
		STATE_INITIAL_STATE,
		STATE_RUN_PREFIX,
		STATE_RUN_LENGTH,
		STATE_TEMPLATE_HEADER,
		STATE_TEMPLATE_PAYLOAD,
		STATE_TEMPLATE_DECODE,
		STATE_DELTA_PREFIX,
		STATE_DELTA_PAYLOAD,
		STATE_APPLY_DELTA,
		STATE_OUTPUT,
		STATE_DONE,
		STATE_FAULT
	} state_t;

	state_t state_q;
	state_t state_d;

	// Explicit parser controls make each register write and bit-consume operation visible.
	logic consume_bits;
	logic [8:0] consume_width;
	logic load_control;
	logic load_dictionary_count;
	logic load_dictionary_entry;
	logic load_initial_state;
	logic load_single_run;
	logic load_run_length;
	logic load_extended_template;
	logic load_compact_template;
	logic append_template_payload;
	logic latch_template_schedule;
	logic load_dictionary_delta;
	logic load_escape_mode;
	logic load_delta_payload;
	logic emit_initial_context;
	logic emit_delta_context;
	logic clear_context;
	logic set_done;
	logic set_fault;
	logic [3:0] fault_code_d;

	// Word input and cross-word bit reservoir. Bit zero is always consumed first.
	logic [RESERVOIR_BITS-1:0] reservoir_q;
	logic [8:0] reservoir_bits_q;
	logic input_last_q;

	// Control word and delta dictionary state.
	logic [23:0] command_count_q;
	logic [23:0] context_count_q;
	logic [2:0] dictionary_count_q;
	logic [2:0] dictionary_index_q;
	logic [31:0] dictionary_start_q [0:6];
	logic signed [31:0] dictionary_operand_q [0:6];

	// Reconstructed absolute state and remaining records in the current Run.
	logic [31:0] current_start_q;
	logic [12:0] current_operand_q;
	logic [16:0] run_remaining_q;

	// Current MXM Template and its decoded loop schedule.
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

	// Delta parsing state. Operand deltas are signed; start-cycle deltas are unsigned.
	logic [31:0] pending_delta_start_q;
	logic signed [31:0] pending_delta_operand_q;
	logic delta_wide_q;

	// One-entry output holding register implements Context backpressure.
	logic context_valid_q;
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

	// Sticky terminal status.
	logic done_q;
	logic fault_q;
	logic [3:0] fault_code_q;

	// Pure decode results shared by the explicit parser control logic.
	logic word_fire;
	logic [16:0] run_length_value_w;
	logic [7:0] template_remaining_width_w;
	logic [7:0] template_chunk_width_w;
	logic [48:0] compact_native_w;
	logic [7:0] compact_payload_target_w;
	logic [5:0] native_width_w;
	logic [8:0] template_header_width_w;
	logic [1:0] header_shape_w;
	logic [1:0] header_target_w;
	logic [31:0] decoded_inner_count_w;
	logic [31:0] decoded_inner_interval_w;
	logic signed [31:0] decoded_inner_stride_w;
	logic [31:0] decoded_outer_count_w;
	logic [31:0] decoded_outer_interval_w;
	logic signed [31:0] decoded_outer_stride_w;
	logic [1:0] decoded_target_w;
	logic [63:0] decoded_inner_span_w;
	logic decoded_native_invalid_w;
	logic decoded_schedule_invalid_w;
	logic delta_prefix_valid_w;
	logic [2:0] delta_prefix_symbol_w;
	logic [2:0] delta_prefix_width_w;
	logic [32:0] delta_start_sum_w;
	logic signed [33:0] delta_operand_sum_w;

	integer reservoir_bit_index;
	integer template_bit_index;
	integer dictionary_reset_index;

	// Do not accept another word while a Context is pending. This prevents one
	// cycle from accepting input while also replaying an already-consumed Context.
	assign word_ready_o = !done_q && !fault_q && ((state_q == STATE_CONTROL) ||
		((state_q != STATE_OUTPUT) && !input_last_q && (reservoir_bits_q <= 9'd256)));
	assign word_fire = word_valid_i && word_ready_o;

	assign run_length_value_w = {1'b0, reservoir_q[15:0]} + 17'd1;
	assign template_remaining_width_w = template_payload_target_q - template_payload_count_q;
	assign template_chunk_width_w = template_remaining_width_w > 8'd64 ? 8'd64 : template_remaining_width_w;
	assign delta_start_sum_w = {1'b0, current_start_q} + {1'b0, pending_delta_start_q};
	assign delta_operand_sum_w = $signed({21'd0, current_operand_q}) + $signed({{2{pending_delta_operand_q[31]}}, pending_delta_operand_q});

	assign context_valid_o = context_valid_q;
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
	assign done_o = done_q;
	assign fault_o = fault_q;
	assign fault_code_o = fault_code_q;

	// Apply the Queue-specific induction operand without changing other native fields.
	function automatic logic [48:0] mxm_instruction_with_operand(
		input logic [48:0] native_instruction,
		input logic [12:0] operand
	);
		begin
			mxm_instruction_with_operand = native_instruction;
			if(QUEUE_KIND == QUEUE_LOAD && native_instruction[1:0] == 2'd0)begin
				mxm_instruction_with_operand[4:3] = operand[1:0];
			end
			else if(QUEUE_KIND == QUEUE_COMPUTE)begin
				case(native_instruction[1:0])
					2'd1, 2'd2: mxm_instruction_with_operand[27:15] = operand;
					2'd3: begin
						if(native_instruction[3])begin
							mxm_instruction_with_operand[22:10] = operand;
						end
					end
					default: begin
					end
				endcase
			end
		end
	endfunction

	// Native instruction checks reproduce the current CModel MXM decode rules.
	function automatic logic load_native_invalid(input logic [48:0] native_instruction);
		logic [5:0] stream_base;
		begin
			load_native_invalid = 1'b0;
			stream_base = '0;
			case(native_instruction[1:0])
				2'd0: begin
					stream_base = native_instruction[15:10];
					if(!native_instruction[5] && native_instruction[8:6] != 3'd0)begin
						load_native_invalid = 1'b1;
					end
					if((!native_instruction[5] && !native_instruction[9] && stream_base > 6'd24) ||
						(!native_instruction[5] && native_instruction[9] && stream_base > 6'd16) ||
						(native_instruction[5] && !native_instruction[9] && stream_base > 6'd31) ||
						(native_instruction[5] && native_instruction[9] && stream_base > 6'd30))begin
						load_native_invalid = 1'b1;
					end
				end
				2'd3: begin
					stream_base = native_instruction[9:4];
					if(native_instruction[3] || |native_instruction[24:10] || |native_instruction[27:26])begin
						load_native_invalid = 1'b1;
					end
					if((!native_instruction[28] && stream_base > 6'd24) ||
						(native_instruction[28] && stream_base > 6'd30))begin
						load_native_invalid = 1'b1;
					end
				end
				default: load_native_invalid = 1'b1;
			endcase
		end
	endfunction

	function automatic logic compute_native_invalid(input logic [48:0] native_instruction);
		logic [5:0] stream_base;
		logic [5:0] activation_stream_base;
		begin
			compute_native_invalid = 1'b0;
			stream_base = native_instruction[14:9];
			activation_stream_base = native_instruction[8:3];
			case(native_instruction[1:0])
				2'd1: begin
					if(native_instruction[46] || activation_stream_base > 6'd30 ||
						(!native_instruction[48] && stream_base > 6'd28) ||
						(native_instruction[48] && stream_base > 6'd30))begin
						compute_native_invalid = 1'b1;
					end
				end
				2'd2: begin
					if(|native_instruction[8:2] || |native_instruction[43:29] || |native_instruction[47:45] ||
						{1'b0, native_instruction[27:15]} >= ACCUMULATOR_ROWS_LIMIT ||
						(!native_instruction[48] && stream_base > 6'd28) ||
						(native_instruction[48] && stream_base > 6'd30))begin
						compute_native_invalid = 1'b1;
					end
				end
				2'd3: begin
					if(!native_instruction[3] || |native_instruction[48:29] ||
						{1'b0, native_instruction[22:10]} >= ACCUMULATOR_ROWS_LIMIT ||
						(native_instruction[26] && native_instruction[9:4] > 6'd30))begin
						compute_native_invalid = 1'b1;
					end
				end
				default: compute_native_invalid = 1'b1;
			endcase
		end
	endfunction

	// MXM Template headers contain the native instruction, Shape and Target.
	always_comb begin
		compact_native_w = '0;
		native_width_w = DEFAULT_NATIVE_WIDTH;
		if(QUEUE_KIND == QUEUE_LOAD && reservoir_q[2:1] != 2'd3)begin
			native_width_w = 6'd16;
		end
		template_header_width_w = 9'd1 + {3'd0, native_width_w} + (reservoir_q[0] ? 9'd0 : 9'd4);
		header_shape_w = '0;
		header_target_w = '0;
		case(native_width_w)
			6'd16: begin
				compact_native_w[15:0] = reservoir_q[16:1];
				header_shape_w = reservoir_q[18:17];
				header_target_w = reservoir_q[20:19];
			end
			6'd29: begin
				compact_native_w[28:0] = reservoir_q[29:1];
				header_shape_w = reservoir_q[31:30];
				header_target_w = reservoir_q[33:32];
			end
			default: begin
				compact_native_w = reservoir_q[49:1];
				header_shape_w = reservoir_q[51:50];
				header_target_w = reservoir_q[53:52];
			end
		endcase
		case(header_shape_w)
			2'd0: compact_payload_target_w = 8'd0;
			2'd1: compact_payload_target_w = 8'd29;
			2'd2: compact_payload_target_w = 8'd36;
			default: compact_payload_target_w = 8'd65;
		endcase
	end

	// Decode the current Template payload into a normalized two-level schedule.
	always_comb begin
		decoded_inner_count_w = 32'd1;
		decoded_inner_interval_w = 32'd1;
		decoded_inner_stride_w = 32'sd0;
		decoded_outer_count_w = 32'd1;
		decoded_outer_interval_w = 32'd1;
		decoded_outer_stride_w = 32'sd0;
		decoded_target_w = template_target_q;

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
		case(QUEUE_KIND)
			QUEUE_LOAD: decoded_native_invalid_w = load_native_invalid(template_native_q);
			QUEUE_COMPUTE: decoded_native_invalid_w = compute_native_invalid(template_native_q);
			default: decoded_native_invalid_w = 1'b0;
		endcase
		decoded_schedule_invalid_w = (decoded_inner_count_w == 32'd0) || (decoded_inner_interval_w == 32'd0) ||
			(decoded_outer_count_w == 32'd0) || (decoded_outer_interval_w == 32'd0) ||
			((decoded_outer_count_w > 32'd1) && ({32'd0, decoded_outer_interval_w} <= decoded_inner_span_w));
		if(QUEUE_KIND == QUEUE_LOAD)begin
			if(template_native_q[1:0] == 2'd3)begin
				decoded_schedule_invalid_w = decoded_schedule_invalid_w || decoded_target_w != TARGET_NONE ||
					decoded_inner_stride_w != 32'sd0 || decoded_outer_stride_w != 32'sd0;
			end
			else begin
				decoded_schedule_invalid_w = decoded_schedule_invalid_w ||
					(decoded_target_w != TARGET_NONE && decoded_target_w != TARGET_WEIGHT_COLUMN);
			end
		end
		else if(QUEUE_KIND == QUEUE_COMPUTE)begin
			decoded_schedule_invalid_w = decoded_schedule_invalid_w ||
				(decoded_target_w != TARGET_NONE && decoded_target_w != TARGET_ACCUMULATOR_ADDRESS);
		end
		else begin
			decoded_schedule_invalid_w = decoded_schedule_invalid_w || decoded_target_w != TARGET_NONE ||
				decoded_inner_stride_w != 32'sd0 || decoded_outer_stride_w != 32'sd0;
		end
	end

	// Delta symbols use a variable-length LSB-first prefix. Symbol seven selects Escape.
	always_comb begin
		delta_prefix_valid_w = 1'b0;
		delta_prefix_symbol_w = 3'd0;
		delta_prefix_width_w = 3'd0;

		if(reservoir_bits_q >= 9'd1 && !reservoir_q[0])begin
			delta_prefix_valid_w = 1'b1;
			delta_prefix_symbol_w = 3'd0;
			delta_prefix_width_w = 3'd1;
		end
		else if(reservoir_bits_q >= 9'd2 && !reservoir_q[1])begin
			delta_prefix_valid_w = 1'b1;
			delta_prefix_symbol_w = 3'd1;
			delta_prefix_width_w = 3'd2;
		end
		else if(reservoir_bits_q >= 9'd4 && !reservoir_q[2])begin
			delta_prefix_valid_w = 1'b1;
			delta_prefix_symbol_w = reservoir_q[3] ? 3'd3 : 3'd2;
			delta_prefix_width_w = 3'd4;
		end
		else if(reservoir_bits_q >= 9'd5 && reservoir_q[2])begin
			delta_prefix_valid_w = 1'b1;
			if(!reservoir_q[3])begin
				delta_prefix_symbol_w = reservoir_q[4] ? 3'd5 : 3'd4;
			end
			else begin
				delta_prefix_symbol_w = reservoir_q[4] ? 3'd7 : 3'd6;
			end
			delta_prefix_width_w = 3'd5;
		end
	end

	// Explicit parser FSM. A non-control Word refill has priority over parsing so
	// reservoir refill and bit consumption remain mutually exclusive in one cycle.
	always_comb begin
		state_d = state_q;
		consume_bits = 1'b0;
		consume_width = '0;
		load_control = 1'b0;
		load_dictionary_count = 1'b0;
		load_dictionary_entry = 1'b0;
		load_initial_state = 1'b0;
		load_single_run = 1'b0;
		load_run_length = 1'b0;
		load_extended_template = 1'b0;
		load_compact_template = 1'b0;
		append_template_payload = 1'b0;
		latch_template_schedule = 1'b0;
		load_dictionary_delta = 1'b0;
		load_escape_mode = 1'b0;
		load_delta_payload = 1'b0;
		emit_initial_context = 1'b0;
		emit_delta_context = 1'b0;
		clear_context = 1'b0;
		set_done = 1'b0;
		set_fault = 1'b0;
		fault_code_d = FAULT_NONE;

		if(!(word_fire && state_q != STATE_CONTROL))begin
			case(state_q)
				// Control Word, Dictionary, Initial State and Run decoding.
				STATE_CONTROL: begin
					if(word_fire)begin
						if(word_i[127:28] != '0)begin
							set_fault = 1'b1;
							fault_code_d = FAULT_RESERVED;
							state_d = STATE_FAULT;
						end
						else if(!word_i[0] || word_i[3:2] != 2'b01)begin
							set_fault = 1'b1;
							fault_code_d = FAULT_CONTROL;
							state_d = STATE_FAULT;
						end
						else begin
							load_control = 1'b1;
							if(!word_i[1] || word_i[27:4] == 24'd0)begin
								set_done = 1'b1;
								state_d = STATE_DONE;
							end
							else begin
								state_d = STATE_DICTIONARY_COUNT;
							end
						end
					end
				end

				STATE_DICTIONARY_COUNT: begin
					if(reservoir_bits_q >= 9'd3)begin
						consume_bits = 1'b1;
						consume_width = 9'd3;
						load_dictionary_count = 1'b1;
						state_d = reservoir_q[2:0] == 3'd0 ? STATE_INITIAL_STATE : STATE_DICTIONARY_ENTRY;
					end
					else if(input_last_q)begin
						set_fault = 1'b1;
						fault_code_d = FAULT_TRUNCATED;
						state_d = STATE_FAULT;
					end
				end

				STATE_DICTIONARY_ENTRY: begin
					if(reservoir_bits_q >= 9'd36)begin
						consume_bits = 1'b1;
						consume_width = 9'd36;
						load_dictionary_entry = 1'b1;
						if(dictionary_index_q + 1'b1 == dictionary_count_q)begin
							state_d = STATE_INITIAL_STATE;
						end
					end
					else if(input_last_q)begin
						set_fault = 1'b1;
						fault_code_d = FAULT_TRUNCATED;
						state_d = STATE_FAULT;
					end
				end

				STATE_INITIAL_STATE: begin
					if(reservoir_bits_q >= INITIAL_STATE_WIDTH)begin
						consume_bits = 1'b1;
						consume_width = INITIAL_STATE_WIDTH;
						load_initial_state = 1'b1;
						state_d = STATE_RUN_PREFIX;
					end
					else if(input_last_q)begin
						set_fault = 1'b1;
						fault_code_d = FAULT_TRUNCATED;
						state_d = STATE_FAULT;
					end
				end

				STATE_RUN_PREFIX: begin
					if(reservoir_bits_q >= 9'd1)begin
						consume_bits = 1'b1;
						consume_width = 9'd1;
						if(!reservoir_q[0])begin
							load_single_run = 1'b1;
							state_d = STATE_TEMPLATE_HEADER;
						end
						else begin
							state_d = STATE_RUN_LENGTH;
						end
					end
					else if(input_last_q)begin
						set_fault = 1'b1;
						fault_code_d = FAULT_TRUNCATED;
						state_d = STATE_FAULT;
					end
				end

				STATE_RUN_LENGTH: begin
					if(reservoir_bits_q >= 9'd16)begin
						if({7'd0, run_length_value_w} > (command_count_q - context_count_q))begin
							set_fault = 1'b1;
							fault_code_d = FAULT_RUN_LENGTH;
							state_d = STATE_FAULT;
						end
						else begin
							consume_bits = 1'b1;
							consume_width = 9'd16;
							load_run_length = 1'b1;
							state_d = STATE_TEMPLATE_HEADER;
						end
					end
					else if(input_last_q)begin
						set_fault = 1'b1;
						fault_code_d = FAULT_TRUNCATED;
						state_d = STATE_FAULT;
					end
				end

				// Compact/Extended Template collection, normalization and validation.
				STATE_TEMPLATE_HEADER: begin
					if(reservoir_bits_q >= 9'd3)begin
						if(reservoir_bits_q >= template_header_width_w)begin
							consume_bits = 1'b1;
							consume_width = template_header_width_w;
							if(reservoir_q[0])begin
								load_extended_template = 1'b1;
								state_d = STATE_TEMPLATE_PAYLOAD;
							end
							else begin
								load_compact_template = 1'b1;
								state_d = header_shape_w == 2'd0 ? STATE_TEMPLATE_DECODE : STATE_TEMPLATE_PAYLOAD;
							end
						end
						else if(input_last_q)begin
							set_fault = 1'b1;
							fault_code_d = FAULT_TRUNCATED;
							state_d = STATE_FAULT;
						end
					end
					else if(input_last_q)begin
						set_fault = 1'b1;
						fault_code_d = FAULT_TRUNCATED;
						state_d = STATE_FAULT;
					end
				end

				STATE_TEMPLATE_PAYLOAD: begin
					if(reservoir_bits_q >= {1'b0, template_chunk_width_w})begin
						consume_bits = 1'b1;
						consume_width = {1'b0, template_chunk_width_w};
						append_template_payload = 1'b1;
						if(template_payload_count_q + template_chunk_width_w == template_payload_target_q)begin
							state_d = STATE_TEMPLATE_DECODE;
						end
					end
					else if(input_last_q)begin
						set_fault = 1'b1;
						fault_code_d = FAULT_TRUNCATED;
						state_d = STATE_FAULT;
					end
				end

				STATE_TEMPLATE_DECODE: begin
					if(decoded_native_invalid_w)begin
						set_fault = 1'b1;
						fault_code_d = FAULT_NATIVE;
						state_d = STATE_FAULT;
					end
					else if(decoded_schedule_invalid_w)begin
						set_fault = 1'b1;
						fault_code_d = FAULT_SCHEDULE;
						state_d = STATE_FAULT;
					end
					else begin
						latch_template_schedule = 1'b1;
						if(context_count_q == 24'd0)begin
							emit_initial_context = 1'b1;
							state_d = STATE_OUTPUT;
						end
						else begin
							state_d = STATE_DELTA_PREFIX;
						end
					end
				end

				// Dictionary/Escape Delta reconstruction and output backpressure.
				STATE_DELTA_PREFIX: begin
					if(delta_prefix_valid_w)begin
						if(delta_prefix_symbol_w < dictionary_count_q)begin
							consume_bits = 1'b1;
							consume_width = {6'd0, delta_prefix_width_w};
							load_dictionary_delta = 1'b1;
							state_d = STATE_APPLY_DELTA;
						end
						else if(delta_prefix_symbol_w != 3'd7)begin
							set_fault = 1'b1;
							fault_code_d = FAULT_DICTIONARY;
							state_d = STATE_FAULT;
						end
						else if(reservoir_bits_q >= 9'd6)begin
							consume_bits = 1'b1;
							consume_width = 9'd6;
							load_escape_mode = 1'b1;
							state_d = STATE_DELTA_PAYLOAD;
						end
						else if(input_last_q)begin
							set_fault = 1'b1;
							fault_code_d = FAULT_TRUNCATED;
							state_d = STATE_FAULT;
						end
					end
					else if(input_last_q)begin
						set_fault = 1'b1;
						fault_code_d = FAULT_TRUNCATED;
						state_d = STATE_FAULT;
					end
				end

				STATE_DELTA_PAYLOAD: begin
					if(reservoir_bits_q >= (delta_wide_q ? 9'd64 : 9'd36))begin
						consume_bits = 1'b1;
						consume_width = delta_wide_q ? 9'd64 : 9'd36;
						load_delta_payload = 1'b1;
						state_d = STATE_APPLY_DELTA;
					end
					else if(input_last_q)begin
						set_fault = 1'b1;
						fault_code_d = FAULT_TRUNCATED;
						state_d = STATE_FAULT;
					end
				end

				STATE_APPLY_DELTA: begin
					if(delta_start_sum_w[32] || delta_operand_sum_w < 0 ||
						(QUEUE_KIND == QUEUE_LOAD && delta_operand_sum_w > 34'sd3) ||
						(QUEUE_KIND == QUEUE_COMPUTE && delta_operand_sum_w > 34'sd8191) ||
						(QUEUE_KIND == QUEUE_DEQUANT && delta_operand_sum_w != 34'sd0))begin
						set_fault = 1'b1;
						fault_code_d = FAULT_DELTA;
						state_d = STATE_FAULT;
					end
					else begin
						emit_delta_context = 1'b1;
						state_d = STATE_OUTPUT;
					end
				end

				STATE_OUTPUT: begin
					if(context_valid_q && context_ready_i)begin
						clear_context = 1'b1;
						if(context_count_q == command_count_q)begin
							set_done = 1'b1;
							state_d = STATE_DONE;
						end
						else if(run_remaining_q != 17'd0)begin
							state_d = STATE_DELTA_PREFIX;
						end
						else begin
							state_d = STATE_RUN_PREFIX;
						end
					end
				end

				STATE_DONE: begin
					set_done = 1'b1;
				end

				STATE_FAULT: begin
				end

				default: begin
					set_fault = 1'b1;
					fault_code_d = FAULT_CONTROL;
					state_d = STATE_FAULT;
				end
			endcase
		end
	end

	// Parser phase register.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			state_q <= STATE_CONTROL;
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
				if(state_q == STATE_CONTROL)begin
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
			else if(consume_bits)begin
				reservoir_q <= reservoir_q >> consume_width;
				reservoir_bits_q <= reservoir_bits_q - consume_width;
			end
		end
	end

	// Control word and Dictionary entries are configured once per decoder reset.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			command_count_q <= '0;
			dictionary_count_q <= '0;
			dictionary_index_q <= '0;
			for(dictionary_reset_index = 0; dictionary_reset_index < 7; dictionary_reset_index = dictionary_reset_index + 1)begin
				dictionary_start_q[dictionary_reset_index] <= '0;
				dictionary_operand_q[dictionary_reset_index] <= '0;
			end
		end
		else begin
			if(load_control)begin
				command_count_q <= word_i[27:4];
			end
			if(load_dictionary_count)begin
				dictionary_count_q <= reservoir_q[2:0];
				dictionary_index_q <= 3'd0;
			end
			if(load_dictionary_entry)begin
				dictionary_start_q[dictionary_index_q] <= {10'd0, reservoir_q[21:0]};
				dictionary_operand_q[dictionary_index_q] <= {{18{reservoir_q[35]}}, reservoir_q[35:22]};
				if(dictionary_index_q + 1'b1 != dictionary_count_q)begin
					dictionary_index_q <= dictionary_index_q + 1'b1;
				end
			end
		end
	end

	// Absolute reconstruction state, Run count and pending Delta fields.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			current_start_q <= '0;
			current_operand_q <= '0;
			run_remaining_q <= '0;
			pending_delta_start_q <= '0;
			pending_delta_operand_q <= '0;
			delta_wide_q <= 1'b0;
		end
		else begin
			if(load_initial_state)begin
				current_start_q <= reservoir_q[31:0];
				if(QUEUE_KIND == QUEUE_LOAD)begin
					current_operand_q <= {11'd0, reservoir_q[33:32]};
				end
				else if(QUEUE_KIND == QUEUE_COMPUTE)begin
					current_operand_q <= reservoir_q[44:32];
				end
				else begin
					current_operand_q <= '0;
				end
			end
			else if(emit_delta_context)begin
				current_start_q <= delta_start_sum_w[31:0];
				current_operand_q <= delta_operand_sum_w[12:0];
			end

			if(load_single_run)begin
				run_remaining_q <= 17'd1;
			end
			else if(load_run_length)begin
				run_remaining_q <= run_length_value_w;
			end
			else if(emit_initial_context || emit_delta_context)begin
				run_remaining_q <= run_remaining_q - 1'b1;
			end

			if(load_dictionary_delta)begin
				pending_delta_start_q <= dictionary_start_q[delta_prefix_symbol_w];
				pending_delta_operand_q <= dictionary_operand_q[delta_prefix_symbol_w];
			end
			else if(load_delta_payload)begin
				if(delta_wide_q)begin
					pending_delta_start_q <= reservoir_q[31:0];
					pending_delta_operand_q <= $signed(reservoir_q[63:32]);
				end
				else begin
					pending_delta_start_q <= {10'd0, reservoir_q[21:0]};
					pending_delta_operand_q <= {{18{reservoir_q[35]}}, reservoir_q[35:22]};
				end
			end

			if(load_escape_mode)begin
				delta_wide_q <= reservoir_q[5];
			end
		end
	end

	// Template capture and normalized schedule registers.
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
			template_inner_stride_q <= '0;
			template_outer_count_q <= 32'd1;
			template_outer_interval_q <= 32'd1;
			template_outer_stride_q <= '0;
			template_target_q <= TARGET_NONE;
		end
		else begin
			if(load_extended_template)begin
				template_extended_q <= 1'b1;
				template_shape_q <= 2'd0;
				template_native_q <= compact_native_w;
				template_payload_q <= '0;
				template_payload_count_q <= 8'd0;
				template_payload_target_q <= 8'd194;
				template_target_q <= TARGET_NONE;
			end
			else if(load_compact_template)begin
				template_extended_q <= 1'b0;
				template_shape_q <= header_shape_w;
				template_native_q <= compact_native_w;
				template_payload_q <= '0;
				template_payload_count_q <= 8'd0;
				template_payload_target_q <= compact_payload_target_w;
				template_target_q <= header_target_w;
			end
			else if(append_template_payload)begin
				for(template_bit_index = 0; template_bit_index < 64; template_bit_index = template_bit_index + 1)begin
					if(template_bit_index[7:0] < template_chunk_width_w)begin
						template_payload_q[template_payload_count_q + template_bit_index] <= reservoir_q[template_bit_index];
					end
				end
				template_payload_count_q <= template_payload_count_q + template_chunk_width_w;
			end

			if(latch_template_schedule)begin
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

	// Context output registers. Initial Context uses the just-decoded schedule;
	// later Contexts reuse the latched Template and apply one reconstructed Delta.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			context_count_q <= '0;
			context_valid_q <= 1'b0;
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
			if(clear_context)begin
				context_valid_q <= 1'b0;
			end
			else if(emit_initial_context)begin
				context_count_q <= context_count_q + 1'b1;
				context_valid_q <= 1'b1;
				context_instruction_q <= mxm_instruction_with_operand(template_native_q, current_operand_q);
				context_start_cycle_q <= current_start_q;
				context_inner_count_q <= decoded_inner_count_w;
				context_inner_interval_q <= decoded_inner_interval_w;
				context_inner_stride_q <= decoded_inner_stride_w;
				context_outer_count_q <= decoded_outer_count_w;
				context_outer_interval_q <= decoded_outer_interval_w;
				context_outer_stride_q <= decoded_outer_stride_w;
				context_target_q <= decoded_target_w;
				context_operand_q <= current_operand_q;
			end
			else if(emit_delta_context)begin
				context_count_q <= context_count_q + 1'b1;
				context_valid_q <= 1'b1;
				context_instruction_q <= mxm_instruction_with_operand(template_native_q, delta_operand_sum_w[12:0]);
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

	// Done/Fault remain asserted until reset so the caller cannot miss termination.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			done_q <= 1'b0;
			fault_q <= 1'b0;
			fault_code_q <= FAULT_NONE;
		end
		else begin
			if(set_fault)begin
				fault_q <= 1'b1;
				fault_code_q <= fault_code_d;
			end
			else if(set_done)begin
				done_q <= 1'b1;
			end
		end
	end
endmodule
