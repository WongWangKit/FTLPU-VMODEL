module lpu_program_reassembler #(
	parameter integer DMA_DATA_WIDTH = 256,
	parameter integer BUFFER_BYTES = 64,
	parameter integer IMEM_DEPTH = 65536
) (
	input logic clk_i,
	input logic rst_ni,

	input logic config_valid_i,
	output logic config_ready_o,
	input logic [31:0] config_byte_count_i,
	input logic [1:0] config_hemisphere_i,
	input logic [3:0] config_target_kind_i,
	input logic [7:0] config_queue_id_i,
	input logic [1:0] config_format_i,
	input logic [16:0] config_imem_base_address_i,
	input logic config_image_first_i,
	input logic config_image_last_i,
	input logic [15:0] config_expected_word_count_i,
	input logic [7:0] config_dma_id_i,

	input logic response_valid_i,
	output logic response_ready_o,
	input logic [DMA_DATA_WIDTH-1:0] response_data_i,
	input logic [DMA_DATA_WIDTH/8-1:0] response_keep_i,
	input logic response_last_i,
	input logic [7:0] response_id_i,
	input logic response_error_i,

	output logic word_valid_o,
	input logic word_ready_i,
	output logic [127:0] word_data_o,
	output logic [3:0] word_strb_o,
	output logic [1:0] word_hemisphere_o,
	output logic [3:0] word_target_kind_o,
	output logic [7:0] word_queue_id_o,
	output logic [16:0] word_imem_address_o,
	output logic word_image_last_o,

	output logic [31:0] received_byte_count_o,
	output logic [15:0] generated_word_count_o,
	output logic idle_o,
	output logic fault_o,
	output logic [5:0] fault_code_o
);
	import lpu_program_load_pkg::*;

	localparam integer DMA_BYTES = DMA_DATA_WIDTH / 8;
	localparam integer BUFFER_BITS = BUFFER_BYTES * 8;
	localparam integer BUFFER_COUNT_WIDTH = $clog2(BUFFER_BYTES + 1);

	logic [BUFFER_BITS-1:0] buffer_q;
	logic [BUFFER_COUNT_WIDTH-1:0] buffer_count_q;
	logic [BUFFER_BITS-1:0] buffer_after_pop_w;
	logic [BUFFER_COUNT_WIDTH-1:0] count_after_pop_w;
	logic [BUFFER_BITS-1:0] buffer_next_w;
	logic [BUFFER_COUNT_WIDTH-1:0] buffer_count_next_w;

	// Image context remains live across transaction boundaries so partial words survive burst changes.
	logic image_active_q;
	logic config_seen_q;
	logic [1:0] image_hemisphere_q;
	logic [3:0] image_target_kind_q;
	logic [7:0] image_queue_id_q;
	logic [1:0] image_format_q;
	logic [16:0] image_imem_base_address_q;
	logic [15:0] image_expected_word_count_q;
	logic image_last_seen_q;
	logic [31:0] transaction_received_q;
	logic [31:0] image_received_q;
	logic [15:0] generated_word_count_q;

	logic [BUFFER_COUNT_WIDTH-1:0] keep_byte_count_w;
	logic keep_invalid_w;
	logic config_start_w;
	logic config_invalid_w;
	logic response_fire;
	logic word_fire;
	logic final_word_w;
	logic final_word_wait_w;
	logic [4:0] word_bytes_w;
	logic [8:0] word_shift_bits_w;
	logic [31:0] transaction_received_next_w;
	logic [31:0] image_received_next_w;
	logic [31:0] expected_image_bytes_w;
	logic response_id_invalid_w;
	logic response_error_w;
	logic burst_length_invalid_w;
	logic image_length_invalid_w;
	logic fault_q;
	logic [5:0] fault_code_q;
	integer append_index;
	integer byte_index;

	function automatic [BUFFER_COUNT_WIDTH-1:0] count_keep_bytes(
		input logic [DMA_BYTES-1:0] keep
	);
		integer index;
		begin
			count_keep_bytes = '0;
			for(index = 0; index < DMA_BYTES; index = index + 1)begin
				if(keep[index])begin
					count_keep_bytes = count_keep_bytes + 1'b1;
				end
			end
		end
	endfunction

	function automatic logic keep_has_hole(input logic [DMA_BYTES-1:0] keep);
		integer index;
		logic zero_seen;
		begin
			zero_seen = 1'b0;
			keep_has_hole = 1'b0;
			for(index = 0; index < DMA_BYTES; index = index + 1)begin
				if(!keep[index])begin
					zero_seen = 1'b1;
				end
				else if(zero_seen)begin
					keep_has_hole = 1'b1;
				end
			end
		end
	endfunction

	initial begin
		if((DMA_DATA_WIDTH < 8) || ((DMA_DATA_WIDTH % 8) != 0))begin
			$error("DMA_DATA_WIDTH must contain a whole number of bytes");
		end
		if(BUFFER_BYTES < (DMA_BYTES + 15))begin
			$error("BUFFER_BYTES must hold one DMA beat plus one partial instruction word");
		end
	end

	assign word_bytes_w = image_format_q == PROGRAM_FORMAT_96 ? 5'd12 : 5'd16;
	assign word_shift_bits_w = word_bytes_w * 8;
	assign final_word_w = image_active_q &&
		(generated_word_count_q + 1'b1 == image_expected_word_count_q);
	assign final_word_wait_w = final_word_w && !image_last_seen_q;
	assign word_valid_o = image_active_q && !fault_q &&
		(buffer_count_q >= word_bytes_w) && !final_word_wait_w;
	assign word_fire = word_valid_o && word_ready_i;

	assign word_data_o = buffer_q[127:0];
	assign word_strb_o = image_format_q == PROGRAM_FORMAT_96 ? 4'b0111 : 4'b1111;
	assign word_hemisphere_o = image_hemisphere_q;
	assign word_target_kind_o = image_target_kind_q;
	assign word_queue_id_o = image_queue_id_q;
	assign word_imem_address_o = image_imem_base_address_q + generated_word_count_q;
	assign word_image_last_o = final_word_w;

	assign keep_byte_count_w = count_keep_bytes(response_keep_i);
	assign keep_invalid_w = response_fire &&
		((keep_byte_count_w == '0) || keep_has_hole(response_keep_i));
	assign buffer_after_pop_w = word_fire ? (buffer_q >> word_shift_bits_w) : buffer_q;
	assign count_after_pop_w = word_fire ? (buffer_count_q - word_bytes_w) : buffer_count_q;

	// Input and output may fire together; append starts after the bytes removed by the current output.
	always_comb begin
		buffer_next_w = buffer_after_pop_w;
		buffer_count_next_w = count_after_pop_w;
		append_index = 0;
		if(response_fire)begin
			for(byte_index = 0; byte_index < DMA_BYTES; byte_index = byte_index + 1)begin
				if(response_keep_i[byte_index])begin
					buffer_next_w[(count_after_pop_w + append_index) * 8 +: 8] =
						response_data_i[byte_index * 8 +: 8];
					append_index = append_index + 1;
				end
			end
			buffer_count_next_w = count_after_pop_w + keep_byte_count_w;
		end
	end

	assign config_start_w = config_valid_i && !config_seen_q && !fault_q;
	assign config_invalid_w = config_start_w && (
		(config_byte_count_i == '0) ||
		((config_format_i != PROGRAM_FORMAT_96) && (config_format_i != PROGRAM_FORMAT_128)) ||
		((config_hemisphere_i != PROGRAM_HEMISPHERE_EAST) &&
		 (config_hemisphere_i != PROGRAM_HEMISPHERE_WEST)) ||
		(config_target_kind_i > PROGRAM_TARGET_SXM_PERMUTE) ||
		(config_expected_word_count_i == '0) ||
		({1'b0, config_imem_base_address_i} + config_expected_word_count_i > IMEM_DEPTH) ||
		(config_image_first_i && (image_active_q || (buffer_count_q != '0))) ||
		(!config_image_first_i && (!image_active_q ||
			(config_hemisphere_i != image_hemisphere_q) ||
			(config_target_kind_i != image_target_kind_q) ||
			(config_queue_id_i != image_queue_id_q) ||
			(config_format_i != image_format_q) ||
			(config_imem_base_address_i != image_imem_base_address_q) ||
			(config_expected_word_count_i != image_expected_word_count_q))));

	assign response_ready_o = config_seen_q && !fault_q &&
		(count_after_pop_w + keep_byte_count_w <= BUFFER_BYTES);
	assign response_fire = response_valid_i && response_ready_o;
	assign config_ready_o = response_fire && response_last_i;

	assign transaction_received_next_w = transaction_received_q + keep_byte_count_w;
	assign image_received_next_w = image_received_q + keep_byte_count_w;
	assign expected_image_bytes_w = {16'd0, image_expected_word_count_q} *
		(image_format_q == PROGRAM_FORMAT_96 ? 32'd12 : 32'd16);
	assign response_id_invalid_w = response_fire && (response_id_i != config_dma_id_i);
	assign response_error_w = response_fire && response_error_i;
	assign burst_length_invalid_w = response_fire &&
		((transaction_received_next_w > config_byte_count_i) ||
		(response_last_i != (transaction_received_next_w == config_byte_count_i)));
	assign image_length_invalid_w = response_fire && response_last_i && config_image_last_i &&
		(image_received_next_w != expected_image_bytes_w);

	assign received_byte_count_o = image_received_q;
	assign generated_word_count_o = generated_word_count_q;
	assign idle_o = !image_active_q && !config_seen_q && !config_valid_i &&
		(buffer_count_q == '0);
	assign fault_o = fault_q || config_invalid_w || keep_invalid_w ||
		response_id_invalid_w || response_error_w || burst_length_invalid_w ||
		image_length_invalid_w;
	assign fault_code_o = fault_q ? fault_code_q :
		(config_invalid_w ? PROGRAM_FAULT_DESCRIPTOR :
		(keep_invalid_w ? PROGRAM_FAULT_KEEP :
		(response_id_invalid_w ? PROGRAM_FAULT_DMA_ID :
		(response_error_w ? PROGRAM_FAULT_DMA_RESPONSE :
		(burst_length_invalid_w ? PROGRAM_FAULT_BURST_LENGTH :
		(image_length_invalid_w ? PROGRAM_FAULT_IMAGE_LENGTH : PROGRAM_FAULT_NONE))))));

	// The byte reservoir is the only state changed by simultaneous beat acceptance and word emission.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			buffer_q <= '0;
			buffer_count_q <= '0;
		end
		else if(!fault_o && (word_fire || response_fire))begin
			buffer_q <= buffer_next_w;
			buffer_count_q <= buffer_count_next_w;
		end
	end

	// Config remains at the FIFO head until its final response beat is accepted.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			config_seen_q <= 1'b0;
			transaction_received_q <= '0;
		end
		else if(!fault_o)begin
			if(config_start_w && !config_invalid_w)begin
				config_seen_q <= 1'b1;
			end
			if(response_fire)begin
				if(response_last_i)begin
					config_seen_q <= 1'b0;
					transaction_received_q <= '0;
				end
				else begin
					transaction_received_q <= transaction_received_next_w;
				end
			end
		end
	end

	// Image metadata is initialized once and retained while later bursts append residual bytes.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			image_active_q <= 1'b0;
			image_hemisphere_q <= '0;
			image_target_kind_q <= '0;
			image_queue_id_q <= '0;
			image_format_q <= '0;
			image_imem_base_address_q <= '0;
			image_expected_word_count_q <= '0;
			image_last_seen_q <= 1'b0;
			image_received_q <= '0;
			generated_word_count_q <= '0;
		end
		else if(!fault_o)begin
			if(config_start_w && !config_invalid_w && config_image_first_i)begin
				image_active_q <= 1'b1;
				image_hemisphere_q <= config_hemisphere_i;
				image_target_kind_q <= config_target_kind_i;
				image_queue_id_q <= config_queue_id_i;
				image_format_q <= config_format_i;
				image_imem_base_address_q <= config_imem_base_address_i;
				image_expected_word_count_q <= config_expected_word_count_i;
				image_last_seen_q <= 1'b0;
				image_received_q <= '0;
				generated_word_count_q <= '0;
			end

			if(response_fire)begin
				image_received_q <= image_received_next_w;
				if(response_last_i && config_image_last_i)begin
					image_last_seen_q <= 1'b1;
				end
			end

			if(word_fire)begin
				if(final_word_w)begin
					image_active_q <= 1'b0;
					image_last_seen_q <= 1'b0;
					image_received_q <= '0;
					generated_word_count_q <= '0;
				end
				else begin
					generated_word_count_q <= generated_word_count_q + 1'b1;
				end
			end
		end
	end

	// Protocol and geometry violations are sticky and freeze all stream state.
	always_ff @(posedge clk_i or negedge rst_ni) begin
		if(!rst_ni)begin
			fault_q <= 1'b0;
			fault_code_q <= PROGRAM_FAULT_NONE;
		end
		else if(!fault_q)begin
			if(config_invalid_w)begin
				fault_q <= 1'b1;
				fault_code_q <= PROGRAM_FAULT_DESCRIPTOR;
			end
			else if(keep_invalid_w && response_ready_o)begin
				fault_q <= 1'b1;
				fault_code_q <= PROGRAM_FAULT_KEEP;
			end
			else if(response_id_invalid_w)begin
				fault_q <= 1'b1;
				fault_code_q <= PROGRAM_FAULT_DMA_ID;
			end
			else if(response_error_w)begin
				fault_q <= 1'b1;
				fault_code_q <= PROGRAM_FAULT_DMA_RESPONSE;
			end
			else if(burst_length_invalid_w)begin
				fault_q <= 1'b1;
				fault_code_q <= PROGRAM_FAULT_BURST_LENGTH;
			end
			else if(image_length_invalid_w)begin
				fault_q <= 1'b1;
				fault_code_q <= PROGRAM_FAULT_IMAGE_LENGTH;
			end
		end
	end
endmodule
