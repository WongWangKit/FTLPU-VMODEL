module lpu_program_load_segment #(
	parameter integer ELASTIC_DEPTH = 2,
	parameter integer SEGMENT_TARGET_KIND = 0,
	parameter integer QUEUE_BASE = 0,
	parameter integer QUEUE_COUNT = 4
) (
	input logic clk_i,
	input logic rst_ni,

	input logic input_valid_i,
	output logic input_ready_o,
	input logic [2:0] input_control_i,
	input logic [127:0] input_data_i,
	input logic [3:0] input_strb_i,
	input logic [1:0] input_hemisphere_i,
	input logic [3:0] input_target_kind_i,
	input logic [7:0] input_queue_id_i,
	input logic [16:0] input_imem_address_i,
	input logic input_last_i,

	output logic local_valid_o,
	input logic local_ready_i,
	output logic [2:0] local_control_o,
	output logic [127:0] local_data_o,
	output logic [3:0] local_strb_o,
	output logic [1:0] local_hemisphere_o,
	output logic [3:0] local_target_kind_o,
	output logic [7:0] local_queue_id_o,
	output logic [16:0] local_imem_address_o,
	output logic local_last_o,

	output logic forward_valid_o,
	input logic forward_ready_i,
	output logic [2:0] forward_control_o,
	output logic [127:0] forward_data_o,
	output logic [3:0] forward_strb_o,
	output logic [1:0] forward_hemisphere_o,
	output logic [3:0] forward_target_kind_o,
	output logic [7:0] forward_queue_id_o,
	output logic [16:0] forward_imem_address_o,
	output logic forward_last_o,

	output logic idle_o
);
	import lpu_program_load_pkg::*;

	logic head_valid;
	logic head_ready;
	logic [2:0] head_control;
	logic [127:0] head_data;
	logic [3:0] head_strb;
	logic [1:0] head_hemisphere;
	logic [3:0] head_target_kind;
	logic [7:0] head_queue_id;
	logic [16:0] head_imem_address;
	logic head_last;
	logic elastic_idle;

	logic broadcast_w;
	logic target_kind_match_w;
	logic queue_in_segment_w;
	logic local_required_w;
	logic forward_required_w;
	logic local_done_q;
	logic forward_done_q;
	logic local_fire;
	logic forward_fire;
	logic local_complete_w;
	logic forward_complete_w;

	initial begin
		if(QUEUE_COUNT < 1 || QUEUE_BASE < 0 || QUEUE_BASE + QUEUE_COUNT > 256)begin
			$error("segment queue range must fit the 8-bit local queue ID");
		end
	end

	lpu_program_load_elastic_stage #(
		.DEPTH(ELASTIC_DEPTH)
	) u_input_elastic (
		.clk_i,
		.rst_ni,
		.input_valid_i,
		.input_ready_o,
		.input_control_i,
		.input_data_i,
		.input_strb_i,
		.input_hemisphere_i,
		.input_target_kind_i,
		.input_queue_id_i,
		.input_imem_address_i,
		.input_last_i,
		.output_valid_o(head_valid),
		.output_ready_i(head_ready),
		.output_control_o(head_control),
		.output_data_o(head_data),
		.output_strb_o(head_strb),
		.output_hemisphere_o(head_hemisphere),
		.output_target_kind_o(head_target_kind),
		.output_queue_id_o(head_queue_id),
		.output_imem_address_o(head_imem_address),
		.output_last_o(head_last),
		.level_o(),
		.idle_o(elastic_idle)
	);

	assign broadcast_w = head_control != PROGRAM_LOAD_WRITE;
	assign target_kind_match_w = head_target_kind == SEGMENT_TARGET_KIND;
	assign queue_in_segment_w = (head_queue_id >= QUEUE_BASE) &&
		(head_queue_id < QUEUE_BASE + QUEUE_COUNT);
	assign local_required_w = target_kind_match_w &&
		(broadcast_w || queue_in_segment_w);
	assign forward_required_w = broadcast_w || !local_required_w;

	assign local_valid_o = head_valid && local_required_w && !local_done_q;
	assign forward_valid_o = head_valid && forward_required_w && !forward_done_q;
	assign local_fire = local_valid_o && local_ready_i;
	assign forward_fire = forward_valid_o && forward_ready_i;
	assign local_complete_w = !local_required_w || local_done_q || local_fire;
	assign forward_complete_w = !forward_required_w || forward_done_q || forward_fire;
	assign head_ready = head_valid && local_complete_w && forward_complete_w;

	assign local_control_o = head_control;
	assign local_data_o = head_data;
	assign local_strb_o = head_strb;
	assign local_hemisphere_o = head_hemisphere;
	assign local_target_kind_o = head_target_kind;
	assign local_queue_id_o = head_queue_id;
	assign local_imem_address_o = head_imem_address;
	assign local_last_o = head_last;

	assign forward_control_o = head_control;
	assign forward_data_o = head_data;
	assign forward_strb_o = head_strb;
	assign forward_hemisphere_o = head_hemisphere;
	assign forward_target_kind_o = head_target_kind;
	assign forward_queue_id_o = head_queue_id;
	assign forward_imem_address_o = head_imem_address;
	assign forward_last_o = head_last;
	assign idle_o = elastic_idle && !local_done_q && !forward_done_q;

	// A broadcast may complete its local and forward branches on different cycles.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			local_done_q <= 1'b0;
			forward_done_q <= 1'b0;
		end
		else begin
			if(head_ready)begin
				local_done_q <= 1'b0;
				forward_done_q <= 1'b0;
			end
			else begin
				if(local_fire)begin
					local_done_q <= 1'b1;
				end
				if(forward_fire)begin
					forward_done_q <= 1'b1;
				end
			end
		end
	end
endmodule
