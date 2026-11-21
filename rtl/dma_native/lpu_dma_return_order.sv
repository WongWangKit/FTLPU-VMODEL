// Vector reads use physical IDs 1..7 (0 is reserved for instruction fetch).
// AXI preserves burst order within an ID only. A burst reserves consecutive
// positions in the bounded return ring; MEM always observes descriptor order.
module lpu_dma_return_order #(parameter W=256,RT=128,Q=384)(
 input logic clk_i,rst_ni,ar_fire,input logic [7:0] len,
 output logic [7:0] id,output logic admit,
 input logic [7:0] rid,input logic beat,input logic [W-1:0] data,input logic [1:0] resp,input logic last,
 output logic expected,last_expected,output logic valid,input logic pop,
 output logic [W-1:0] payload,output logic [1:0] error,output logic tail
);
 localparam PER=(Q+7)/8, DEP=PER<RT?PER:RT, P=RT<=1?1:$clog2(RT), IP=DEP<=1?1:$clog2(DEP);
 typedef logic [P-1:0] ptr_t;
 typedef struct packed {ptr_t start;logic [7:0] len;} record_t;
 record_t meta[7][DEP];
 logic [2:0] next_id;
 logic [IP-1:0] pushp[7],popp[7];logic [$clog2(DEP+1)-1:0] count[7];logic [7:0] index_q[7];
 logic [$clog2(RT+1)-1:0] used,live;
 ptr_t alloc,head,dest;
 logic [RT-1:0] arrived;
 logic [W+2:0] ram[RT];
 function automatic ptr_t plus_ptr(ptr_t p,integer delta);
   integer n;n=int'(p)+delta;return ptr_t'(n>=RT?n-RT:n);
 endfunction
 wire [2:0] ix=(rid>=1 && rid<=7)?3'(rid-1):0;
 assign id=8'(next_id)+1;
 assign admit=int'(count[next_id])<DEP && int'(used)+int'(len)+1<=RT && int'(live)<Q-1;
 assign expected=rid>=1 && rid<=7 && count[ix]!=0;
 assign last_expected=meta[ix][popp[ix]].len==index_q[ix];
 assign dest=plus_ptr(meta[ix][popp[ix]].start,int'(index_q[ix]));
 assign valid=arrived[head];assign {tail,error,payload}=ram[head];
 wire take=valid && pop;
 always_ff @(posedge clk_i)begin
   if(ar_fire)meta[next_id][pushp[next_id]]<={alloc,len};
   if(beat)ram[dest]<={last,resp,data};
 end
 always_ff @(posedge clk_i or negedge rst_ni)
 if(!rst_ni)begin
   next_id<=0;alloc<=0;head<=0;used<=0;live<=0;arrived<=0;
   for(int i=0;i<7;i++)begin count[i]<=0;pushp[i]<=0;popp[i]<=0;index_q[i]<=0;end
 end else begin
   used<=used+(ar_fire?int'(len)+1:0)-int'(take);
   live<=live+int'(ar_fire)-int'(beat&&last);
   if(ar_fire)begin alloc<=plus_ptr(alloc,int'(len)+1);next_id<=next_id==6?0:next_id+1'b1;end
   if(take)begin arrived[head]<=0;head<=plus_ptr(head,1);end
   if(beat)arrived[dest]<=1;
   for(int i=0;i<7;i++)begin
     count[i]<=count[i]+int'(ar_fire && next_id==i)-int'(beat && ix==i && last);
     if(ar_fire && next_id==i)pushp[i]<=pushp[i]==DEP-1?0:pushp[i]+1'b1;
     if(beat && ix==i)begin
       index_q[i]<=last?0:index_q[i]+1'b1;
       if(last)popp[i]<=popp[i]==DEP-1?0:popp[i]+1'b1;
     end
   end
 end
endmodule
