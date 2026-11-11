`timescale 1ns/1ps
// Five independent instruction streams, real 4x4 array, real dual-bank backend.
module lpu_mxm_core_tb #(parameter integer SCENARIO=0);
  localparam integer R=4,C=4,K=8,N=8,LIMIT=SCENARIO==8?5000:400;
  // 0: earliest first compute, continuous reuse of two loaded tiles.
  // 1: four distinct tiles, continuous 32-beat ping-pong load and compute.
  // 2: one-edge-early first compute must fault (not a successful schedule).
  // 3: deliberately insert an odd compute gap to verify bank phase faults.
  // 4/5: continuous BF16->FP32 / FP32->BF16 at the two output commands.
  // 6: one-edge-late backend prefetch/control must fault without buffering A.
  // 7: 40 activations per tile; weights still take 32 beats, compute has no gap.
  // 8: compiler schedules 1024 beats per group, full-depth SRAM and reload.
  // 9: an odd 33-address pass must collide; 10: even 34-address pass is legal.
  localparam integer BATCH=SCENARIO==8?1024:(SCENARIO==7?40:(SCENARIO==9?33:(SCENARIO==10?34:32)));
  localparam bit REFILL=SCENARIO==1 || SCENARIO==3 || SCENARIO==4 || SCENARIO==5 || SCENARIO>=7;
  import lpu_mxm_isa_pkg::*;
  localparam integer CB=COMPUTE_INSTRUCTION_BITS,LB=LOAD_INSTRUCTION_BITS;
  logic clk=0,rst_n=0,run=0,ce=0,cl=0,le=0,ll=0,be=0,bl=0;
  logic [CB-1:0] ci=0;
  logic [LB-1:0] li=0;
  localparam integer AB=lpu_mxm_backend_isa_pkg::BACKEND_ADDRESS_BITS;
  localparam integer IB=lpu_mxm_backend_isa_pkg::BACKEND_INSTRUCTION_BITS;
  logic [IB-1:0] bi=0;
  localparam integer WS=lpu_mxm_config_pkg::WEIGHT_STREAM_COUNT;
  localparam integer Q=lpu_mxm_config_pkg::WEIGHT_Q_STREAM,SL=lpu_mxm_config_pkg::WEIGHT_SCALE_LO_STREAM;
  localparam integer SH=lpu_mxm_config_pkg::WEIGHT_SCALE_HI_STREAM,Z=lpu_mxm_config_pkg::WEIGHT_ZERO_STREAM;
  logic [R*WS*K*8-1:0] weight_streams;
  logic [R*WS*K-1:0] weight_stream_valid='1;
  wire [R*WS*K-1:0] weight_consumed;
  integer row_load_seq[0:R-1],row_param_seq[0:R-1];
  logic pe=0,pl=0,de=0,dl=0,pi=0,di=0;
  wire per,plr,der,dlr;
  wire [R-1:0] prv,drv,pri,dri;
  wire cr,clr,lr,llr,br,blr,fault,frontend_fault,backend_fault;
  wire [R-1:0] cv,lv;
  wire [R*CB-1:0] cp;
  wire [R*LB-1:0] lp;
  wire [R*16-1:0] cx,lx;
  wire [C-1:0] pv,rv;
  wire [C*N*32-1:0] pd,rd;
  wire [C*16-1:0] pt,rt,ra;
  wire [R-1:0] returned_valid;
  wire [R*N*32-1:0] returned_data;
  wire [R*16-1:0] returned_tag;
  wire [C-1:0] slots,slot_bf16,result_bf16;
  wire [R*C-1:0] cell_wv,cell_wb,cell_av,cell_ab;
  logic [R*C-1:0] sampled_cell_wv,sampled_cell_wb,sampled_cell_av,sampled_cell_ab;
  wire [C-1:0] issue_valid,issue_bf16,alu_valid;
  wire [C*2-1:0] issue_operation;
  wire [C*16-1:0] issue_address,alu_address,alu_tag;
  wire [C*N*32-1:0] operand_a,operand_b;
  logic [C-1:0] consumed_partial,consumed_alu;
  logic [C*N*32-1:0] consumed_data,consumed_a,consumed_b;
  logic [C*16-1:0] consumed_tag,consumed_alu_tag,consumed_alu_address;
  wire [C*2-1:0] ops,bank_requests,bank_writes;
  wire [C*16-1:0] slot_address;
  wire [C*2*9-1:0] bank_addresses;
  logic [C*2-1:0] serviced_requests,serviced_writes;
  logic [C*2*9-1:0] serviced_addresses;
  logic [R*K*16-1:0] activation;
  integer trace_fd=0;
  logic [R-1:0] accepted_activation,accepted_weight;
  logic [R*16-1:0] accepted_compute_index,accepted_load_index;
  logic [R-1:0] accepted_compute_buffer,accepted_load_buffer;
  logic [R*16-1:0] sampled_activation_lane0,sampled_weight_lane0;
  string trace_path,vcd_path;
  initial begin
    if($value$plusargs("trace_path=%s",trace_path)) begin
      trace_fd=$fopen(trace_path,"w");if(!trace_fd) $fatal(1,"cannot open core trace");
      $fdisplay(trace_fd,"sample_ns,reset_n,run,compute_launch,backend_launch,column,partial_valid,partial_tag,partial_lane0,result_valid,result_tag,result_address,result_lane0,fault,load_launch,compute_row_valid,compute_row_buffer,compute_row_tag,load_row_valid,load_row_buffer,load_row_index,activation_accepted,activation_buffer,activation_tag,activation_lane0,weight_accepted,weight_buffer,weight_index,weight_lane0,backend_slot_valid,backend_operation,backend_address,bank0_valid,bank0_write,bank0_address,bank1_valid,bank1_write,bank1_address,frontend_fault,backend_fault,result_bf16,backend_bf16,issue_valid,issue_operation,issue_address,issue_bf16,partial_accepted,accepted_partial_tag,accepted_partial_lane0,alu_valid,alu_tag,alu_address,operand_a0,operand_b0,cell_weight_accepted,cell_weight_buffer,cell_activation_accepted,cell_activation_buffer,returned_valid,returned_tag,returned_lane0");
    end
    if($value$plusargs("vcd_path=%s",vcd_path)) begin
      $dumpfile(vcd_path);$dumpvars(0,clk,rst_n,run,cl,ll,bl,cv,lv,cp,lp,cx,lx,activation,weight_streams,pv,pd,pt,returned_valid,returned_data,returned_tag,rv,rd,rt,ra,slots,ops,slot_bf16,result_bf16,slot_address,issue_valid,issue_address,issue_operation,issue_bf16,alu_valid,operand_a,operand_b,alu_address,alu_tag,bank_requests,bank_writes,bank_addresses,fault,frontend_fault,backend_fault);
    end
  end
  always @(posedge clk) begin
    // Inputs actually consumed at this edge; do not substitute post-NBA valid.
    accepted_activation=cv;accepted_weight=lv;
    serviced_requests=bank_requests;serviced_writes=bank_writes;serviced_addresses=bank_addresses;
    consumed_partial=returned_valid;consumed_data=returned_data;consumed_tag=returned_tag;
    consumed_alu=alu_valid;consumed_a=operand_a;consumed_b=operand_b;consumed_alu_tag=alu_tag;consumed_alu_address=alu_address;
    sampled_cell_wv=cell_wv;sampled_cell_wb=cell_wb;sampled_cell_av=cell_av;sampled_cell_ab=cell_ab;
    accepted_compute_index=cx;accepted_load_index=lx;
    for(integer r=0;r<R;r++) begin
      accepted_compute_buffer[r]=cp[r*CB];accepted_load_buffer[r]=lp[r*LB+1];
      sampled_activation_lane0[r*16+:16]=activation[r*K*16+:16];
      sampled_weight_lane0[r*16+:16]={8'b0,weight_streams[(r*WS*K+Q*K)*8+:8]};
    end
    #2;
    if(trace_fd) for(integer c=0;c<C;c++)
      $fdisplay(trace_fd,"%0.3f,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%08h,%0d,%0d,%0d,%08h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%04h,%0d,%0d,%0d,%04h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%08h,%0d,%0d,%0d,%08h,%08h,%0d,%0d,%0d,%0d,%0d,%0d,%08h",
        $realtime,rst_n,run,cl,bl,c,pv[c],pt[c*16+:16],pd[c*N*32+:32],rv[c],rt[c*16+:16],ra[c*16+:16],rd[c*N*32+:32],fault,
        ll,cv[c],cp[c*CB],cx[c*16+:16],lv[c],lp[c*LB+1],lx[c*16+:16],
        accepted_activation[c],accepted_compute_buffer[c],accepted_compute_index[c*16+:16],sampled_activation_lane0[c*16+:16],
        accepted_weight[c],accepted_load_buffer[c],accepted_load_index[c*16+:16],sampled_weight_lane0[c*16+:16],
        slots[c],ops[c*2+:2],slot_address[c*16+:16],
        serviced_requests[c*2],serviced_writes[c*2],serviced_addresses[c*18+:9],
        serviced_requests[c*2+1],serviced_writes[c*2+1],serviced_addresses[c*18+9+:9],frontend_fault,backend_fault,result_bf16[c],slot_bf16[c],
        issue_valid[c],issue_operation[c*2+:2],issue_address[c*16+:16],issue_bf16[c],
        consumed_partial[c],consumed_tag[c*16+:16],consumed_data[c*N*32+:32],consumed_alu[c],consumed_alu_tag[c*16+:16],consumed_alu_address[c*16+:16],consumed_a[c*N*32+:32],consumed_b[c*N*32+:32],
        sampled_cell_wv[c],sampled_cell_wb[c],sampled_cell_av[c],sampled_cell_ab[c],returned_valid[c],returned_tag[c*16+:16],returned_data[c*N*32+:32]);
  end
  final if(trace_fd) $fclose(trace_fd);
  always @(posedge clk) if(rst_n && run) begin
    logic [R*WS*K-1:0] expected_consume;
    expected_consume=0;
    for(integer r=0;r<R;r++) for(integer k=0;k<K;k++) begin
      expected_consume[(r*WS+Q)*K+k]=lv[r];
      expected_consume[(r*WS+SL)*K+k]=prv[r];
      expected_consume[(r*WS+SH)*K+k]=prv[r];
      expected_consume[(r*WS+Z)*K+k]=prv[r];
    end
    if(weight_consumed!==expected_consume || drv!==lv) $fatal(1,"parameter/weight stream consume or instruction phase mismatch");
  end
  always #5 clk=~clk;
  lpu_mxm_core dut (
    .clk_i(clk),.rst_ni(rst_n),.run_i(run),
    .compute_enqueue_valid_i(ce),.compute_launch_i(cl),.compute_instruction_i(ci),.compute_enqueue_ready_o(cr),.compute_launch_ready_o(clr),
    .load_enqueue_valid_i(le),.load_launch_i(ll),.load_instruction_i(li),.load_enqueue_ready_o(lr),.load_launch_ready_o(llr),
    .backend_enqueue_valid_i(be),.backend_launch_i(bl),.backend_instruction_i(bi),.backend_enqueue_ready_o(br),.backend_launch_ready_o(blr),
    .param_load_enqueue_valid_i(pe),.param_load_launch_i(pl),.param_load_instruction_i(pi),
    .param_load_enqueue_ready_o(per),.param_load_launch_ready_o(plr),
    .dequant_enqueue_valid_i(de),.dequant_launch_i(dl),.dequant_instruction_i(di),
    .dequant_enqueue_ready_o(der),.dequant_launch_ready_o(dlr),
    .param_load_row_valid_o(prv),.param_load_row_instruction_o(pri),
    .dequant_row_valid_o(drv),.dequant_row_instruction_o(dri),
    .activation_valid_i(cv),.activation_i(activation),.weight_stream_valid_i(weight_stream_valid),.weight_stream_i(weight_streams),.weight_stream_consume_o(weight_consumed),
    .compute_row_valid_o(cv),.load_row_valid_o(lv),.compute_row_instruction_o(cp),.load_row_instruction_o(lp),
    .compute_row_tag_o(cx),.load_row_index_o(lx),.partial_valid_o(pv),.partial_o(pd),.partial_tag_o(pt),
    .returned_valid_o(returned_valid),.returned_o(returned_data),.returned_tag_o(returned_tag),
    .backend_slot_valid_o(slots),.backend_slot_operation_o(ops),.backend_slot_address_o(slot_address),.backend_slot_bf16_o(slot_bf16),
    .backend_issue_valid_o(issue_valid),.backend_issue_operation_o(issue_operation),.backend_issue_address_o(issue_address),.backend_issue_bf16_o(issue_bf16),
    .alu_valid_o(alu_valid),.operand_a_o(operand_a),.operand_b_o(operand_b),.alu_address_o(alu_address),.alu_tag_o(alu_tag),
    .cell_weight_valid_o(cell_wv),.cell_weight_buffer_o(cell_wb),.cell_activation_valid_o(cell_av),.cell_activation_buffer_o(cell_ab),
    .bank_request_valid_o(bank_requests),.bank_write_o(bank_writes),.bank_address_o(bank_addresses),
    .frontend_fault_o(frontend_fault),.backend_fault_o(backend_fault),
    .result_valid_o(rv),.result_bf16_o(result_bf16),.result_o(rd),.result_address_o(ra),.result_tag_o(rt),.fault_o(fault));
  function automatic logic [31:0] fp32_integer(input integer value);
    integer leading;
    logic [31:0] fraction;
    begin
      leading=0;for(integer b=0;b<31;b++) if((value>>b)&1) leading=b;
      fraction=32'(value)<<(23-leading);
      fp32_integer=value==0?32'b0:{1'b0,8'(leading+127),fraction[22:0]};
    end
  endfunction
  function automatic logic [15:0] bf16_integer(input integer value);
    integer leading,step,units,remainder;
    logic [31:0] rounded;
    begin
      leading=0;for(integer b=0;b<31;b++) if((value>>b)&1) leading=b;
      step=leading>7?1<<(leading-7):1;
      units=value/step;remainder=value%step;
      if(remainder*2>step || (remainder*2==step && units%2==1)) units=units+1;
      rounded=fp32_integer(units*step);bf16_integer=rounded[31:16];
    end
  endfunction
  function automatic logic [CB-1:0] compute_word(input integer seq);
    compute_word=CB'(seq%2);
  endfunction
  function automatic integer compute_start(input integer seq);
    compute_start=34+seq*BATCH+(SCENARIO==3 && seq>=2?3:0)-(SCENARIO==2?1:0);
  endfunction
  function automatic integer load_start(input integer seq);
    load_start=seq<2?32*seq:32+(seq-1)*BATCH;
  endfunction
  function automatic integer backend_start(input integer seq);
    case(seq)
      0:backend_start=compute_start(0)+19+R;
      1:backend_start=compute_start(0)+19+R+BATCH/2;
      default:backend_start=compute_start(seq-1)+19+R;
    endcase
    if(SCENARIO==6) backend_start=backend_start+1;
  endfunction
  function automatic logic [IB-1:0] backend_word(input integer beat);
    integer op;
    bit quantized;
    begin
      op=beat<BATCH?1:(beat<2*BATCH?2:(beat<3*BATCH?3:0));
      quantized=(SCENARIO==4 && op==3) || (SCENARIO==5 && op==0);
      backend_word=(IB'(quantized)<<(IB-1)) | (IB'(beat%BATCH)<<2) | IB'(op);
    end
  endfunction
  always @(posedge clk) for(integer r=0;r<R;r++) begin
    if(!rst_n) row_load_seq[r]<=-1;
    else if(run && lv[r] && lx[r*16+:16]==0) row_load_seq[r]<=row_load_seq[r]+1;
  end
  always @(posedge clk) for(integer r=0;r<R;r++) begin
    if(!rst_n) row_param_seq[r]<=-1;
    else if(run && prv[r]) row_param_seq[r]<=row_param_seq[r]+1;
  end
  always_comb begin
    activation=0;weight_streams='1;
    for(integer r=0;r<R;r++) begin
      logic [31:0] a,scale_bits;
      integer load_id;
      load_id=row_load_seq[r]+(lv[r] && lx[r*16+:16]==0?1:0);
      a=fp32_integer((int'(cx[r*16+:16])%BATCH)%3+r+1);
      scale_bits=fp32_integer(row_param_seq[r]+(prv[r]?1:0)+1);
      for(integer k=0;k<K;k++) begin
        activation[(r*K+k)*16+:16]=a[31:16];
        weight_streams[(r*WS*K+Q*K+k)*8+:8]=8'(32-int'(lx[r*16+:16]));
        weight_streams[(r*WS*K+SL*K+k)*8+:8]=scale_bits[23:16];
        weight_streams[(r*WS*K+SH*K+k)*8+:8]=scale_bits[31:24];
        weight_streams[(r*WS*K+Z*K+k)*8+:8]=0;
      end
    end
  end
  bit expected_partial[0:C-1][0:LIMIT],expected_result[0:C-1][0:LIMIT];
  integer partial_tag[0:C-1][0:LIMIT],result_tag[0:C-1][0:LIMIT];
  integer cycle=0,compute_seq=0,backend_seq=0,partials=0,outputs=0;
  integer loaded_beats[0:R-1][0:1],last_activation_edge[0:R-1][0:1];
  integer load_seq=0,first_load_cycle=-1,overlap_edges=0,dequant_seq=0;
  always @(posedge clk) begin
    if(!rst_n) begin
      cycle=0;compute_seq=0;backend_seq=0;partials=0;outputs=0;
      load_seq=0;first_load_cycle=-1;overlap_edges=0;dequant_seq=0;
      for(integer r=0;r<R;r++) for(integer b=0;b<2;b++) begin loaded_beats[r][b]=0;last_activation_edge[r][b]=-1000;end
      for(integer c=0;c<C;c++) for(integer t=0;t<=LIMIT;t++) begin expected_partial[c][t]=0;expected_result[c][t]=0;end
    end else if(run) begin
      cycle=cycle+1;
      if(ll) begin
        if(first_load_cycle<0) first_load_cycle=cycle;
        if(cycle-first_load_cycle!=load_start(load_seq)) $fatal(1,"weight launch schedule mismatch");
        load_seq=load_seq+1;
      end
      if(cl) begin
        if(!clr) $fatal(1,"core compute launch not ready");
        if(cycle-first_load_cycle!=compute_start(compute_seq/BATCH)+compute_seq%BATCH)
          $fatal(1,"compute beat schedule mismatch");
        for(integer c=0;c<C;c++) begin
          expected_partial[c][cycle+21+c]=1;partial_tag[c][cycle+21+c]=compute_seq;
        end
        compute_seq=compute_seq+1;
      end
      if(bl) begin
        integer group_id,offset;
        if(!blr) $fatal(1,"core backend launch not ready");
        group_id=backend_seq<BATCH/2?0:(backend_seq<BATCH?1:backend_seq/BATCH+1);
        offset=backend_seq-(group_id==0?0:(group_id==1?BATCH/2:(group_id-1)*BATCH));
        if(cycle-first_load_cycle!=backend_start(group_id)+offset) $fatal(1,"backend beat schedule mismatch");
        if(backend_seq>=2*BATCH) for(integer c=0;c<C;c++) begin
          expected_result[c][cycle+6+c]=1;result_tag[c][cycle+6+c]=backend_seq;
        end
        backend_seq=backend_seq+1;
      end
      if(dl) begin
        if(!dlr || (de && !der)) $fatal(1,"dequant queue unavailable");
        dequant_seq=dequant_seq+1;
      end
      if(pl && !plr) $fatal(1,"parameter queue unavailable");
      if(ll && !llr) $fatal(1,"core load launch not ready");
      for(integer c=0;c<C;c++) begin
        bit expected_add;
        expected_add=returned_valid[c] && int'(returned_tag[c*16+:16])>=BATCH && int'(returned_tag[c*16+:16])<3*BATCH;
        if(alu_valid[c]!==expected_add) $fatal(1,"core operand capture delayed or missing column=%0d",c);
        if(alu_valid[c]) begin
          integer tag_value;
          tag_value=int'(returned_tag[c*16+:16]);
          if(operand_a[c*N*32+:N*32]!==returned_data[c*N*32+:N*32] || alu_tag[c*16+:16]!==returned_tag[c*16+:16] || alu_address[c*16+:16]!==16'(tag_value%BATCH))
            $fatal(1,"core new partial did not directly enter A1");
          for(integer g=0;g<N;g++) begin
            integer expected_old;
            expected_old=8*(4*((tag_value%BATCH)%3)+10)*(c*N+g+1)*(tag_value<2*BATCH?1:3);
            if(operand_b[(c*N+g)*32+:32]!==fp32_integer(expected_old)) $fatal(1,"core SRAM B not prefetched at A1 capture");
          end
        end
      end
      for(integer r=0;r<R;r++) begin
        if(cv[r]) begin
          integer b;
          b=int'(cp[r*CB]);
          // INT8 input may prefetch the retiring Buffer two cycles before
          // its first BF16 write. Read/write ownership is checked below at
          // every cell's actual M1/write interface, not at source acceptance.
          last_activation_edge[r][b]=cycle;
        end
        if(lv[r]) begin
          integer b;
          b=int'(lp[r*LB+1]);
          if(lx[r*16+:16]==0) loaded_beats[r][b]=0;
          loaded_beats[r][b]=loaded_beats[r][b]+1;
        end
        if(cv[r] && lv[r] && cp[r*CB]!=lp[r*LB+1]) overlap_edges=overlap_edges+1;
      end
      // Actual ports at every cell: independently scheduled weight and
      // activation windows, no hierarchy or DUT helper calls.
      if(first_load_cycle>=0 && SCENARIO!=2) for(integer r=0;r<R;r++) for(integer c=0;c<C;c++) begin
        bit expected_a,expected_w,expected_ab,expected_wb;
        integer relative_edge;
        expected_a=0;expected_w=0;expected_ab=0;expected_wb=0;
        relative_edge=cycle-first_load_cycle;
        for(integer s=0;s<4;s++) begin
          integer start_a;
          start_a=compute_start(s)+1+3*r+c;
          if(relative_edge>=start_a && relative_edge<start_a+BATCH) begin expected_a=1;expected_ab=1'(s%2);end
        end
        for(integer s=0;s<(REFILL?4:2);s++) begin
          integer start_w,end_w;
          start_w=load_start(s)+3+3*r+(s<2?c*(N+1):c);
          end_w=load_start(s)+34+3*r+c;
          if(relative_edge>=start_w && relative_edge<=end_w) begin expected_w=1;expected_wb=1'(s%2);end
        end
        if(cell_av[r*C+c]!==expected_a || (expected_a && cell_ab[r*C+c]!==expected_ab))
          $fatal(1,"cell activation gap/phase mismatch row=%0d cell=%0d edge=%0d",r,c,relative_edge);
        if(cell_wv[r*C+c]!==expected_w || (expected_w && cell_wb[r*C+c]!==expected_wb))
          $fatal(1,"cell weight link/buffer mismatch row=%0d cell=%0d edge=%0d",r,c,relative_edge);
        if(cell_av[r*C+c] && cell_wv[r*C+c] && cell_ab[r*C+c]==cell_wb[r*C+c])
          $fatal(1,"cell weight replacement overlaps old activation row=%0d cell=%0d",r,c);
      end
      #1;
      if(fault && (SCENARIO==2 || SCENARIO==3 || SCENARIO==6 || SCENARIO==9)) begin
        if(cycle-first_load_cycle!=(SCENARIO==2?34:(SCENARIO==3?121+R:(SCENARIO==9?backend_start(2)+1:56+R)))) $fatal(1,"fault at unexpected edge");
        if(frontend_fault!==(SCENARIO==2) || backend_fault!==(SCENARIO!=2)) $fatal(1,"unexpected fault source");
        $display("MXM_CORE_NEGATIVE_PASS scenario=%0d fault_edge=%0d frontend_fault=%0d backend_fault=%0d",SCENARIO,cycle-first_load_cycle,frontend_fault,backend_fault);
        // Let the public-port trace process record the faulting edge too.
        #2;
        $finish;
      end
      if(fault) $fatal(1,"core fault cycle=%0d",cycle);
      for(integer c=0;c<C;c++) begin
        if(pv[c]!==expected_partial[c][cycle] || rv[c]!==expected_result[c][cycle])
          $fatal(1,"core valid phase mismatch column=%0d cycle=%0d",c,cycle);
        if(returned_valid[c]!==expected_partial[c][cycle>=R?cycle-R:0])
          $fatal(1,"core return phase mismatch Superlane=%0d cycle=%0d",c,cycle);
        if(returned_valid[c]) begin
          integer tag_value;
          tag_value=partial_tag[c][cycle-R];
          if(returned_tag[c*16+:16]!==16'(tag_value)) $fatal(1,"core return tag mismatch");
          for(integer g=0;g<N;g++) begin
            integer expected;
            expected=8*(4*((tag_value%BATCH)%3)+10)*(c*N+g+1)*(REFILL?tag_value/BATCH+1:(tag_value/BATCH)%2+1);
            if(returned_data[(c*N+g)*32+:32]!==fp32_integer(expected)) $fatal(1,"core return data mismatch");
          end
        end
        if(pv[c]) begin
          integer tag_value;
          tag_value=partial_tag[c][cycle];
          if(pt[c*16+:16]!==16'(tag_value)) $fatal(1,"core partial tag mismatch");
          for(integer g=0;g<N;g++) begin
            integer expected;
            expected=8*(4*((tag_value%BATCH)%3)+10)*(c*N+g+1)*(REFILL?tag_value/BATCH+1:(tag_value/BATCH)%2+1);
            if(pd[(c*N+g)*32+:32]!==fp32_integer(expected)) $fatal(1,"core partial numerical mismatch");
            partials=partials+1;
          end
        end
        if(rv[c]) begin
          integer tag_value;
          bit expected_bf16;
          tag_value=result_tag[c][cycle];
          expected_bf16=(SCENARIO==4 && tag_value<3*BATCH) || (SCENARIO==5 && tag_value>=3*BATCH);
          if(result_bf16[c]!==expected_bf16) $fatal(1,"core output format mismatch");
          if(rt[c*16+:16]!==16'(tag_value) || ra[c*16+:16]!==16'(tag_value%BATCH))
            $fatal(1,"core result address/tag mismatch");
          for(integer g=0;g<N;g++) begin
            integer expected;
            logic [31:0] expected_bits;
            expected=8*(4*((tag_value%BATCH)%3)+10)*(c*N+g+1)*(tag_value<3*BATCH?(REFILL?6:4):(REFILL?4:2));
            expected_bits=expected_bf16?{16'b0,bf16_integer(expected)}:fp32_integer(expected);
            if(rd[(c*N+g)*32+:32]!==expected_bits) $fatal(1,"core output numerical mismatch");
            outputs=outputs+1;
          end
        end
      end
    end
  end
  initial begin
    repeat(3) @(negedge clk);rst_n=1;
    // Independently preload all five queues; no per-compute backend fields.
    for(integer s=0;s<5;s++) begin
      @(negedge clk);ce=s==0;ci=compute_word(0);le=s<(REFILL?4:2);
      li=LB'(s%2)<<1;
      be=s==0;bi=backend_word(0);
      pe=s<(REFILL?4:2);pi=~1'(s%2);de=s==0;di=1;
    end
    @(negedge clk);ce=0;le=0;be=0;pe=0;de=0;run=1;pl=1;
    for(integer t=0;t<(SCENARIO==8?4*BATCH+100:280);t++) begin
      @(negedge clk);
      ll=t==load_start(0) || t==load_start(1) || (REFILL && (t==load_start(2) || t==load_start(3)));
      cl=0;bl=0;ce=0;be=0;pl=0;dl=0;de=0;
      for(integer s=0;s<(REFILL?4:2);s++) begin
        if(s>0 && t==load_start(s)-1) pl=1;
        if(t>=load_start(s) && t<load_start(s)+32) dl=1;
      end
      if(dl && dequant_seq+1<(REFILL?4:2)*32) begin de=1;di=~1'((dequant_seq+1)/32);end
      for(integer s=0;s<4;s++) if(t>=compute_start(s) && t<compute_start(s)+BATCH) cl=1;
      for(integer s=0;s<5;s++) if(t>=backend_start(s) && t<backend_start(s)+(s==0?BATCH/2:(s==1?BATCH-BATCH/2:BATCH))) bl=1;
      if(cl && compute_seq+1<4*BATCH) begin ce=1;ci=compute_word((compute_seq+1)/BATCH);end
      if(bl && backend_seq+1<4*BATCH) begin be=1;bi=backend_word(backend_seq+1);end
    end
    @(negedge clk);ll=0;cl=0;bl=0;ce=0;be=0;pl=0;dl=0;de=0;
    if(SCENARIO==2 || SCENARIO==3 || SCENARIO==6 || SCENARIO==9) $fatal(1,"unsafe schedule did not fault");
    if(partials!=4*BATCH*C*N || outputs!=2*BATCH*C*N || compute_seq!=4*BATCH || backend_seq!=4*BATCH || load_seq!=(REFILL?4:2) || overlap_edges==0 || dequant_seq!=(REFILL?4:2)*32)
      $fatal(1,"core missing results partials=%0d outputs=%0d",partials,outputs);
    $display("MXM_CORE_PASS scenario=%0d batch_size=%0d compute_beats=%0d backend_beats=%0d partial_fp32=%0d output_elements=%0d dequant_write=3 output_latency=6 returned_to_output=4 top_to_output=%0d return_stages=%0d direct_A=1 count_free=1 overlap_edges=%0d",SCENARIO,BATCH,compute_seq,backend_seq,partials,outputs,R+4,R,overlap_edges);
    $finish;
  end
  initial begin #100000;$fatal(1,"core timeout");end
endmodule
