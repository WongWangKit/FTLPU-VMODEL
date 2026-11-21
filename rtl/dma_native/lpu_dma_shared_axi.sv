// Two logical readers, ONE physical AXI manager. ID 0 is a 32-byte loader
// packet (two physical beats on LPU16); IDs 1..7 carry vector bursts.
// The data writer uses AW/W/B independently of AR/R. No AXI clock gating.
module lpu_dma_shared_axi #(parameter W=256, PW=256, RT=128, Q=384)(
 input logic clk_i,rst_ni,
 input logic pv, input logic [63:0] pa,output logic pr,
 output logic prv,input logic prr,output logic [PW-1:0] pd,output logic [1:0] pe,
 input logic dv,input logic [63:0] da,input logic [7:0] dl,output logic dr,
 output logic drv,input logic drr,output logic [W-1:0] dd,output logic [1:0] de,output logic dlast,
 input logic data_r_expected,data_last_expected,data_b_expected,
 input logic d_awvalid,output logic d_awready,input logic [63:0] d_awaddr,input logic [7:0] d_awlen,
 input logic d_wvalid,output logic d_wready,input logic [W-1:0] d_wdata,input logic d_wlast,
 output logic d_bvalid,output logic [1:0] d_bresp,output logic isolated_o,
 output logic [63:0] m_axi_araddr_o,m_axi_awaddr_o,output logic [7:0] m_axi_arid_o,m_axi_awid_o,
 output logic [7:0] m_axi_arlen_o,m_axi_awlen_o,output logic [2:0] m_axi_arsize_o,m_axi_awsize_o,
 output logic [1:0] m_axi_arburst_o,m_axi_awburst_o,output logic m_axi_arvalid_o,m_axi_awvalid_o,
 input logic m_axi_arready_i,m_axi_awready_i,input logic [W-1:0] m_axi_rdata_i,
 input logic [7:0] m_axi_rid_i,m_axi_bid_i,input logic [1:0] m_axi_rresp_i,m_axi_bresp_i,
 input logic m_axi_rlast_i,m_axi_rvalid_i,m_axi_bvalid_i,output logic m_axi_rready_o,m_axi_bready_o,
 output logic [W-1:0] m_axi_wdata_o,output logic [W/8-1:0] m_axi_wstrb_o,
 output logic m_axi_wvalid_o,m_axi_wlast_o,input logic m_axi_wready_i
);
 localparam N=PW/W, IX=N<=1?1:$clog2(N);
 logic turn,locked,owner,sel,p_live,p_buf;
 logic [IX-1:0] ix;
 logic bad,good,eligible_p,credit,expected,exp_last,ordered;
 logic [7:0] data_id;logic hold_ar,hold_aw,hold_w;
 logic [2:0] wid;logic waddr_seen,wtail_seen;localparam PER=(Q+7)/8;
 logic [$clog2(PER+1)-1:0] write_count[7];
 wire wr_credit=write_count[wid]<PER;
 wire aw_fire=m_axi_awvalid_o && m_axi_awready_i;
 wire tail_fire=m_axi_wvalid_o && m_axi_wready_i && m_axi_wlast_o;
 wire write_accepted=(aw_fire || waddr_seen) && (tail_fire || wtail_seen);
 wire good_bid=m_axi_bid_i>=1 && m_axi_bid_i<=7 && write_count[3'(m_axi_bid_i-1)]!=0;
 initial if ((W!=128 && W!=256) || PW!=256) $fatal(1,"DMA profile width");
 assign eligible_p=pv && !p_live && !p_buf;
 assign sel=locked?owner:(dv && credit && (!eligible_p || turn));
 assign m_axi_araddr_o=sel?da:pa;
 assign m_axi_arlen_o=sel?dl:8'(N-1);
 assign m_axi_arid_o=sel?data_id:8'd0;
 assign m_axi_arvalid_o=isolated_o?hold_ar:(sel?(dv&&credit):eligible_p);
 assign pr=m_axi_arvalid_o && !sel && m_axi_arready_i && !isolated_o;
 assign dr=m_axi_arvalid_o && sel && m_axi_arready_i && !isolated_o;
 assign m_axi_arburst_o=1; assign m_axi_awburst_o=1;
 assign m_axi_arsize_o=$clog2(W/8);assign m_axi_awsize_o=$clog2(W/8);
 assign bad=(m_axi_rvalid_i && (m_axi_rid_i==0 ? (!p_live || m_axi_rlast_i!=(ix==N-1)) :
           (!expected || m_axi_rlast_i!=exp_last))) ||
           (m_axi_bvalid_i && (!good_bid || !data_b_expected));
 assign good=!isolated_o && !bad;
 // All published addresses already own response storage. READY is a function
 // of registered link state, never a combinational path from RID/RESP/VALID.
 // Accept a malformed wire beat into quarantine, not into an owner's FIFO.
 assign m_axi_rready_o=rst_ni && !isolated_o;
 assign drv=good && ordered;
 lpu_dma_return_order #(.W(W),.RT(RT),.Q(Q)) u_returns (
   .clk_i,.rst_ni,.ar_fire(dr),.len(dl),.id(data_id),.admit(credit),
   .rid(m_axi_rid_i),.beat(m_axi_rvalid_i && good && m_axi_rready_o && m_axi_rid_i!=0),
   .data(m_axi_rdata_i),.resp(m_axi_rresp_i),.last(m_axi_rlast_i),.expected,.last_expected(exp_last),
   .valid(ordered),.pop(drr && good),.payload(dd),.error(de),.tail(dlast));
