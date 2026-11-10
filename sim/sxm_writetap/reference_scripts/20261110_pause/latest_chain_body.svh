  // Only boundary-valid/data from the unchanged latest MXM enter this fabric.
  // Sample the module-level issue calendar on the opposite edge. The upstream
  // TB increments its integer cycle with a blocking posedge assignment; using
  // that variable as an asynchronous job wire creates a testbench race.
  reg sxm_job=0;
  always @(negedge clk)sxm_job=run && first_load_cycle>=0 && cycle-first_load_cycle==backend_start(3)+5;
  wire mem_ready,mem_done,mem_busy,mem_fault;
  wire [3:0] mem_cap;
  wire [127:0] read_valid;
  wire [8191:0] read_data;
  wire [31:0] committed;
  reg [31:0] read_issue=0;
  reg [1023:0] read_cmd=0;
  wire [95:0] lane_map;
  for(genvar t=0;t<4;t++)for(genvar l=0;l<8;l++)assign lane_map[t*24+l*3+:3]=3'(l);
  lpu_sxm_triangle_mem_integration #(.T(4),.DEPTH(1024),.FABRIC_COLUMNS(6),.MEM_LEFT(3)) fabric(
    .clk_i(clk),.rst_ni(rst_n),.job_valid_i(sxm_job),.fp32_i(FORMAT!=0),.resources_ready_i(1'b1),
    .matrices_i(16'd32),.base_i(15'd16),.tile_map_i(8'he4),.lane_map_i(lane_map),.job_ready_o(mem_ready),
    .cap_valid_i(rv),.cap_data_i(rd),.cap_accept_o(mem_cap),.read_issue_valid_i(read_issue),.read_issue_i(read_cmd),
    .read_valid_o(read_valid),.read_data_o(read_data),.committed_segments_o(committed),.done_o(mem_done),.busy_o(mem_busy),.fault_o(mem_fault),.tap_sample_o());
  reg [31:0] observed[0:31][0:31][0:31];
  integer incoming_count[0:3],memory_done_count=0;
  integer read_segments=0,consumer_words=0,consumer_jobs=0;
  initial for(integer t=0;t<4;t++)incoming_count[t]=0;
  always @(posedge clk)if(rst_n)begin
    if(mem_fault || mem_cap!==rv)$fatal(1,"actual latest MXM/fabric capture fault cycle=%0d rel=%0d job=%b cap=%h rv=%h fault=%b core=%b writer=%b monitor=%b bad=%b",cycle,cycle-first_load_cycle,sxm_job,mem_cap,rv,mem_fault,fabric.core_fault,fabric.writer_fault,fabric.monitor_bad,fabric.bad_q);
    if(mem_done)memory_done_count++;
    for(integer t=0;t<4;t++)if(rv[t])begin
      for(integer l=0;l<8;l++)observed[incoming_count[t]/32][incoming_count[t]%32][8*t+l]=rd[t*256+l*32+:32];
      incoming_count[t]++;
    end
  end
  // Four unchanged latest VXM Tile execution engines. Only module-level
  // configuration/execute expansion is provided; datapath and collectors intact.
  reg load_vx=0,execute_vx=0;
  reg [55:0] vx_instructions=0;
  vxm_global_config_t vx_config;
  wire [3:0] vx_ready,vx_execute_ready,vx_idle,vx_done,vx_fault;
  wire [127:0] consumed,vx_valid;
  wire [8191:0] vx_data;
  for(genvar t=0;t<4;t++)begin:g_vxm
    lpu_vxm_tile_execution u_vxm(
      .clk_i(clk),.rst_ni(rst_n),.local_config_load_i(load_vx),.local_config_ready_o(vx_ready[t]),.local_config_active_i(8'hff),.local_config_instruction_i(vx_instructions),
      .execute_valid_i(execute_vx),.execute_ready_o(vx_execute_ready[t]),.repeat_control_i(4'b1011),.config_done_o(vx_done[t]),
      .global_config_valid_i(load_vx),.global_config_i(vx_config),.stream_valid_i(read_valid[t*32+:32]),.stream_data_i(read_data[t*2048+:2048]),.stream_consumed_o(consumed[t*32+:32]),
      .immediate_valid_i('0),.immediate_data_i('0),
      .lut_config_valid_i(1'b0),.lut_config_bank_i('0),.lut_config_input_min_i('0),.lut_config_segment_width_i('0),
      .lut_write_valid_i(1'b0),.lut_write_bank_i('0),.lut_write_address_i('0),.lut_write_k_i('0),.lut_write_b_i('0),.lut_write_log_i('0),
      .lut_shared_configured_i('0),.lut_shared_input_min_i('0),.lut_shared_segment_width_i('0),
      .lut_lane_response_valid_i('0),.lut_lane_response_stage_i('0),.lut_lane_response_k_i('0),.lut_lane_response_b_i('0),.lut_lane_response_log_i('0),
      .lut_lane_request_valid_o(),.lut_lane_request_address_o(),.lut_lane_request_stage_o(),
      .tail_valid_o(),.tail_value_o(),.tail_original_o(),.tail_auxiliary_o(),
      .accumulator_state_valid_o(),.accumulator_state_data_o(),.feedback_state_valid_o(),.feedback_state_value_o(),.instruction_pending_o(),
      .output_ready_i('1),.output_valid_o(vx_valid[t*32+:32]),.output_data_o(vx_data[t*2048+:2048]),.idle_o(vx_idle[t]),.fault_o(vx_fault[t]));
  end
  integer depth_now=2,first_row=0;
  bit high_phase[0:3][0:7];reg [15:0] output_low[0:3][0:7][0:7];
  integer job_checked=0,job_done[0:3];
  function automatic integer exact_integer(input reg [31:0] bits);
    reg [31:0] x,mant;
    integer exp;
    begin
      x=FORMAT!=0?bits:{bits[15:0],16'b0};exp=int'(x[30:23])-127;
      mant={8'b0,1'b1,x[22:0]};
      exact_integer=exp>=23?int'(mant<<(exp-23)):int'(mant>>(23-exp));
    end
  endfunction
  function automatic [31:0] sum_gold(input integer global_row,tile,lane);
    integer r0,r1;
    r0=exact_integer(observed[global_row/32][8*tile+lane][global_row%32]);
    r1=exact_integer(observed[(global_row+1)/32][8*tile+lane][(global_row+1)%32]);
    sum_gold=fp32_integer(r0+r1);
  endfunction
  always @(posedge clk)if(rst_n)begin
    if(|vx_fault)$fatal(1,"VXM consumer fault");
    if(read_valid!==consumed)$fatal(1,"MEM Read not accepted by real VXM collector");
    for(integer t=0;t<4;t++)begin
      if(vx_done[t])job_done[t]++;
      for(integer st=0;st<32;st++)if(read_valid[t*32+st])read_segments++;
      for(integer b=0;b<8;b++)if(vx_valid[t*32+2*b])begin
        integer head,group,branch,logical_row;
        head=2*b+2-depth_now;group=(head%8)/depth_now;branch=head/8;
        logical_row=first_row+4*group+2*branch;
        if(head<0 || (2*b+2)%depth_now!=0 || !vx_valid[t*32+2*b+1])$fatal(1,"VXM chain tail placement");
        for(integer l=0;l<8;l++)begin
          reg [15:0] halfword;
          halfword={vx_data[(t*32+2*b+1)*64+l*8+:8],vx_data[(t*32+2*b)*64+l*8+:8]};
          if(!high_phase[t][b])output_low[t][b][l]=halfword;
          else begin
            if({halfword,output_low[t][b][l]}!==sum_gold(logical_row,t,l))$fatal(1,"VXM numerical result chain%0d row%0d tile%0d lane%0d",depth_now,logical_row,t,l);
            consumer_words++;job_checked++;
          end
        end
        high_phase[t][b]=!high_phase[t][b];
      end
    end
  end
  task automatic consumer_tick;
    #1;if(mem_fault || |vx_fault)$fatal(1,"consumer/fabric fault");
    @(posedge clk);#1;@(negedge clk);read_issue=0;read_cmd=0;load_vx=0;execute_vx=0;
  endtask
  task automatic consume_all;
    integer rows_per_job,job_n,tick,row_ix,phase,b,g,st,global_row,head,operand,branch,stream,delta;
    begin
      if(mem_busy || memory_done_count!=1 || committed!=32'(32*8*4*4*(FORMAT!=0?4:2)))$fatal(1,"MEM producer not committed/drained");
      for(integer t=0;t<4;t++)if(incoming_count[t]!=1024)$fatal(1,"MXM missing input");
      for(depth_now=2;depth_now<=8;depth_now*=2)begin
        rows_per_job=32/depth_now;
        for(first_row=0;first_row<1024;first_row+=rows_per_job)begin
          job_checked=0;
          for(integer t=0;t<4;t++)begin job_done[t]=0;for(integer b0=0;b0<8;b0++)high_phase[t][b0]=0;end
          vx_config=0;vx_config.chain_length=depth_now==2?VXM_CHAIN_LENGTH_2:depth_now==4?VXM_CHAIN_LENGTH_4:VXM_CHAIN_LENGTH_8;
          vx_config.compute_dtype=VXM_FORMAT_FP32;vx_config.lhs_dtype=FORMAT!=0?VXM_FORMAT_FP32:VXM_FORMAT_BF16;vx_config.rhs_dtype=vx_config.lhs_dtype;
          vx_config.lhs_read_bits=FORMAT!=0?VXM_READ_BITS_32:VXM_READ_BITS_16;vx_config.rhs_read_bits=vx_config.lhs_read_bits;
          vx_instructions=0;for(integer h=0;h<8;h+=depth_now)vx_instructions[h*7+:3]=VXM_LOCAL_ADD[2:0];
          #1;if(!(&vx_ready))$fatal(1,"VXM config not ready");load_vx=1;consumer_tick();
          #1;if(!(&vx_execute_ready))$fatal(1,"VXM execute not ready");execute_vx=1;consumer_tick();
          // Each MEM Read row is eight cycles apart. Compensate bank-group
          // distance; low/high halves go to the SAME native stream pair.
          for(tick=0;tick<rows_per_job*8+50;tick++)begin
            for(g=0;g<4;g++)for(phase=0;phase<2;phase++)begin
              delta=tick-8+(5-g)-phase;
              if(delta>=0 && delta%8==0 && delta/8<rows_per_job && (FORMAT!=0 || phase==0))begin
                row_ix=delta/8;global_row=first_row+row_ix;
                if(((global_row%8)*(FORMAT!=0?4:2))/8==g)for(b=0;b<2;b++)begin
                  st=(global_row%8)*(FORMAT!=0?4:2)+2*phase+b;
                  head=(row_ix/4)*depth_now;branch=(row_ix%4)/2;operand=row_ix%2;
                  stream=head*2+branch*16+operand*2+b;
                  read_issue[st]=1;read_cmd[st*32+:32]=(32'(16+global_row/8)<<15)|32'h100|(32'(stream)<<3);
                end
              end
            end
            consumer_tick();
          end
          if(mem_busy || !(&vx_idle) || job_checked!=rows_per_job*16)$fatal(1,"consumer drain/check count depth%0d rows%0d got%0d",depth_now,rows_per_job,job_checked);
          for(integer t=0;t<4;t++)if(job_done[t]!=1)$fatal(1,"VXM completion count");
          consumer_jobs++;
        end
      end
      if(consumer_words!=3*16384 || read_segments!=3*32*8*4*4*(FORMAT!=0?4:2))$fatal(1,"full consumer coverage counts");
      $display("LATEST_CHAIN_PASS FP=%0d matrices=32 input_elements=32768 native_commits=%0d read_segments=%0d VXM_words=%0d jobs=%0d chains=2/4/8",FORMAT,committed,read_segments,consumer_words,consumer_jobs);
    end
  endtask
