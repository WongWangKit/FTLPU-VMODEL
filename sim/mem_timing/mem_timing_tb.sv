`timescale 1ns/1ps

// Black-box oracle: schedule each accepted command at issue_cycle + row*hop.
// No DUT internals or arithmetic/control helper functions are inspected.
module mem_timing_tb #(
  parameter integer ROWS = 4,
  parameter integer SEED = 32'h4d454d31,
  parameter integer RAW_INGRESS = 0,
  parameter integer PHYSICAL_ROWS = 64
);
  localparam integer CELLS = 2*32*ROWS;
  localparam integer LIMIT = 4096;
  localparam integer TAIL = 3*(ROWS-1)+3;
  logic clk=0, rst_n=0;
  logic [1:0] issue_valid=0;
  logic [63:0] issue=0;
  logic [CELLS-1:0] sr_valid='1;
  logic [CELLS*64-1:0] sr_data=0;
  wire [2*CELLS-1:0] consume;
  wire [2*ROWS-1:0] read_valid, read_dir;
  wire [2*ROWS*64-1:0] read_data;
  wire [2*ROWS*5-1:0] read_stream;
  wire [1:0] fault, mem_fault, adapter_fault, native_valid, north_valid, busy;
  wire [63:0] native_issue;
  wire [5:0] fault_code;
  wire [63:0] north;
  logic [31:0] expected [0:LIMIT-1][0:1][0:ROWS-1];
  bit scheduled [0:LIMIT-1][0:1][0:ROWS-1];
  logic [63:0] memory [0:1][0:ROWS-1][0:63];
  integer last_issue [0:1];
  bit last_long [0:1];
  integer cycles=0, commands=0, reads=0, writes=0, rejects=0;
  integer long_events=0, short_events=0, tight_switches=0;
  integer trace_fd=0;
  bit suppress_stream=0;
  logic [31:0] random_state=SEED;
  string trace_path;

  if(RAW_INGRESS)begin:gen_raw_ingress
    for(genvar b=0;b<2;b=b+1)begin:gen_adapter
      mem_c7_primitive_adapter #(.P_MEM_BANK_DEPTH_ROWS(PHYSICAL_ROWS),.P_MEM_ACTIVE_ROWS(32)) adapter(
        .issue_valid_i(issue_valid[b]),.issue_instruction_i(issue[b*32+:32]),
        .native_valid_o(native_valid[b]),.native_command_o(native_issue[b*32+:32]),
        .command_fault_o(adapter_fault[b]));
    end
  end else begin:gen_direct_ingress
    assign native_valid=issue_valid;assign native_issue=issue;assign adapter_fault=0;
  end
  assign fault=mem_fault|adapter_fault;
  mem_slice #(.P_TILE_ROWS(ROWS), .P_MEM_BANK_DEPTH_ROWS(PHYSICAL_ROWS), .P_MEM_ACTIVE_ROWS(32)) dut (
    .clk_i(clk), .rst_ni(rst_n), .bank_issue_valid_i(native_valid), .bank_issue_i(native_issue),
    .sr_state_valid_i(sr_valid), .sr_state_data_i(sr_data), .producer_collision_i({2*ROWS{1'b0}}),
    .sr_consume_o(consume), .sr_inject_valid_o(read_valid), .sr_inject_data_o(read_data),
    .sr_inject_stream_dir_o(read_dir), .sr_inject_stream_idx_o(read_stream),
    .mem_fault_valid_o(mem_fault), .mem_fault_code_o(fault_code),
    .bank_north_cmd_valid_o(north_valid), .bank_north_cmd_o(north), .bank_pipeline_busy_o(busy)
  );

  function automatic [31:0] command(input integer op, address, stream, direction, tap, delay3);
    command=(tap<<31)|(delay3<<30)|(address<<15)|(direction<<8)|(stream<<3)|op;
    if(RAW_INGRESS)command=command|(((address+stream)%64)<<9);
  endfunction
  function automatic bit legal(input logic [31:0] word);
    legal=(word[2:0]<2) && !(word[2:0]==0 && word[31]) &&
          (RAW_INGRESS || word[14:9]==0) && (word[29:15]<32);
  endfunction
  function automatic bit can_issue(input logic [31:0] word, input integer bank);
    can_issue=word[30] || !last_long[bank] || cycles-last_issue[bank]>=2*(ROWS-1)+1;
  endfunction
  function automatic [31:0] random_next(input logic [31:0] value);
    random_next={value[30:0],value[31]^value[21]^value[1]^value[0]};
  endfunction

  task automatic step(input bit v0, input logic [31:0] w0, input bit v1, input logic [31:0] w1);
    logic [2*CELLS-1:0] want_consume;
    logic [2*ROWS-1:0] want_read;
    logic [1:0] want_busy;
    logic [31:0] word;
    logic [63:0] value;
    integer at,slot,address,entry,hop;
    if(cycles+TAIL>=LIMIT)$fatal(1,"test horizon exceeded");
    issue_valid={v1,v0};issue={w1,w0};
    sr_valid=suppress_stream?'0:'1;
    for(integer c=0;c<CELLS;c=c+1)
      sr_data[c*64+:64]=64'h4d454d0012345678 ^ (64'h102030405060708*(c+1)) ^ (64'h13579bdf*(cycles+1));
    if(!rst_n)begin
      for(integer t=cycles;t<LIMIT;t=t+1)
        for(integer b=0;b<2;b=b+1)for(integer r=0;r<ROWS;r=r+1)scheduled[t][b][r]=0;
      for(integer b=0;b<2;b=b+1)begin last_issue[b]=-100;last_long[b]=0;end
    end else begin
      for(integer b=0;b<2;b=b+1)begin
        word=issue[b*32+:32];
        if(issue_valid[b] && legal(word))begin
          if(!can_issue(word,b))$fatal(1,"oracle generated an unsafe transition");
          if(last_long[b] && !word[30] && cycles-last_issue[b]==2*(ROWS-1)+1)
            tight_switches=tight_switches+1;
          last_issue[b]=cycles;last_long[b]=word[30];commands=commands+1;
          hop=word[30]?3:1;
          for(integer r=0;r<ROWS;r=r+1)begin
            at=cycles+r*hop;
            if(scheduled[at][b][r])$fatal(1,"oracle schedule overlaps");
            scheduled[at][b][r]=1;expected[at][b][r]=RAW_INGRESS?(word & 32'hffff81ff):word;
          end
        end else if(issue_valid[b])rejects=rejects+1;
      end
    end
    want_busy=0;want_consume=0;want_read=0;
    for(integer b=0;b<2;b=b+1)begin
      for(integer t=cycles;t<=cycles+TAIL;t=t+1)
        for(integer r=0;r<ROWS;r=r+1)want_busy[b]|=scheduled[t][b][r];
      for(integer r=0;r<ROWS;r=r+1)if(scheduled[cycles][b][r])begin
        word=expected[cycles][b][r];slot=(word[8]*32+word[7:3])*ROWS+r;
        if(word[2:0]==0)want_read[b*ROWS+r]=1;
        if(word[2:0]==1 && !word[31] && sr_valid[slot])want_consume[b*CELLS+slot]=1;
      end
    end
    #2;
    if(consume!==want_consume || busy!==want_busy)
      $fatal(1,"consume/busy mismatch E%0d rows=%0d actual_busy=%b expected=%b",cycles,ROWS,busy,want_busy);
    clk=1;#1;
    if(read_valid!==want_read)$fatal(1,"read wave E%0d actual=%h expected=%h",cycles,read_valid,want_read);
    for(integer b=0;b<2;b=b+1)begin
      if(north_valid[b]!==scheduled[cycles][b][ROWS-1] ||
         (scheduled[cycles][b][ROWS-1] && north[b*32+:32]!==expected[cycles][b][ROWS-1]))
        $fatal(1,"north trace mismatch E%0d bank=%0d",cycles,b);
      if(fault[b] !== (rst_n && issue_valid[b] && !legal(issue[b*32+:32])))
        $fatal(1,"fault mismatch E%0d bank=%0d code=%0d",cycles,b,fault_code[b*3+:3]);
      if(mem_fault[b] && fault_code[b*3+:3]!==3'd1)$fatal(1,"wrong rejection code");
      for(integer r=0;r<ROWS;r=r+1)if(scheduled[cycles][b][r])begin
        word=expected[cycles][b][r];address=word[29:15];entry=b*ROWS+r;
        slot=(word[8]*32+word[7:3])*ROWS+r;
        if(word[30])long_events=long_events+1;else short_events=short_events+1;
        if(word[2:0]==0)begin
          reads=reads+1;value=memory[b][r][address];
          if(read_data[entry*64+:64]!==value || read_dir[entry]!==word[8] || read_stream[entry*5+:5]!==word[7:3])
            $fatal(1,"read data/metadata E%0d bank=%0d row=%0d address=%0d actual=%h expected=%h",cycles,b,r,address,read_data[entry*64+:64],value);
        end else begin
          value=sr_data[slot*64+:64];
          if(sr_valid[slot])begin memory[b][r][address]=value;writes=writes+1;end
        end
        if(trace_fd)$fwrite(trace_fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%h\n",
          cycles,b,r,word[30]?3:1,word[2:0],address,word[7:3],word[8],word[31],value);
      end
    end
    clk=0;#1;cycles=cycles+1;
  endtask

  task automatic drain;
    repeat(TAIL)step(0,0,0,0);
  endtask

  initial begin : run_test
    logic [31:0] a,b;
    bit va,vb;
    for(integer t=0;t<LIMIT;t=t+1)
      for(integer bank=0;bank<2;bank=bank+1)for(integer r=0;r<ROWS;r=r+1)scheduled[t][bank][r]=0;
    for(integer bank=0;bank<2;bank=bank+1)begin
      last_issue[bank]=-100;last_long[bank]=0;
      for(integer r=0;r<ROWS;r=r+1)for(integer address=0;address<64;address=address+1)memory[bank][r][address]=0;
    end
    if($value$plusargs("TRACE=%s",trace_path))begin
      trace_fd=$fopen(trace_path,"w");
      if(!trace_fd)$fatal(1,"cannot open trace");
      $fwrite(trace_fd,"cycle,bank,superlane,hop,opcode,address,stream,direction,preserve,data\n");
    end
    rst_n=1;#1;rst_n=0;#1;step(0,0,0,0);rst_n=1;
    // Both queues sustain one command per cycle, including repeated words.
    for(integer i=0;i<32;i=i+1)
      step(1,command(i<16?1:0,i%8,5,0,0,0),1,command(i<16?1:0,i%8,21,1,i<16 && i%3==0,0));
    // Tight 1-to-3 change; independent bank 1 keeps using one-cycle hops.
    for(integer i=0;i<32;i=i+1)
      step(1,command(i<16?1:0,i%8,6,1,0,1),1,command(i<16?1:0,i%8,22,0,0,0));
    // Exactly the compiler's minimum number of bubbles for the full column.
    repeat(2*(ROWS-1))step(0,0,0,0);
    for(integer i=0;i<16;i=i+1)step(1,command(0,i%8,5,0,0,0),1,command(0,i%8,21,1,0,0));
    drain();
    // Long-path full rate on both banks, then repeated identical read tokens.
    for(integer i=0;i<32;i=i+1)step(1,command(1,i%8,7,i%2,i%2,1),1,command(1,i%8,23,i%2,0,1));
    for(integer i=0;i<8;i=i+1)step(1,command(0,0,7,0,0,1),1,command(0,0,23,1,0,1));
    drain();
    // Deterministic random instructions; the oracle enforces compiler spacing.
    for(integer i=0;i<1000;i=i+1)begin
      random_state=random_next(random_state);
      a=command(random_state[0],random_state[5:1],random_state[9:6],random_state[10],random_state[0] && random_state[11],random_state[12]);
      va=random_state[13] || random_state[14];
      random_state=random_next(random_state);
      b=command(random_state[0],random_state[5:1],16+random_state[9:6],random_state[10],random_state[0] && random_state[11],random_state[12]);
      vb=random_state[13] || random_state[14];
      step(va && can_issue(a,0),a,vb && can_issue(b,1),b);
    end
    drain();
    // New rejected input must leave older long waves intact.
    step(1,command(0,0,1,0,0,1),1,command(0,0,17,1,0,1));
    step(1,command(RAW_INGRESS?3:0,0,1,0,0,0)|32'h200,1,command(2,0,17,0,0,0));
    step(1,command(0,32,1,0,0,0),1,command(0,0,17,0,1,0));
    drain();
    // Reset flushes long relays but preserves already-written SRAM contents.
    step(1,command(1,12,2,0,0,1),1,command(1,12,18,1,0,1));
    step(0,0,0,0);rst_n=0;step(0,0,0,0);rst_n=1;
    for(integer i=0;i<8;i=i+1)step(1,command(0,12,2,0,0,0),1,command(0,12,18,1,0,0));
    drain();
    // Missing WriteTap input is still a local no-op, in long mode as well.
    suppress_stream=1;
    step(1,command(1,12,2,0,1,1),1,command(1,12,18,1,1,1));
    drain();suppress_stream=0;
    step(1,command(0,12,2,0,0,1),1,command(0,12,18,1,0,1));
    drain();
    if(busy!==0 || !tight_switches || !long_events || !short_events || rejects!=4)
      $fatal(1,"missing timing coverage/busy tail");
    if(trace_fd)$fclose(trace_fd);
    $display("MEM_TIMING TEST_PASS rows=%0d seed=%h cycles=%0d commands=%0d reads=%0d writes=%0d long_events=%0d short_events=%0d tight_switches=%0d rejects=%0d raw_ingress=%0d physical_rows=%0d",
      ROWS,SEED,cycles,commands,reads,writes,long_events,short_events,tight_switches,rejects,RAW_INGRESS,PHYSICAL_ROWS);
    $finish;
  end
endmodule

module mem_timing_bad_transition_tb #(
  parameter integer ROWS=4,
  parameter integer GAP=0
);
  logic clk=0,rst_n=0,valid=0;
  logic [31:0] word=0;
  mem_bank_control_column #(.P_TILE_ROWS(ROWS)) dut(
    .clk_i(clk),.rst_ni(rst_n),.south_cmd_valid_i(valid),.south_cmd_i(word));
  task automatic step;
    #2;clk=1;#1;clk=0;#1;
  endtask
  initial begin
    step();rst_n=1;valid=1;word=32'h40000000;step();
    valid=0;repeat(GAP)step();
    valid=1;word=32'h00008000;step();
    valid=0;repeat(3*ROWS+4)step();
    $fatal(1,"UNEXPECTED_UNSAFE_TRANSITION_ACCEPTED");
  end
endmodule