`ifndef SYNTHESIS
 always @(posedge clk_i)if(rst_ni && drv && drr && (!data_r_expected || dlast!=data_last_expected))
   $fatal(1,"shared read retirement order");
`endif
 assign prv=p_buf && !isolated_o;
 assign m_axi_awvalid_o=isolated_o?hold_aw:d_awvalid && wr_credit; assign d_awready=m_axi_awready_i && wr_credit && !isolated_o;
 assign m_axi_awid_o=8'(wid)+1;assign m_axi_awaddr_o=d_awaddr;assign m_axi_awlen_o=d_awlen;
 assign m_axi_wvalid_o=isolated_o?hold_w:d_wvalid && wr_credit;assign d_wready=m_axi_wready_i && wr_credit && !isolated_o;
 assign m_axi_wdata_o=d_wdata;assign m_axi_wstrb_o='1;assign m_axi_wlast_o=d_wlast;
 assign m_axi_bready_o=rst_ni && !isolated_o;assign d_bvalid=m_axi_bvalid_i && m_axi_bready_o && good;assign d_bresp=m_axi_bresp_i;
 always_ff @(posedge clk_i or negedge rst_ni)begin
   if(!rst_ni)begin wid<=0;waddr_seen<=0;wtail_seen<=0;hold_ar<=0;hold_aw<=0;hold_w<=0;
     for(int i=0;i<7;i++)write_count[i]<=0;
   end else if(isolated_o)begin
     if(m_axi_awready_i)hold_aw<=0;if(m_axi_arready_i)hold_ar<=0;if(m_axi_wready_i)hold_w<=0;
   end else begin
     if(bad)begin hold_ar<=m_axi_arvalid_o&&!m_axi_arready_i;hold_aw<=m_axi_awvalid_o&&!m_axi_awready_i;
       hold_w<=m_axi_wvalid_o&&!m_axi_wready_i;end
     if(aw_fire)waddr_seen<=1;if(tail_fire)wtail_seen<=1;
     if(write_accepted)begin wid<=wid==6?0:wid+1'b1;waddr_seen<=0;wtail_seen<=0;end
     for(int i=0;i<7;i++)write_count[i]<=write_count[i]+int'(write_accepted && wid==i)-int'(d_bvalid && m_axi_bid_i==i+1);
   end
 end
 always_ff @(posedge clk_i or negedge rst_ni)
  if(!rst_ni)begin turn<=0;locked<=0;owner<=0;p_live<=0;p_buf<=0;ix<=0;isolated_o<=0;pe<=0;pd<=0;end
  else if(!isolated_o) begin
   if(bad) isolated_o<=1;
   if(m_axi_arvalid_o && !m_axi_arready_i)begin locked<=1;owner<=sel;end
   if(pr||dr)begin locked<=0;turn<=!sel;end
   if(pr)begin p_live<=1;ix<=0;pe<=0;end
   if(prv && prr)p_buf<=0;
   if(good && m_axi_rvalid_i && m_axi_rready_o && m_axi_rid_i==0)begin
     pd[ix*W+:W]<=m_axi_rdata_i;if(m_axi_rresp_i!=0)pe<=m_axi_rresp_i;
     if(m_axi_rlast_i)begin p_live<=0;p_buf<=1;end else ix<=ix+1'b1;
   end
  end
endmodule
