`timescale 1ns/1ps
// Unit boundary: ordered data client of the shared AXI manager -> native
// wave -> real SRF and SRAM. No lpu_top, fake commit, or ICU substitution
// on the positive path. Two explicit receiver-side fault injections below.
module data_window_tb #(parameter T=4,F=52);
 localparam V=8*T,W=8*V,Q=T==2?832:384,RT=128;
 bit clk=0,rst=0;always #5 clk=~clk;
 bit dv,store,ack,cancel;wire ready,busy,done,error;wire [31:0] rtag;
 logic [6:0] bank;logic [2:0] lane;logic [14:0] row;logic [63:0] addr;
 logic [31:0] count,stride,tag;
 wire req,mwr,mhem,ret,merr;wire [6:0] mb;wire [2:0] ml;wire [14:0] mr;wire [W-1:0] md,mq;
 wire av,ar,rv,rr,rl,awv,awr,wv,wr,wl,bv;wire [1:0] resp,br;
 wire [63:0] aa,wa;wire [7:0] al,wal;logic [W-1:0] rd;wire [W-1:0] wd;
 bit [63:0] tick,first,lim='1;bit window=1;wire allow,port_ready;
 wire granted=!mwr || allow;
 logic [14:0] rs;logic [4:0] fs;wire [4:0] ms;
 lpu_dma_data_channel #(.W(W),.Q(Q),.RT(RT),.ROWS(32),.BANKS(2*F),.EXPLICIT_MEM_LAYOUT(1)) data(
 .clk_i(clk),.rst_ni(rst),.enable_i(1'b1),.isolated_i(1'b0),.cancel_i(cancel),
 .desc_valid_i(dv),.desc_ready_o(ready),.store_i(store),.hem_i(1'b0),.bank_i(bank),.lane_i(lane),.row_i(row),
 .addr_i(addr),.count_i(count),.stride_i(stride),.tag_i(tag),.row_stride_i(rs),.fabric_stream_i(fs),.mem_stream(ms),
 .busy_o(busy),.result_valid_o(done),
 .result_error_o(error),.result_ready_i(ack),.result_tag_o(rtag),
 .mem_req(req),.mem_ready(port_ready&&granted),.mem_write(mwr),.mem_hem(mhem),.mem_bank(mb),.mem_lane(ml),.mem_row(mr),.mem_data(md),
 .mem_ret(ret),.mem_err(merr),.mem_q(mq),.arvalid(av),.arready(ar),.araddr(aa),.arlen(al),
 .rvalid(rv),.rready(rr),.rdata(rd),.rresp(resp),.rlast(rl),
 .awvalid(awv),.awready(awr),.awaddr(wa),.awlen(wal),.wvalid(wv),.wready(wr),.wdata(wd),.wlast(wl),.bvalid(bv),.bresp(br));
 bit [63:0] epoch=3;bit reserved_hem;bit [2:0] reserved_lane;bit [4:0] reserved_stream;logic [2*F-1:0] mask;
 lpu_dma_weight_window #(.T(T),.F(F)) calendar(.valid_i(window),.cancel_i(cancel),.cycle_i(tick),.first_i(first),.limit_i(lim),
 .epoch_i(64'd3),.desc_epoch_i(epoch),.hem_i(mhem),.reserved_hem_i(reserved_hem),.bank_i(mb),.reserved_banks_i(mask),
 .lane_i(ml),.reserved_lane_i(reserved_lane),.stream_i(ms),.reserved_stream_i(reserved_stream),.grant_o(allow));
 wire [2*F-1:0] cmdv,bfault;wire [31:0] cmd;wire [2*F*T-1:0] commits;
 wire [T*32-1:0] west;wire [T*32*64-1:0] westd;wire [2*T*32-1:0] edges;wire [2*T*32*64-1:0] edge_data;
 wire [2*16*T-1:0] collision;wire [2*F*T-1:0] bank_collision;
 bit substitute_bank,duplicate_store,early_store,drop_store;logic [T*32-1:0] east;
 always_comb begin
   east=edges[T*32-1:0];
   if(duplicate_store && wave.expected_tile[1])east[ms]=1;
   if(early_store && wave.live && !wave.issued)
     for(int j=0;j<T;j++)east[j*32+ms]=1;
   if(drop_store && wave.expected_tile[T-1])east[(T-1)*32+ms]=0;
 end
 lpu_dma_mem_wave #(.T(T),.F(F)) wave(.clk_i(clk),.rst_ni(rst),.req(req&&granted),.write_i(mwr),.bank_i(mb),
 .stream_i(ms),.row_i(mr),.vector_i(md),.ready(port_ready),.ret,.err(merr),.vector_o(mq),.cmd_valid(cmdv),.cmd,
 .normal_write_committed(commits),.east_valid(east),.east_data(edge_data[T*32*64-1:0]),
 .west_valid(west),.west_data(westd),.native_fault(|bfault),.collision((|collision)||(|bank_collision)));
 // Replace the destination command with a legal write in its sibling bank.
 // This still produces the SAME boundary consume signal, but not the same commit.
 wire [2*F-1:0] physical_valid=substitute_bank ? (cmdv<<1) : cmdv;
 lpu_mem_srf_integration #(.MEM_SLICES(F),.MEM_DEPTH_ROWS(32),.SUPERLANES(T)) mem(
 .clk_i(clk),.rst_ni(rst),.bank_issue_valid_i(physical_valid),.bank_issue_i({(2*F){cmd}}),
 .boundary_valid_i({west,{(T*32){1'b0}}}),.boundary_data_i({westd,{(T*32*64){1'b0}}}),
 .boundary_valid_o(edges),.boundary_data_o(edge_data),.normal_write_committed_o(commits),
 .srf_collision_o(collision),.mem_internal_collision_o(bank_collision),.mem_bank_fault_valid_o(bfault));

 // Ordered client memory with separately stalled address, payload and response.
 byte unsigned ddr[65536];int ra,rleft=0,read_num=0,awq[$],lenq[$],writing=0,where_w,bs=0;
 typedef struct packed {logic last;logic [W-1:0] val;} beat_t;beat_t beats[$],beat;
 bit bad_r,bad_b;int saw_bad,mem_fires,retired,wrong_commits,checked_tail,ars,aws,bdone;
 int tracefd;
 initial begin tracefd=$fopen("edges.csv","w");if(!tracefd)$fatal(1,"open edges.csv");
   $fdisplay(tracefd,"edge,event,tag,bank,stream,index_or_address,value");end
 task automatic event_row(input logic [8*24-1:0] kind,input logic [63:0] index,value);
   $fdisplay(tracefd,"%0d,%0s,%0d,%0d,%0d,%0d,%0d",tick,kind,tag,mb,ms,index,value);
 endtask
 assign ar=rst && rleft==0 && tick%5!=1;assign rv=rleft!=0;assign rl=rleft==1;
 assign resp=(bad_r && read_num==1)?2:0;
 always_comb for(int b=0;b<V;b++)rd[8*b+:8]=ddr[(ra+b)%65536];
 assign awr=rst && tick%7>=3;assign wr=rst && tick%5>=2;
 assign bv=bs!=0 && tick%5==0;assign br=bad_b?2:0;
 bit [63:0] launched,deadline;int dstbank;bit timed;
 always @(posedge clk)if(rst)begin
   tick<=tick+1;
   if(tick>45000)$fatal(1,"timeout tag=%d row=%d",tag,mr);
   if(dv&&ready)event_row("desc",addr,count);
   if(av&&ar)event_row("AR",aa,int'(al)+1);
   if(rv&&rr)event_row("R",ra,{resp,rl});
   if(awv&&awr)event_row("AW",wa,int'(wal)+1);
   if(wv&&wr)event_row("W",0,wl);
   if(bv)event_row("B",0,br);
   if(done&&ack)event_row("result_accept",rtag,error);
   if(req&&port_ready&&granted)begin
     if(mwr)event_row("RX_launch",mr,ml);else event_row("MEM_read",mr,ml);
   end
   if(|cmdv)event_row("MEM_command",wave.row,cmd);
   if(wave.live && !wave.write_q && |wave.expected_tile)event_row("TX_gather",wave.expected_tile,wave.hits);
   if(ret)event_row("native_retire",wave.row,merr);
   if(av&&ar)begin
     if(aa[11:0]+(int'(al)+1)*V>4096)$fatal(1,"AR crosses 4 KiB");
     ra<=int'(aa);rleft<=int'(al)+1;read_num<=0;ars++;
   end
   if(rv&&rr)begin read_num<=read_num+1;ra<=ra+V;rleft<=rleft-1;end
   if((rv&&rr&&resp!=0)||(bv&&br!=0))begin saw_bad++;if(req)$fatal(1,"new native request on failed response");end
   if(awv&&awr)begin
     if(wa[11:0]+(int'(wal)+1)*V>4096)$fatal(1,"AW crosses 4 KiB");
     awq.push_back(int'(wa));lenq.push_back(int'(wal)+1);aws++;
   end
   if(wv&&wr)begin beat.val=wd;beat.last=wl;beats.push_back(beat);end
   if(bv)begin bs--;bdone++;end
   if(!writing && awq.size())begin writing=lenq.pop_front();where_w=awq.pop_front();end
   if(writing && beats.size())begin beat=beats.pop_front();if(beat.last!=(writing==1))$fatal(1,"WLAST");
     for(int b=0;b<V;b++)ddr[where_w+b]=beat.val[8*b+:8];where_w+=V;writing--;if(!writing)bs++;
   end
   if(req&&port_ready&&granted)begin
     mem_fires++;
     if(mwr)begin launched=tick;dstbank=mb;deadline=tick+15+T-int'(mb)/8;timed=1;end
   end
   if(timed && |commits)begin
     for(int k=0;k<T;k++)
       if(commits[(dstbank+int'(substitute_bank))*T+k])begin
         event_row("registered_leaf_write",k,dstbank+int'(substitute_bank));
         if(tick!=deadline+1-(T-1-k))$fatal(1,"write edge got=%d last=%d tile=%d",tick,deadline,k);
         if(substitute_bank)wrong_commits++;else if(k==T-1)checked_tail++;
       end
   end
   if(ret)begin retired++;timed=0;end
 end
 task automatic start(bit st,int b,int l,int row0,int a,int n,int s,int step=1,int sid=-1);
   @(negedge clk);store=st;bank=b;lane=l;row=row0;addr=a;count=n;stride=s;tag++;dv=1;
   rs=step;fs=sid<0?(st?l:24+l):sid;reserved_stream=fs;reserved_lane=l;mask='0;mask[b]=1;
   do @(posedge clk);while(!ready);@(negedge clk);dv=0;
   rs='0;fs='1; // descriptor inputs may immediately change after fire
 endtask
 task automatic finish_x(bit failed);
   while(!done)@(negedge clk);
   repeat(3)begin if(!done||busy||error!==failed||rtag!=tag)$fatal(1,"result tag=%d error=%b want=%b",tag,error,failed);
     @(negedge clk);end
   ack=1;@(negedge clk);ack=0;
 endtask
 task automatic compare_bytes(int a,int n,int s);
   for(int i=0;i<n;i++)for(int b=0;b<V;b++)if(ddr['hc000+i*V+b]!==ddr[a+i*s+b])
     $fatal(1,"data mismatch tag=%d row=%d byte=%d",tag,i,b);
 endtask
 initial begin
   string ds,hexfile;int fd,hh,b,l,r,a,n,s,slot,page,last,old,ar0,good0,base,span;
   tag=0;for(int i=0;i<65536;i++)ddr[i]=8'(i*37+i/17);
   if(!$value$plusargs("DESC=%s",ds)||!$value$plusargs("HEX=%s",hexfile))$fatal(1,"missing CModel files");
   $readmemh(hexfile,ddr,4096,4096+24*3*T*V-1);
   repeat(4)@(negedge clk);rst=1;
   fd=$fopen(ds,"r");if(!fd)$fatal(1,"open descriptors");
   for(int i=0;i<24;i++)begin
     if($fscanf(fd,"%d %d %d %d %d %d %d %d %d %d",hh,b,l,r,a,n,s,slot,page,last)!=10 || hh!=0)$fatal(1,"descriptor");
     start(0,b,l,r,a,n,s);finish_x(0);start(1,b,l,r,'hc000,n,V);finish_x(0);compare_bytes(a,n,s);
   end
   $fclose(fd);
   // Nearest/farthest bank and all eight lanes. Revoke the window after
   // launch: it is an admission contract, never a clock enable.
   for(int i=0;i<8;i++)begin
     b=i%2?0:2*F-1;span=15+T-b/8;window=0;old=mem_fires;good0=checked_tail;
     start(0,b,i,31,'h8800,1,V);while(!req)@(negedge clk);
     window=1;first=tick+1;lim='1;#1;if(allow)$fatal(1,"early");
     first=0;epoch=2;#1;if(allow)$fatal(1,"stale epoch");epoch=3;
     reserved_hem=1;#1;if(allow)$fatal(1,"hem");reserved_hem=0;
     reserved_lane=i^1;#1;if(allow)$fatal(1,"lane");reserved_lane=i;
     mask='0;#1;if(allow)$fatal(1,"bank");
     @(negedge clk);mask[b]=1;lim=tick+span;#1;if(allow)$fatal(1,"one edge short");
     @(negedge clk);if(mem_fires!=old)$fatal(1,"unreserved launch");
     lim=tick+span+1;#1;if(!allow)$fatal(1,"exact window rejected");
     @(negedge clk);window=0;finish_x(0);
     if(mem_fires!=old+1||checked_tail!=good0+1)$fatal(1,"missing tail");
     start(1,b,i,31,'hc000,1,V);finish_x(0);compare_bytes('h8800,1,V);window=1;lim='1;
   end
   ar0=ars;start(0,2,2,4,4096-V,3,V);finish_x(0);if(ars!=ar0+2)$fatal(1,"4k split");
   start(1,2,2,4,'hc000,3,V);finish_x(0);compare_bytes(4096-V,3,V);
   start(0,1,3,2,'h9000,4,2*V);finish_x(0);start(1,1,3,2,'hc000,4,V);finish_x(0);compare_bytes('h9000,4,2*V);
   // Independent byte and SRAM-row strides, and stream != lane mapping.
   // Ordinary adjacent-row STORE makes a symmetric wrong-address bug visible.
   window=0;old=mem_fires;start(0,78,3,4,'h9400,3,2*V,4,5);
   while(!req)@(negedge clk);reserved_stream=27;window=1;repeat(3)@(negedge clk);
   if(mem_fires!=old)$fatal(1,"wrong stream reservation");
   reserved_stream=5;finish_x(0);start(1,78,6,4,'hc000,9,V,1,13);finish_x(0);
   for(int i=0;i<9;i++)for(int j=0;j<V;j++)
     if(ddr['hc000+i*V+j] !== (i%4==0 ? ddr['h9400+(i/4)*2*V+j] : 8'b0))
        $fatal(1,"row stride or guard mismatch row=%0d",i+4);
   ar0=ars;start(0,78,3,30,'h9400,2,V,2,5);finish_x(1);
   start(0,78,3,0,'h9400,2,V,0,5);finish_x(1);
   if(ars!=ar0)$fatal(1,"illegal destination allocated DDR traffic");
   substitute_bank=1;start(0,2,1,0,'h8400,1,V);finish_x(1);substitute_bank=0;
   if(wrong_commits!=T)$fatal(1,"wrong bank injection never reached real SRAM");
   old=mem_fires;bad_r=1;start(0,2,2,0,'h8800,4,V);finish_x(1);bad_r=0;
   if(mem_fires!=old || saw_bad!=1 || rleft)$fatal(1,"failed R replayed or not drained");
   window=0;old=mem_fires;start(0,2,2,0,'h8800,12,V);
   while(!read_num || !rleft)@(negedge clk);
   cancel=1;@(negedge clk);cancel=0;finish_x(1);window=1;
   if(mem_fires!=old || rleft)$fatal(1,"cancel leaked admitted burst");
   duplicate_store=1;start(1,2,2,0,'hc000,1,V);finish_x(1);duplicate_store=0;
   drop_store=1;start(1,2,2,0,'hc000,1,V);finish_x(1);drop_store=0;
   early_store=1;start(1,78,6,4,'hc000,1,V,1,13);finish_x(0);early_store=0;compare_bytes('h9400,1,2*V);
   bad_b=1;start(1,2,2,0,'hc000,5,V);finish_x(1);bad_b=0;
   start(0,2,2,0,'h8800,2,V);finish_x(0);start(1,2,2,0,'hc000,2,V);finish_x(0);compare_bytes('h8800,2,V);
   if(aws!=bdone || mem_fires!=retired || saw_bad<2)$fatal(1,"undrained obligations");
   $fclose(tracefd);
   $display("PASS T=%0d 24 CModel segments + 8 exact windows; native req/ret=%0d/%0d wrong-bank leaves=%0d AW/B=%0d/%0d",
      T,mem_fires,retired,wrong_commits,aws,bdone);$finish;
 end
endmodule
