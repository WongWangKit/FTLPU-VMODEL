// DEV oldest waiting-target selection, extended with epoch ownership and atomic phases.
// Entries stay in admission order. A phase receipt occupies its original slot until acknowledged.
module lpu_qctl_event_buffer #(parameter integer N=2, DEPTH=8, G=64) (
 input logic clk_i,rst_ni,clear_i,input logic [G-1:0] generation_i,
 input logic event_valid_i,output logic event_ready_o,input logic [31:0] event_tag_i,
 input logic [G-1:0] event_generation_i,input logic [N-1:0] event_mask_i,input logic event_phase_i,
 input logic [N-1:0] active_i,wait_i,input logic [N*32-1:0] wait_tag_i,
 output logic [N-1:0] fire_o,
 output logic receipt_valid_o,input logic receipt_ready_i,output logic [31:0] receipt_tag_o,
 output logic [G-1:0] receipt_generation_o,output logic [63:0] receipt_cycle_o,output logic idle_o,fault_o
);
 typedef struct packed {logic [N-1:0] pending;logic [31:0] tag;logic phase,receipt;logic [63:0] edge_no;} entry_t;
 entry_t slots[DEPTH],next_slots[DEPTH];logic [$clog2(DEPTH+1)-1:0] count, count_d;
 integer sel,rec;logic [N-1:0] tag_hit;logic [63:0] wall;logic input_fault;
 always_comb begin
   sel=-1;rec=-1;tag_hit='0;fire_o='0;receipt_tag_o='0;receipt_cycle_o='0;
   for(int i=0;i<DEPTH;i++)if(i<count)begin
     if(sel<0 && |(slots[i].pending & wait_i))sel=i;
     if(slots[i].receipt)begin
       if(rec<0)rec=i;else if(slots[i].edge_no<slots[rec].edge_no)rec=i;
     end
   end
   if(sel>=0 && !fault_o && !clear_i)begin
     for(int q=0;q<N;q++)tag_hit[q]=slots[sel].pending[q] && wait_i[q] && (wait_tag_i[q*32+:32]==slots[sel].tag);
     if(!slots[sel].phase || tag_hit==slots[sel].pending) fire_o=tag_hit;
   end
   if(rec>=0)begin receipt_tag_o=slots[rec].tag;receipt_cycle_o=slots[rec].edge_no;end
 end
 assign idle_o=count==0;
 assign receipt_valid_o=rec>=0 && !clear_i && !fault_o;
 assign receipt_generation_o=generation_i;
 assign event_ready_o=rst_ni && !clear_i && !fault_o && (event_generation_i<generation_i || count<DEPTH);
 assign input_fault=event_valid_i && event_ready_o && (event_mask_i=='0 || event_generation_i>generation_i || generation_i=='0 ||
      (event_generation_i==generation_i && |(event_mask_i & ~active_i)));
 always_comb begin
   count_d='0;for(int i=0;i<DEPTH;i++)next_slots[i]='0;
   for(int i=0;i<DEPTH;i++)if(i<count)begin
     entry_t v;v=slots[i];
     if(i==sel && |fire_o)begin
       v.pending=v.pending & ~fire_o;
       if(v.pending=='0 && v.phase)begin v.receipt=1;v.edge_no=wall;end
     end
     if((|v.pending || v.receipt) && !(i==rec && receipt_valid_o && receipt_ready_i))begin
       next_slots[count_d]=v;count_d=count_d+1'b1;
     end
   end
   if(event_valid_i && event_ready_o && !input_fault && event_generation_i==generation_i)begin
     next_slots[count_d]={event_mask_i,event_tag_i,event_phase_i,1'b0,64'b0};count_d=count_d+1'b1;
   end
 end
 always_ff @(posedge clk_i or negedge rst_ni)begin
   if(!rst_ni)begin count<='0;fault_o<=0;wall<=0;for(int i=0;i<DEPTH;i++)slots[i]<='0;end
   else begin
     wall<=wall+1'b1;
     if(clear_i)begin count<='0;fault_o<=0;end
     else begin count<=count_d;if(input_fault)fault_o<=1;for(int i=0;i<DEPTH;i++)slots[i]<=next_slots[i];end
   end
 end
endmodule

