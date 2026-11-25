// Runtime installs one immutable upstream-format u32 table (2 words/entry,
// 8 words/segment). A task grants banks/streams for ONE physical interval.
// No DDR pointer chasing here: table RAM is local; only payloads use AXI.
module lpu_dma_expert_loader #(parameter F=52, V=32, ROWS=8192)(
 input logic clk_i,rst_ni,clear_i,word_valid_i,input logic [31:0] word_i,
 input logic [10:0] experts_i,input logic [8:0] segments_i,output logic config_ready_o,
 input logic task_valid_i,output logic task_ready_o,input logic [9:0] expert_i,
 input logic xor_i,input logic [543:0] template_i,input logic [4*F-1:0] banks_i,
 input logic [31:0] streams_i,input logic available_i,config_safe_i,cancel_i,
 input logic [1:0] resident_i,leased_i,input logic [63:0] generation_i,image_i,cycle_i,
 output logic busy_o,valid_o,output logic [543:0] command_o,output logic [4*F-1:0] mask_o,
 input logic accepted_i,rejected_i,result_i,error_i,
 output logic failed_partial_o,done_o,error_o,input logic done_ready_i
);
 typedef enum logic [3:0]{IDLE,ENTRY0,ENTRY1,READSEG,CHECKSEG,COMPARE,ISSUE,WAITRES,PUBLISHED} state_t;
 state_t state;
 logic [31:0] tab[4096];logic [12:0] used;logic [10:0] experts;logic [8:0] segments;
 logic [11:0] ptr;logic [31:0] first_seg,raw[8];logic [2:0] field;
 logic [8:0] nseg,k,j;logic scan,swap,began,killed;
 logic [543:0] base;logic [31:0] streams;logic [9:0] expert;
 logic [9:0] cache_id[2];logic [63:0] cache_gen[2],cache_page[2];logic [1:0] cache_valid,cache_swap;
 logic [22:0] prior_start[256];logic [15:0] prior_end[256];
 wire [6:0] bank={raw[4][5:0],raw[5][0]^swap};
 wire [7:0] loc={raw[3][0],bank};
 wire [32:0] endrow={1'b0,raw[6]}+raw[2];
 wire [64:0] endaddr={1'b0,raw[1],raw[0]}+65'(raw[2])*V;
 wire good=raw[0]%V==0 && !endaddr[64] && raw[2]!=0 && raw[2]<=65536 &&
   raw[3]<2 && raw[4]<F && raw[5]<2 && endrow<=ROWS && raw[7]<32 &&
   mask_o[(raw[3][0]?2*F:0)+bank] && streams[raw[7][4:0]];
 wire overlap=prior_start[j[7:0]][22:15]==loc && prior_start[j[7:0]][14:0]<endrow &&
              raw[6]<prior_end[j[7:0]];
 wire s=template_i[432];
 wire hit=resident_i[s] && cache_valid[s] && cache_id[s]==expert_i &&
   cache_gen[s]==template_i[63:0] && cache_page[s]==template_i[127:64] && cache_swap[s]==xor_i;
 assign busy_o=state!=IDLE;
 assign config_ready_o=!busy_o && !done_o && config_safe_i && leased_i==0 && !task_valid_i && (clear_i || used<4096);
 assign task_ready_o=!busy_o && !done_o && available_i && !cancel_i && !clear_i && !word_valid_i;
 assign valid_o=state==ISSUE && !cancel_i;
 always_comb begin
   command_o=base;command_o[319:256]={raw[1],raw[0]};command_o[351:320]=raw[2];command_o[383:352]=V;
   command_o[398:384]=raw[6][14:0];command_o[399]=0;command_o[415:400]=16'd1;
   command_o[422:416]=bank;command_o[423]=raw[3][0];command_o[431:427]=raw[7][4:0];
   command_o[433]=k==0;command_o[434]=k+1==nseg;
 end
 task automatic finish(input logic bad);
   begin state<=IDLE;done_o<=1;error_o<=bad;failed_partial_o<=bad && began;end
 endtask
 always_ff @(posedge clk_i or negedge rst_ni)
 if(!rst_ni)begin state<=IDLE;used<=0;experts<=0;segments<=0;done_o<=0;error_o<=0;
   cache_valid<=0;failed_partial_o<=0;began<=0;killed<=0;end
 else begin
   failed_partial_o<=0;
   if(done_ready_i)done_o<=0;
   if(config_ready_o && clear_i)begin used<=0;experts<=experts_i;segments<=segments_i;cache_valid<=0;end
   else if(config_ready_o && word_valid_i && used<4096)begin tab[used[11:0]]<=word_i;used<=used+1'b1;end
   for(int i=0;i<2;i++)if(!leased_i[i])cache_valid[i]<=0;
   if(cancel_i && busy_o && state!=WAITRES)finish(1);
   else case(state)
   IDLE:if(task_valid_i && task_ready_o)begin
     began<=0;killed<=0;error_o<=0;expert<=expert_i;swap<=xor_i;base<=template_i;
     streams<=streams_i;mask_o<=banks_i;ptr<=12'(2*expert_i);
     if(experts==0 || experts>1024 || segments==0 || segments>256 ||
        used!=2*experts+8*segments || expert_i>=experts || template_i[63:0]!=generation_i ||
        template_i[543:480]!=image_i || generation_i==0 || template_i[127:64]==0)begin done_o<=1;error_o<=1;end
     else if(hit)done_o<=1;
     else if(leased_i[s])begin done_o<=1;error_o<=1;end
     else state<=ENTRY0;
   end
   ENTRY0:begin first_seg<=tab[ptr];ptr<=ptr+1'b1;state<=ENTRY1;end
   ENTRY1:if(tab[ptr]==0 || {1'b0,first_seg}+{1'b0,tab[ptr]}>segments)finish(1);
     else begin nseg<=tab[ptr][8:0];ptr<=12'(2*experts+8*first_seg);field<=0;k<=0;scan<=1;state<=READSEG;end
   READSEG:begin raw[field]<=tab[ptr];ptr<=ptr+1'b1;field<=field+1'b1;if(field==7)state<=CHECKSEG;end
   CHECKSEG:if(!good)finish(1);
     else if(!scan)state<=ISSUE;
     else begin j<=0;state<=COMPARE;end
   COMPARE:if(j<k)begin if(overlap)finish(1);else j<=j+1'b1;end
     else begin prior_start[k[7:0]]<={loc,raw[6][14:0]};prior_end[k[7:0]]<=endrow[15:0];state<=READSEG;
       if(k+1==nseg)begin k<=0;ptr<=12'(2*experts+8*first_seg);scan<=0;end else k<=k+1'b1;end
   ISSUE:if(rejected_i || cycle_i>=base[255:192])finish(1);
     else if(accepted_i)begin began<=1;state<=WAITRES;end
   WAITRES:begin if(cancel_i)killed<=1;
     if(result_i)begin if(error_i || killed || cancel_i)finish(1);
       else if(k+1==nseg)state<=PUBLISHED;
       else begin k<=k+1'b1;state<=READSEG;end end end
   PUBLISHED:if(resident_i[base[432]])begin
     cache_valid[base[432]]<=1;cache_id[base[432]]<=expert;cache_swap[base[432]]<=swap;
     cache_gen[base[432]]<=base[63:0];cache_page[base[432]]<=base[127:64];finish(0);end
   default:state<=IDLE;
   endcase
 end
endmodule
