`timescale 1ns/1ps
module program_transport_tb;
import lpu_program_load_pkg::*;

parameter integer DMA_DATA_WIDTH=256;
parameter integer FIFO_DEPTH=3;
localparam COMMAND_DEPTH=16, COMMAND_ADDRESS_WIDTH=4;

logic clk_i;
logic rst_ni;
logic abort_i;
logic command_write_valid_i;
logic command_write_ready_o;
logic [COMMAND_ADDRESS_WIDTH-1:0] command_write_address_i;
logic [2:0] command_write_opcode_i;
logic [63:0] command_write_source_address_i;
logic [31:0] command_write_byte_count_i;
logic [1:0] command_write_hemisphere_i;
logic [3:0] command_write_target_kind_i;
logic [7:0] command_write_queue_id_i;
logic [1:0] command_write_format_i;
logic [16:0] command_write_imem_base_address_i;
logic command_write_image_first_i;
logic command_write_image_last_i;
logic [15:0] command_write_expected_word_count_i;
logic [COMMAND_ADDRESS_WIDTH-1:0] command_write_jump_address_i;
logic start_valid_i;
logic start_ready_o;
logic [COMMAND_ADDRESS_WIDTH:0] start_command_count_i;
logic dma_cmd_valid_o;
logic dma_cmd_ready_i;
logic [63:0] dma_cmd_address_o;
logic [31:0] dma_cmd_length_o;
logic [7:0] dma_cmd_id_o;
logic dma_rsp_valid_i;
logic dma_rsp_ready_o;
logic [DMA_DATA_WIDTH-1:0] dma_rsp_data_i;
logic [DMA_DATA_WIDTH/8-1:0] dma_rsp_keep_i;
logic dma_rsp_last_i;
logic [7:0] dma_rsp_id_i;
logic dma_rsp_error_i;
logic west_load_valid_o;
logic west_load_ready_i;
logic [2:0] west_load_control_o;
logic [127:0] west_load_data_o;
logic [3:0] west_load_strb_o;
logic [3:0] west_load_target_kind_o;
logic [7:0] west_load_queue_id_o;
logic [16:0] west_load_imem_address_o;
logic west_load_last_o;
logic east_load_valid_o;
logic east_load_ready_i;
logic [2:0] east_load_control_o;
logic [127:0] east_load_data_o;
logic [3:0] east_load_strb_o;
logic [3:0] east_load_target_kind_o;
logic [7:0] east_load_queue_id_o;
logic [16:0] east_load_imem_address_o;
logic east_load_last_o;
logic west_commit_valid_i;
logic west_commit_ready_o;
logic west_commit_error_i;
logic east_commit_valid_i;
logic east_commit_ready_o;
logic east_commit_error_i;
logic weight_load_done_i;
logic all_frontends_ready_i;
logic instruction_load_done_o;
logic program_start_o;
logic busy_o;
logic [31:0] generated_word_count_o;
logic [31:0] committed_word_count_o;
logic error_o;
logic [5:0] error_code_o;
lpu_program_load_subsystem #(
.COMMAND_DEPTH(COMMAND_DEPTH), .DMA_DATA_WIDTH(DMA_DATA_WIDTH),
.CONFIG_FIFO_DEPTH(FIFO_DEPTH), .DMA_OUTSTANDING_DEPTH(FIFO_DEPTH),
.DMA_RX_FIFO_DEPTH(FIFO_DEPTH), .WORD_FIFO_DEPTH(FIFO_DEPTH),
.COMMIT_FIFO_DEPTH(FIFO_DEPTH), .PRIME_FIFO_DEPTH(4),
.REASSEMBLY_BUFFER_BYTES(DMA_DATA_WIDTH/8+16), .IMEM_DEPTH(64)
) dut (.*);
initial clk_i=0; always #5 clk_i=~clk_i;

integer cyc=0, mode=0, req_w=0,req_r=0,off=0;
integer east_words=0,west_words=0,primes=0,ec_w=0,ec_r=0,wc_w=0,wc_r=0;
integer lengths[64],ids[64],addresses[64],e_due[64],w_due[64];
logic took_rsp=0,took_ec=0,took_wc=0;
integer n;
integer sampled_fault=-1;
task automatic ck(input logic ok,input string s);if(!ok)$fatal(1,"%s cycle=%0d error=%0d",s,cyc,error_code_o);endtask
always @(posedge clk_i) if(rst_ni) begin
 cyc=cyc+1;
 if(error_o && sampled_fault==-1) sampled_fault=int'(error_code_o);
 if(cyc>5000)$fatal(1,"timeout mode=%0d",mode);
 if(dma_cmd_valid_o && dma_cmd_ready_i)begin
  addresses[req_w]=int'(dma_cmd_address_o);lengths[req_w]=int'(dma_cmd_length_o);ids[req_w]=int'(dma_cmd_id_o);req_w++;
 end
 took_rsp=dma_rsp_valid_i&&dma_rsp_ready_o;
 if(took_rsp)begin off+=$countones(dma_rsp_keep_i);if(dma_rsp_last_i)begin req_r++;off=0;end end
 took_ec=east_commit_valid_i&&east_commit_ready_o;if(took_ec)ec_r++;
 took_wc=west_commit_valid_i&&west_commit_ready_o;if(took_wc)wc_r++;
 if(east_load_valid_o&&east_load_ready_i)begin
  if(east_load_control_o==PROGRAM_LOAD_WRITE)begin
   ck(east_load_strb_o==7 && east_load_queue_id_o==3 && east_load_target_kind_o==PROGRAM_TARGET_MEM,"east metadata");
   ck(east_load_imem_address_o==5+east_words,"east address");
   for(integer b=0;b<12;b++)ck(east_load_data_o[b*8+:8]==8'(east_words*12+b),"96-bit reassembly");
   ck(east_load_last_o==(east_words==4),"east last");east_words++;e_due[ec_w]=cyc+7;ec_w++;
  end else begin ck(east_load_control_o==PROGRAM_LOAD_PRIME && east_words==5 && ec_r==5,"early east PRIME");primes++;end
 end
 if(west_load_valid_o&&west_load_ready_i)begin
  if(west_load_control_o==PROGRAM_LOAD_WRITE)begin
   ck(west_load_strb_o==15 && west_load_queue_id_o==1 && west_load_target_kind_o==PROGRAM_TARGET_MXM_COMPUTE,"west metadata");
   ck(west_load_imem_address_o==7+west_words,"west address");
   for(integer b=0;b<16;b++)ck(west_load_data_o[b*8+:8]==8'(west_words*16+b),"128-bit reassembly");
   ck(west_load_last_o==(west_words==2),"west last");west_words++;w_due[wc_w]=cyc+5;wc_w++;
  end else begin ck(west_load_control_o==PROGRAM_LOAD_PRIME && west_words==3 && wc_r==3,"early west PRIME");primes++;end
 end
 if(mode==0)ck(!error_o,"unexpected transport fault");
 if(!weight_load_done_i)ck(!program_start_o,"early START before dependencies");
end
always @(negedge clk_i) if(rst_ni)begin
 dma_cmd_ready_i=cyc%7!=0;
 east_load_ready_i=!(cyc>=25&&cyc<100)&&cyc%3!=0;
 west_load_ready_i=cyc%5!=0;
 if(took_rsp)dma_rsp_valid_i=0;
 if(!dma_rsp_valid_i && req_r<req_w && cyc%4!=0 && (mode==0 || mode==5 || (req_r==0 && off==0)))begin
  n=lengths[req_r]-off;if(n>DMA_DATA_WIDTH/8)n=DMA_DATA_WIDTH/8;
  dma_rsp_valid_i=1;dma_rsp_data_i=0;dma_rsp_keep_i=0;
  for(integer b=0;b<n;b++)begin dma_rsp_keep_i[b]=1;dma_rsp_data_i[b*8+:8]=8'(addresses[req_r]+off+b);end
  dma_rsp_last_i=off+n==lengths[req_r];dma_rsp_id_i=8'(ids[req_r]);dma_rsp_error_i=0;
  if(req_r==0&&off==0)case(mode)
   1:dma_rsp_id_i=8'hfe;
   2:dma_rsp_error_i=1;
   3:dma_rsp_keep_i[1]=0;
   4:dma_rsp_last_i=!dma_rsp_last_i;
  endcase
 end
 if(took_ec)east_commit_valid_i=0;
 if(took_wc)west_commit_valid_i=0;
 if(!east_commit_valid_i&&ec_r<ec_w&&e_due[ec_r]<=cyc)begin east_commit_valid_i=1;east_commit_error_i=mode==5;end
 if(!west_commit_valid_i&&wc_r<wc_w&&w_due[wc_r]<=cyc)west_commit_valid_i=1;
 all_frontends_ready_i=primes==2;
end
task automatic command(input integer ix,op,addr,len,hemi,kind,q,fmt,base,first,last,words);
 @(negedge clk_i);
 command_write_valid_i=1;command_write_address_i=4'(ix);command_write_opcode_i=3'(op);
 command_write_source_address_i=64'(addr);command_write_byte_count_i=32'(len);
 command_write_hemisphere_i=2'(hemi);command_write_target_kind_i=4'(kind);command_write_queue_id_i=8'(q);
 command_write_format_i=2'(fmt);command_write_imem_base_address_i=17'(base);
 command_write_image_first_i=1'(first);command_write_image_last_i=1'(last);command_write_expected_word_count_i=16'(words);
 do @(posedge clk_i);while(!command_write_ready_o);
 @(negedge clk_i);command_write_valid_i=0;
endtask
initial begin
rst_ni='0;
abort_i='0;
command_write_valid_i='0;
command_write_address_i='0;
command_write_opcode_i='0;
command_write_source_address_i='0;
command_write_byte_count_i='0;
command_write_hemisphere_i='0;
command_write_target_kind_i='0;
command_write_queue_id_i='0;
command_write_format_i='0;
command_write_imem_base_address_i='0;
command_write_image_first_i='0;
command_write_image_last_i='0;
command_write_expected_word_count_i='0;
command_write_jump_address_i='0;
start_valid_i='0;
start_command_count_i='0;
dma_cmd_ready_i='0;
dma_rsp_valid_i='0;
dma_rsp_data_i='0;
dma_rsp_keep_i='0;
dma_rsp_last_i='0;
dma_rsp_id_i='0;
dma_rsp_error_i='0;
west_load_ready_i='0;
east_load_ready_i='0;
west_commit_valid_i='0;
west_commit_error_i='0;
east_commit_valid_i='0;
east_commit_error_i='0;
weight_load_done_i='0;
all_frontends_ready_i='0;
 void'($value$plusargs("CASE=%d",mode));
 repeat(4)@(negedge clk_i);rst_ni=1;
 command(0,PROGRAM_LOADER_LOAD_IMEM,0,20,0,0,3,0,5,1,0,5);
 command(1,PROGRAM_LOADER_LOAD_IMEM,20,40,0,0,3,0,5,0,1,5);
 command(2,PROGRAM_LOADER_WAIT_DMA,0,0,0,0,3,0,0,0,0,0);
 command(3,PROGRAM_LOADER_COMMIT_QUEUE,0,0,0,0,3,0,0,0,0,0);
 command(4,PROGRAM_LOADER_LOAD_IMEM,0,48,1,3,1,1,7,1,1,3);
 command(5,PROGRAM_LOADER_WAIT_DMA,0,0,1,3,1,0,0,0,0,0);
 command(6,PROGRAM_LOADER_COMMIT_QUEUE,0,0,1,3,1,0,0,0,0,0);
 command(7,PROGRAM_LOADER_END,0,0,0,0,0,0,0,0,0,0);
 @(negedge clk_i);start_command_count_i=8;start_valid_i=1;
 do @(posedge clk_i);while(!start_ready_o);
 @(negedge clk_i);start_valid_i=0;
 if(mode!=0)begin
  // Faults, like ready/valid, are sampled on the clock edge. LAST changes
  // the FIFO head after the edge; the driver releases VALID on negedge.
  wait(sampled_fault!=-1);@(negedge clk_i);
  case(mode)
   1:ck(sampled_fault==PROGRAM_FAULT_DMA_ID,"wrong ID fault");
   2:ck(sampled_fault==PROGRAM_FAULT_DMA_RESPONSE,"response fault");
   3:ck(sampled_fault==PROGRAM_FAULT_KEEP,"keep fault");
   4:ck(sampled_fault==PROGRAM_FAULT_BURST_LENGTH,"length fault");
   5:ck(sampled_fault==PROGRAM_FAULT_COMMIT,"commit fault");
  endcase
  repeat(5)@(negedge clk_i);ck(error_o&&!program_start_o,"sticky error");
 end else begin
  wait(instruction_load_done_o && primes==2 && !busy_o);
  @(negedge clk_i);ck(east_words==5&&west_words==3&&generated_word_count_o==8&&committed_word_count_o==8,"final conservation");
  repeat(10)@(negedge clk_i);weight_load_done_i=1;
  @(negedge clk_i);ck(program_start_o,"START gate");
 end
 $display("PASS transport width=%0d depth=%0d case=%0d",DMA_DATA_WIDTH,FIFO_DEPTH,mode);$finish;
end
endmodule
