// One physical iMEM and one ordered fetch engine per addressed instruction stream.
// A native event is packed on its second loader word; a macro image stores each word verbatim.
module lpu_slice_issue_frontend #(
  parameter integer PAYLOAD_BITS=128,AUX_BITS=0,QUEUE_KIND=-1,MACRO_DEPTH=64,ACTIVE_CONTEXTS=4,
  localparam EVENT_DEPTH=lpu_program_load_pkg::NATIVE_EVENT_DEPTH,
  localparam DEPTH=QUEUE_KIND<0?EVENT_DEPTH:(MACRO_DEPTH>EVENT_DEPTH?MACRO_DEPTH:EVENT_DEPTH),
  localparam AW=$clog2(DEPTH), CW=$clog2(DEPTH+1), EW=32+AUX_BITS+PAYLOAD_BITS,
  localparam W=QUEUE_KIND>=0 && EW<128?128:EW
)(
  input wire clk_i,rst_ni,clear_i,write_i,prime_i,macro_i,run_i,
  input wire [16:0] addr_i,input wire [127:0] data_i,input wire [3:0] strb_i,input wire last_i,
  input wire [31:0] cycle_i,input wire sink_ready_i,
  output wire [127:0] payload_o,output wire [31:0] aux_o,
  output wire launch_o,ready_o,idle_o,fault_o
);
  wire reset_n=rst_ni && !clear_i;
  logic half,sealed_q,primed,macro_q,finished,invalid;
  logic [AW-1:0] base;
  logic [CW-1:0] count;
  logic [PAYLOAD_BITS-1:0] first;
  logic [31:0] previous;
  wire room,sr,rv,rr,rl,pv,pr,pl,wv,wr,wl,fetch_fault,mem_fault;
  wire [AW-1:0] ra;
  wire [W-1:0] rd,word_data;
  wire [W-1:0] packed_event=W'({data_i[0+:32+AUX_BITS],first});
  wire bad_write=primed || sealed_q || !room || strb_i!=15 ||
      ((count!=0 || half) && macro_i!=macro_q) ||
      (macro_i ? (QUEUE_KIND<0 || addr_i>=MACRO_DEPTH || (count!=0 && addr_i!=(17'(base)+17'(count)))) :
       (addr_i!={count,half} || count>=EVENT_DEPTH ||
        (!half && (last_i || |(data_i>>PAYLOAD_BITS))) ||
        (half && ((|(data_i>>(32+AUX_BITS))) || (count!=0 && data_i[31:0]<=previous)))));
  wire start_fetch=prime_i && sealed_q && !primed && macro_i==macro_q;
  lpu_slice_imem #(.WORD_WIDTH(W),.DEPTH(DEPTH)) u_imem(
    .clk_i,.rst_ni(reset_n),.load_mode_i(!primed),
    .load_valid_i(write_i && !bad_write && (macro_i || half)),.load_ready_o(room),
    .load_address_i(macro_i?addr_i[AW-1:0]:AW'(count)),.load_data_i(macro_i?W'(data_i):packed_event),
    .request_valid_i(rv),.request_ready_o(rr),.request_address_i(ra),.request_last_i(rl),
    .response_valid_o(pv),.response_ready_i(pr),.response_data_o(rd),.response_last_o(pl),
    .outstanding_o(),.idle_o(),.fault_o(mem_fault));
  lpu_slice_imem_fetch #(.WORD_WIDTH(W),.IMEM_DEPTH(DEPTH)) u_fetch(
    .clk_i,.rst_ni(reset_n),.start_valid_i(start_fetch),.start_ready_o(sr),
    .start_base_address_i(base),.start_word_count_i(count),.request_valid_o(rv),.request_ready_i(rr),
    .request_address_o(ra),.request_last_o(rl),.response_valid_i(pv),.response_ready_o(pr),
    .response_data_i(rd),.response_last_i(pl),.word_valid_o(wv),.word_ready_i(wr),
    .word_o(word_data),.word_last_o(wl),.busy_o(),.done_o(),.fault_o(fetch_fault),.fault_code_o());
  wire macro_wr,macro_ready,macro_idle,macro_issue,macro_fault,macro_done;
  wire [$clog2(ACTIVE_CONTEXTS+1)-1:0] active_count;
  wire [2:0] waiting_contexts; // upstream default CONTEXT_FIFO_DEPTH=4
  wire streaming_prime=(int'(active_count)==ACTIVE_CONTEXTS) && waiting_contexts!=0;
  wire [48:0] instr;
  if(QUEUE_KIND>=0)begin:g_macro
    lpu_five_macro_frontend #(.QUEUE_KIND(QUEUE_KIND),.ACTIVE_CONTEXTS(ACTIVE_CONTEXTS)) u_macro(
      .clk_i,.rst_ni(reset_n),.run_i(run_i && macro_q),.prime_i(primed && !run_i && macro_q),
      .schedule_cycle_i(cycle_i),.fetch_word_valid_i(wv && macro_q),.fetch_word_ready_o(macro_wr),
      .fetch_word_i(128'(word_data)),.fetch_word_last_i(wl),.issue_valid_o(macro_issue),
      .issue_ready_i(sink_ready_i),.issue_instruction_o(instr),.issue_cycle_o(),.decoder_done_o(macro_done),
      .word_fifo_level_o(),.context_fifo_level_o(waiting_contexts),.active_count_o(active_count),.idle_o(macro_idle),
      .prime_ready_o(macro_ready),.fault_o(macro_fault),.fault_code_o());
  end else begin
    assign {macro_wr,macro_ready,macro_idle,macro_issue,macro_fault,macro_done,waiting_contexts,active_count,instr}='0;
  end
  wire [31:0] stamp=word_data[PAYLOAD_BITS+:32];
  wire due=primed && !macro_q && wv && run_i && stamp==cycle_i && !invalid;
  assign launch_o=macro_q?macro_issue:due;
  assign wr=macro_q?macro_wr:(due && sink_ready_i);
  assign ready_o=!invalid && ((!half && count==0) || (primed && (macro_q?(macro_ready || streaming_prime):wv)));
  assign idle_o=(!half && count==0) || (finished && (!macro_q || (macro_done && macro_idle)));
  assign fault_o=invalid || mem_fault || fetch_fault || (macro_q && macro_fault);
  assign payload_o=macro_q?128'(instr):128'(word_data[PAYLOAD_BITS-1:0]);
  assign aux_o=(word_data>>(PAYLOAD_BITS+32));
  always_ff @(posedge clk_i or negedge reset_n)begin
    if(!reset_n)begin half<=0;sealed_q<=0;primed<=0;macro_q<=0;count<=0;base<=0;
      finished<=0;invalid<=0;previous<=0;end
    else begin
      if(write_i)begin
        if(bad_write)invalid<=1;
        else begin
          macro_q<=macro_i;
          if(macro_i && count==0)base<=AW'(addr_i);
          if(!macro_i && !half)begin first<=data_i[PAYLOAD_BITS-1:0];half<=1;end
          else begin count<=count+1'b1;half<=0;sealed_q<=last_i;previous<=data_i[31:0];end
        end
      end
      if(prime_i)begin if(!start_fetch || !sr)invalid<=1;else primed<=1;end
      if(wv && wr && wl)finished<=1;
      if(!macro_q && run_i && wv && (stamp<cycle_i || (due && !sink_ready_i)))invalid<=1;
    end
  end
endmodule
