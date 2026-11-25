// One scheduled data descriptor; consecutive rows, byte-strided external
// vectors. Read bursts reserve ALL their vector slots before AR is published.
// The native MEM port completes one (non-stallable once begun) wave at a time.
module lpu_dma_data_channel #(parameter W=256, RT=128, Q=384, ROWS=2048, BANKS=104,
 parameter bit EXPLICIT_MEM_LAYOUT=0)(
 input logic clk_i,rst_ni,enable_i,isolated_i,cancel_i,
 input logic desc_valid_i,output logic desc_ready_o,input logic store_i,hem_i,
 input logic [6:0] bank_i,input logic [2:0] lane_i,input logic [14:0] row_i,
 input logic [63:0] addr_i,input logic [31:0] count_i,stride_i,input logic [31:0] tag_i,
 output logic busy_o,result_valid_o,result_error_o, input logic result_ready_i,output logic [31:0] result_tag_o,
 output logic mem_req, input logic mem_ready,output logic mem_write,mem_hem, output logic [6:0] mem_bank,
 output logic [2:0] mem_lane,output logic [14:0] mem_row,output logic [W-1:0] mem_data,
 input logic mem_ret,mem_err,input logic [W-1:0] mem_q,
 output logic arvalid,input logic arready,output logic [63:0] araddr,output logic [7:0] arlen,
 input logic rvalid,output logic rready,input logic [W-1:0] rdata,input logic [1:0] rresp,input logic rlast,
 output logic r_expected,last_expected,b_expected,
 output logic awvalid,input logic awready,output logic [63:0] awaddr,output logic [7:0] awlen,
 output logic wvalid,input logic wready,output logic [W-1:0] wdata,output logic wlast,
 input logic bvalid,input logic [1:0] bresp,
 // Set EXPLICIT_MEM_LAYOUT on the standalone descriptor endpoint. Existing
 // fixed-layout instantiations do not consume these pins or infer a span multiplier.
 input logic [14:0] row_stride_i,input logic [4:0] fabric_stream_i,output logic [4:0] mem_stream,
 input tri0 indexed_i,input logic [63:0] index_addr_i,input logic [31:0] row_limit_i
);
 localparam BYTES=W/8, ID_CAP=(Q-1<RT)?Q-1:RT;
 logic active,stop,store,waiting,wr,aw_sent,w_sent;
 logic [31:0] left,rows_left,stride; logic [63:0] addr;
 logic [14:0] row;logic [7:0] chunk,w_index,r_index;
 logic [31:0] rx_promised,b_due;
 logic [64:0] last_byte;
 assign last_byte={1'b0,addr_i}+65'(count_i-1'b1)*65'(stride_i)+65'(BYTES-1);
 wire [14:0] row_step=EXPLICIT_MEM_LAYOUT ? row_stride_i : 15'd1;
 logic [14:0] row_step_q;
 // count<=ROWS<=32768 is checked separately. No narrow multiply/add may
 // wrap a bad last row back into SRAM. DDR stride is independently in bytes.
 wire [30:0] last_row=31'(row_i)+31'(15'(count_i-1'b1))*31'(row_step);
 logic index_phase,index_sent;
 logic [63:0] index_addr;
 logic [31:0] row_limit;
 wire [64:0] indexed_end=last_byte+((65'(row_limit_i)-1)<<9);
 wire index_legal=!indexed_i || (!store_i && index_addr_i[1:0]==0 && index_addr_i[63:42]==0 &&
    row_limit_i!=0 && !row_limit_i[31] && stride_i==BYTES && count_i<=512/BYTES && !indexed_end[64]);
 wire legal=index_legal && count_i!=0 && bank_i<BANKS && count_i<=ROWS && row_step!=0 && last_row<ROWS &&
   addr_i%BYTES==0 && (count_i==1 || (stride_i!=0 && stride_i%BYTES==0)) && !last_byte[64];
 assign desc_ready_o=rst_ni && enable_i && !isolated_i && !cancel_i && !active && !result_valid_o;
 assign busy_o=active;
 wire arfire=arvalid&&arready,rfire=rvalid&&rready,awfire=awvalid&&awready,wfire=wvalid&&wready;
 wire wr_fire=wr && (aw_sent||awfire) && (w_sent||(wfire&&wlast));
 wire [31:0] index_word=rdata[8*index_addr[$clog2(BYTES)-1:0]+:32];
 wire fault=cancel_i || (rfire && (rresp!=0 || (index_phase && index_word>=row_limit)))||(bvalid && bresp!=0)||(mem_ret && mem_err);
 logic rxv,rxr,txv,txr,lenv,lenr;
 logic [W-1:0] rx_data;logic [7:0] expected_len;
 logic [$clog2(RT+1)-1:0] tx_level;
 logic [$clog2(ID_CAP+1)-1:0] len_level;
 wire local_reset_n=rst_ni && active;
 // FIFO pointers clear between descriptors; memory contents need not reset.
 lpu_queue_fifo #(.DEPTH(RT),.DATA_WIDTH(W)) rx(.clk_i,.rst_ni(local_reset_n),
   .enqueue_valid_i(rfire && !index_phase && !stop && !fault),.enqueue_data_i(rdata),.enqueue_ready_o(rxr),
   .dequeue_valid_o(rxv),.dequeue_ready_i(mem_req&&mem_ready&&!store),.dequeue_data_o(rx_data),.level_o());
 lpu_queue_fifo #(.DEPTH(RT),.DATA_WIDTH(W)) tx(.clk_i,.rst_ni(local_reset_n),
   .enqueue_valid_i(mem_ret && store && !stop && !fault),.enqueue_data_i(mem_q),.enqueue_ready_o(txr),
   .dequeue_valid_o(txv),.dequeue_ready_i(wfire),.dequeue_data_o(wdata),.level_o(tx_level));
 lpu_queue_fifo #(.DEPTH(ID_CAP),.DATA_WIDTH(8)) lengths(.clk_i,.rst_ni(local_reset_n),
   .enqueue_valid_i(arfire),.enqueue_ready_o(lenr),.enqueue_data_i(arlen),
   .dequeue_valid_o(lenv),.dequeue_ready_i(rfire && rlast),.dequeue_data_o(expected_len),.level_o(len_level));
 assign r_expected=lenv;assign last_expected=r_index==expected_len;
 // An attributable failed beat needs no payload slot. Accept it even when
 // RX cannot pop, then drain subsequent accepted bursts without replay.
 assign rready=lenv && (stop || rxr || (rvalid && rresp!=0));
 assign b_expected=b_due!=0;
 assign mem_req=active && !isolated_i && !cancel_i && !stop && !waiting &&
   !(rvalid && rresp!=0) && !(bvalid && bresp!=0) &&
   rows_left!=0 && (store?tx_level<RT:rxv);
 assign mem_write=!store;assign mem_data=rx_data;assign mem_row=row;
 wire mem_fire=mem_req && mem_ready;
 assign awvalid=wr && !aw_sent;assign wvalid=wr && !w_sent && txv;
 assign wlast=w_index==awlen;
 integer n,limit_beats;
 always_comb begin
   n=left>16?16:int'(left);
   limit_beats=(4096-int'(addr[11:0]))/BYTES;
   if(n>limit_beats)n=limit_beats;
   if(stride!=BYTES && n>1)n=1;
   if(store)begin if(n>int'(tx_level))n=int'(tx_level);end
   else if(n>RT-int'(rx_promised))n=RT-int'(rx_promised);
 end
 initial if(RT<1 || Q<2 || BANKS>128 || ROWS>32768) $fatal(1,"data channel geometry");
 always_ff @(posedge clk_i or negedge rst_ni)
 if(!rst_ni)begin active<=0;stop<=0;result_valid_o<=0;result_error_o<=0;result_tag_o<=0;
    store<=0;mem_hem<=0;mem_bank<=0;mem_lane<=0;row<=0;addr<=0;left<=0;rows_left<=0;stride<=0;
    index_phase<=0;index_sent<=0;index_addr<=0;row_limit<=0;
    waiting<=0;wr<=0;aw_sent<=0;w_sent<=0;arvalid<=0;araddr<=0;arlen<=0;
    awaddr<=0;awlen<=0;chunk<=0;w_index<=0;r_index<=0;rx_promised<=0;b_due<=0;row_step_q<=0;mem_stream<=0;end
 else if(!isolated_i) begin
   if(result_valid_o&&result_ready_i)result_valid_o<=0;
   if(desc_valid_i&&desc_ready_o)begin
     active<=legal;stop<=0;result_error_o<=!legal;result_valid_o<=!legal;result_tag_o<=tag_i;
     index_phase<=indexed_i;index_sent<=0;index_addr<=index_addr_i;row_limit<=row_limit_i;
     row<=row_i;mem_hem<=hem_i;mem_bank<=bank_i;mem_lane<=lane_i;
     store<=store_i;rows_left<=count_i;left<=count_i;addr<=addr_i;stride<=stride_i;
     row_step_q<=row_step;mem_stream<=EXPLICIT_MEM_LAYOUT ? fabric_stream_i :
       (store_i ? 5'(lane_i) : 5'd24+lane_i);
     rx_promised<=0;b_due<=0;waiting<=0;r_index<=0;
   end else if(active)begin
     if(fault)stop<=1;
     if(mem_fire)begin waiting<=1;rows_left<=rows_left-1;row<=row+row_step_q;end
     if(mem_ret)waiting<=0;
     if(index_phase && !index_sent && !arvalid && !stop && !fault)begin
       arvalid<=1;araddr<=index_addr & ~64'(BYTES-1);arlen<=0;end
     if(index_phase && rfire)begin
       index_phase<=0;
       if(!stop && !fault)addr<=addr+(64'(index_word)<<9);
     end
     if(!store && !index_phase && !arvalid && !stop && !fault && n>0 && len_level<ID_CAP)begin
       arvalid<=1;araddr<=addr;arlen<=8'(n-1);end
     if(arfire)begin arvalid<=0;if(index_phase)index_sent<=1;
       else begin left<=left-(32'(arlen)+1);addr<=addr+(64'(arlen)+1)*64'(stride);end end
     rx_promised<=rx_promised+((arfire&&!index_phase)?32'(arlen)+1:0)-((mem_fire&&!store)?1:0);
     if(rfire)r_index<=rlast?0:r_index+1'b1;
     if(store && !wr && !stop && !fault && n>0 && b_due<ID_CAP)begin
       wr<=1;awaddr<=addr;awlen<=8'(n-1);aw_sent<=0;w_sent<=0;w_index<=0;
       left<=left-32'(n);addr<=addr+64'(n)*64'(stride);
     end
     if(awfire)aw_sent<=1;
     if(wfire)begin w_index<=w_index+1'b1;if(wlast)w_sent<=1;end
     if(wr_fire)wr<=0;
     b_due<=b_due+32'(wr_fire)-32'(bvalid);
     if(!waiting && !mem_fire && !arvalid && !lenv && !wr && !b_due &&
        (stop || (left==0 && rows_left==0 && !rxv && !txv)))begin
       active<=0;result_valid_o<=1;result_error_o<=stop || fault;
     end
   end
 end
endmodule
