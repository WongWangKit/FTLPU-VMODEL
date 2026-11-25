module lpu_sxm_subsystem #(parameter integer T=4,MEM_GROUPS=0,DEPTH=4096) (
	output wire [31:0] wt_cmd_valid_o,output wire [1023:0] wt_cmd_o,
    output wire [T*32-1:0] wt_valid_o,output wire [T*2048-1:0] wt_data_o,
    output wire [4*T-1:0] wt_target_o,input wire [T*32-1:0] wt_sample_valid_i,
    input wire [31:0] wt_foreign_cmd_i,input wire [3:0] wt_busy_i,wt_fault_i,
    input wire wt_transport_fault_i,
    input logic clk_i,
	input logic rst_ni,
	input logic run_i,
	input logic ctrl_issue_i, exec_issue_i,
	input logic [127:0] ctrl_word_i, exec_word_i,
	input logic [31:0] ctrl_aux_i,
	output wire busy_o,
	input logic [T*32-1:0] east_inner_valid_i,
	input logic [T*32*64-1:0] east_inner_data_i,
	output logic [T*32-1:0] east_outer_valid_o,
	output logic [T*32*64-1:0] east_outer_data_o,
	input logic [T*32-1:0] west_outer_valid_i,
	input logic [T*32*64-1:0] west_outer_data_i,
	output logic [T*32-1:0] west_inner_valid_o,
	output logic [T*32*64-1:0] west_inner_data_o,
	output logic fault_o,
	output logic conflict_o
);

	localparam P=32;
	wire [T*P*6-1:0] rs,ws;
	wire [T*P-1:0] rv,take,wv;
	wire [T*P*64-1:0] rd,wd;
	wire [3:0] fault,compat_fault;
	wire clash,batch_fault;
    localparam TW=$clog2(T);
    // Local ICU control events: configure one source tile, then launch a finite matrix job.
    wire configure=ctrl_issue_i && ctrl_aux_i==32'h40;
    wire job=ctrl_issue_i && ctrl_aux_i==32'h41;
    wire ready,pending,completion_fault,done;
    wire [31:0] committed_segments;
    logic [T-1:0] configured;
    logic [T*TW-1:0] tile_map;
    logic [T*24-1:0] lane_map;
    logic [31:0] age,cycles_per_tile;
    logic capture,fp32,east;
    logic [4:0] first_stream;
    wire [T-1:0] expected,available,accepted;
    wire [T*32-1:0] consumed;
    wire [T*2048-1:0] cap_data;
    wire format_ok=ctrl_word_i[31]?(MEM_GROUPS>=4 && ctrl_word_i[36:32]<=28):
                                    (MEM_GROUPS>=2 && ctrl_word_i[36:32]<=30);
    wire cfg_ok=ctrl_word_i[2:0]<T && ctrl_word_i[5:3]<T && ctrl_word_i[127:30]==0;
    for(genvar t=0;t<T;t++)begin:g_batch_input
      wire [31:0] valid=east?east_inner_valid_i[t*32+:32]:west_outer_valid_i[t*32+:32];
      wire [2047:0] data=east?east_inner_data_i[t*2048+:2048]:west_outer_data_i[t*2048+:2048];
      wire [31:0] mask=(fp32?32'hf:32'h3)<<first_stream;
      assign expected[t]=capture && age>=t && age<t+cycles_per_tile;
      assign available[t]=expected[t] && (mask & valid)==mask;
      assign consumed[t*32+:32]=accepted[t]?mask:0;
      assign cap_data[t*2048+256+:1792]='0;
      for(genvar l=0;l<8;l++)for(genvar b=0;b<4;b++)
        assign cap_data[t*2048+l*32+b*8+:8]=(b<2 || fp32)?data[(int'(first_stream)+b)*64+l*8+:8]:8'd0;
    end
    always_ff @(posedge clk_i or negedge rst_ni)
      if(!rst_ni)begin configured<=0;tile_map<=0;lane_map<=0;capture<=0;age<=0;
        cycles_per_tile<=0;fp32<=0;east<=0;first_stream<=0;end
      else begin
        if(configure && cfg_ok && !pending)begin
          configured[ctrl_word_i[2:0]]<=1;
          tile_map[int'(ctrl_word_i[2:0])*TW+:TW]<=TW'(ctrl_word_i[5:3]);
          lane_map[int'(ctrl_word_i[2:0])*24+:24]<=ctrl_word_i[29:6];
        end
        if(job && ready)begin age<=0;capture<=1;cycles_per_tile<=32'(ctrl_word_i[30:15])*(8*T);
          fp32<=ctrl_word_i[31];east<=ctrl_word_i[37];first_stream<=ctrl_word_i[36:32];end
        else if(capture)begin age<=age+1;if(age+1>=cycles_per_tile+T-1)capture<=0;end
      end
	lpu_sxm_stream_boundary #(.T(T),.PORTS(P)) boundary(
	  .clk_i,.rst_ni,.run_i,.east_valid_i(east_inner_valid_i & ~(east?consumed:'0)),.east_data_i(east_inner_data_i),
	  .west_valid_i(west_outer_valid_i & ~(east?'0:consumed)),.west_data_i(west_outer_data_i),
	  .east_valid_o(east_outer_valid_o),.east_data_o(east_outer_data_o),
	  .west_valid_o(west_inner_valid_o),.west_data_o(west_inner_data_o),
	  .read_sel_i(rs),.read_valid_o(rv),.read_data_o(rd),.consume_i(take),
	  .write_valid_i(wv),.write_sel_i(ws),.write_data_i(wd),.conflict_o(clash));
	sxm_triangle_writetap_core #(.T(T),.PORT_STREAMS(P),.DEPTH(DEPTH)) u_execution(
	  .clk_i,.rst_ni,.ctrl_valid_i(ctrl_issue_i && !ctrl_aux_i[6]),.ctrl_op_i(ctrl_aux_i[1:0]),.ctrl_ctx_i(ctrl_aux_i[2]),
	  .ctrl_index_i(ctrl_aux_i[5:3]),.ctrl_data_i(ctrl_word_i),
	  .cap_valid_i(exec_issue_i && exec_word_i[0]),.cap_ctx_i(exec_word_i[1]),.cap_tile_i(exec_word_i[4:2]),
	  .cap_group_i(exec_word_i[7:5]),.cap_row_i(exec_word_i[11:8]),
	  .p_valid_i(exec_issue_i && exec_word_i[12]),.p_ctx_i(exec_word_i[13]),.p_dest_i(exec_word_i[16:14]),
	  .p_source_i(exec_word_i[19:17]),.p_row_i(exec_word_i[23:20]),.p_paired_i(exec_word_i[24]),.p_branch_i(exec_word_i[25]),
	  .p_sequence_i(exec_word_i[31:26]),.run_valid_i(exec_word_i[32+:T]&{T{exec_issue_i}}),.run_ctx_i(exec_word_i[36]),
	  .run_delay_i(exec_word_i[52:37]),.run_interval_i(exec_word_i[68:53]),.run_count_i(exec_word_i[74:69]),
	  .run_sequence_i(exec_word_i[80:75]),.sr_read_req_o(rs),.sr_read_valid_i(rv),.sr_read_data_i(rd),
	  .sr_consume_o(take),.sr_write_valid_o(wv),.sr_write_sel_o(ws),.sr_write_data_o(wd),.fault_o(fault),.busy_o,
	  .compat_t_valid_i(1'b0),.compat_p_valid_i(1'b0),.compat_t_family_i('0),.compat_p_family_i('0),
	  .compat_t_raw_i('0),.compat_p_raw_i('0),.compat_fault_o(compat_fault),
	  .batch_job_i(job),.batch_mode_i(2'd0),.batch_dtype_i({1'b0,ctrl_word_i[31]}),
      .batch_count_i(ctrl_word_i[30:15]),.batch_lane_map_i(lane_map),.batch_tile_map_i(tile_map),
      .batch_ready_o(ready),.batch_fault_o(batch_fault),.batch_cap_valid_i(available),
      .batch_lane_valid_i({T*8{1'b1}}),.batch_cap_data_i(cap_data),.batch_cap_accept_o(accepted),
      .batch_block_valid_o(),.batch_block_fp32_o(),.batch_block_vector_o(),
      .batch_block_data_o(),.batch_block_matrix_o(),.batch_block_column_o(),
      .resources_ready_i((&configured) && format_ok && ctrl_word_i[127:38]==0),.base_i(ctrl_word_i[14:0]),
      .mem_busy_i(wt_busy_i),.mem_fault_i(wt_fault_i),.transport_fault_i(wt_transport_fault_i),
      .read_issue_valid_i(wt_foreign_cmd_i),.tap_data_valid_i(wt_sample_valid_i),
      .stream_valid_o(wt_valid_o),.stream_data_o(wt_data_o),.mem_issue_valid_o(wt_cmd_valid_o),.mem_issue_o(wt_cmd_o),
      .target_tap_o(wt_target_o),.target_address_o(),.tap_sample_o(),.pending_o(pending),.writer_busy_o(),
      .writer_fault_o(),.bad_o(),.monitor_bad_o(),.committed_segments_o(committed_segments),.done_o(done),
      .completion_fault_o(completion_fault));
	always_ff @(posedge clk_i or negedge rst_ni)
	  if(!rst_ni)begin fault_o<=0; conflict_o<=0;end
	  else begin fault_o<=fault_o || (|fault) || (|compat_fault) || batch_fault || completion_fault || (expected!=accepted)
        || (configure && (!cfg_ok || pending)) || (ctrl_issue_i && ctrl_aux_i[6] && !configure && !job)
        || (exec_issue_i && (|(exec_word_i[35:32] >> T))); conflict_o<=conflict_o || clash;end
endmodule
