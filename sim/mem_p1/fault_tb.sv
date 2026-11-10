`timescale 1ns/1ps

// Independent safety/wave oracle for exceptional cycles, not a CModel trace.
module mem_p1_fault_tb;
  logic clk=0,rst_n=0;
  logic[1:0] valid=0;
  logic[63:0] command=0;
  logic[255:0] state_valid=0;
  logic[16383:0] state_data='x;
  logic[7:0] feedback=0;
  wire[511:0] consume[0:0];
  wire[7:0] rv[0:0],rd[0:0],local_consume[0:0];
  wire[511:0] data[0:0];
  wire[39:0] stream[0:0];
  wire[1:0] fault[0:0],tile_valid[0:0],busy[0:0],north_valid[0:0],bank_id[0:0];
  wire[5:0] code[0:0];
  wire[3:0] tile_id[0:0];
  wire[29:0] fault_row[0:0];
  wire[63:0] north[0:0];
  integer probe_row=0;
  wire[63:0] observed[0:7];
  logic[63:0] memory[0:0][0:1][0:3][0:63];
  logic[31:0] pipeline[0:1][1:3];
  logic pipe_valid[0:1][1:3];
  logic[31:0] current[0:1][0:3];
  logic current_valid[0:1][0:3];
  integer ticks=0,rejected=0,missing=0,collision_cases=0;

  for(genvar n=0;n<1;n=n+1)begin:gen_error
    mem_slice #(.P_MEM_BANK_DEPTH_ROWS(64),.P_MEM_ACTIVE_ROWS(32)) dut(
      .clk_i(clk),.rst_ni(rst_n),.bank_issue_valid_i(valid),.bank_issue_i(command),
      .sr_state_valid_i(state_valid),.sr_state_data_i(state_data),.producer_collision_i(feedback),
      .sr_consume_o(consume[n]),.sr_inject_valid_o(rv[n]),.sr_inject_data_o(data[n]),
      .sr_inject_stream_dir_o(rd[n]),.sr_inject_stream_idx_o(stream[n]),
      .mem_fault_valid_o(fault[n]),.mem_fault_code_o(code[n]),.mem_fault_bank_id_o(bank_id[n]),
      .mem_fault_tile_valid_o(tile_valid[n]),.mem_fault_tile_id_o(tile_id[n]),.mem_fault_row_o(fault_row[n]),
      .bank_north_cmd_valid_o(north_valid[n]),.bank_north_cmd_o(north[n]),.bank_pipeline_busy_o(busy[n]));
    assign local_consume[n]=dut.bank_stream_consume;
    for(genvar b=0;b<2;b=b+1)begin:observe_bank
      for(genvar t=0;t<4;t=t+1)begin:observe_tile
        assign observed[n*8+b*4+t]=dut.gen_bank[b].u_logical_bank.gen_leaf[t].u_leaf.mem_array[probe_row];
      end
    end
  end

  function automatic bit legal(input logic[31:0] word);
    legal=(word[2:0]<2) && !(word[2:0]==0 && word[31]) &&
          word[14:9]==0 && !word[30] && word[29:15]<32;
  endfunction
  function automatic [31:0] cmd(input integer op,row,s,tap);
    cmd=(tap<<31)|(row<<15)|(s<<3)|op;
  endfunction

  task automatic tick;
    logic[511:0] expected_consume;
    logic[7:0] expected_rv,expected_local;
    logic[1:0] expected_busy;
    integer sr_index,row,d,s,entry,fc,ft,fr;
    bit fv,tv;
    logic[31:0] word;
    logic[63:0] value;
    for(integer b=0;b<2;b=b+1)for(integer t=0;t<4;t=t+1)begin
      current[b][t]=t==0?command[b*32+:32]:pipeline[b][t];
      current_valid[b][t]=rst_n && (t==0?(valid[b]&&legal(command[b*32+:32])):pipe_valid[b][t]);
    end
    expected_busy=0;
    for(integer b=0;b<2;b=b+1)for(integer t=0;t<4;t=t+1)expected_busy[b]|=current_valid[b][t];
    expected_consume=0;
    for(integer b=0;b<2;b=b+1)for(integer t=0;t<4;t=t+1)begin
      word=current[b][t];sr_index=word[8:3]*4+t;
      if(current_valid[b][t] && word[2:0]==1 && !word[31] && state_valid[sr_index])
        expected_consume[b*256+sr_index]=1;
    end
    #3;
    for(integer n=0;n<1;n=n+1)begin
      if(consume[n]!==expected_consume || busy[n]!==expected_busy)$fatal(1,"safety consume/busy tick=%0d",ticks);
      for(integer b=0;b<2;b=b+1)if(rst_n && valid[b] && !legal(command[b*32+:32]))begin
        if(!fault[n][b] || code[n][b*3+:3]!==3'd1 || tile_valid[n][b])$fatal(1,"issue fault phase tick=%0d",ticks);
      end
    end
    clk=1;#1;
    for(integer n=0;n<1;n=n+1)begin
      expected_rv=0;expected_local=0;
      for(integer b=0;b<2;b=b+1)begin
        for(integer t=0;t<4;t=t+1)begin
          word=current[b][t];row=word[29:15];sr_index=word[8:3]*4+t;entry=b*4+t;
          if(current_valid[b][t])begin
            if(word[2:0]==0)begin
              expected_rv[entry]=1;
              if(data[n][entry*64+:64]!==memory[n][b][t][row] ||
                 rd[n][entry]!==word[8] || stream[n][entry*5+:5]!==word[7:3])
                $fatal(1,"response preserved tick=%0d instance=%0d bank=%0d tile=%0d",ticks,n,b,t);
            end else if(state_valid[sr_index])begin
              memory[n][b][t][row]=state_data[sr_index*64+:64];
              expected_local[entry]=!word[31];
            end
          end
        end
        fv=0;fc=0;ft=0;fr=0;tv=0;
        if(rst_n && valid[b] && !legal(command[b*32+:32]))begin
          fv=1;fc=1;fr=command[b*32+15+:15];rejected=rejected+1;
        end
        for(integer t=0;t<4;t=t+1)if(!fv && expected_rv[b*4+t] && feedback[b*4+t])begin
          fv=1;fc=3;ft=t;tv=1;fr=current[b][t][29:15];collision_cases=collision_cases+1;
        end
        for(integer t=0;t<4;t=t+1)begin
          word=current[b][t];sr_index=word[8:3]*4+t;
          if(!fv && current_valid[b][t] && word[2:0]==1 && !word[31] && !state_valid[sr_index])begin
            fv=1;fc=2;ft=t;tv=1;fr=word[29:15];missing=missing+1;
          end
        end
        if(fault[n][b]!==fv || code[n][b*3+:3]!==3'(fc) || tile_valid[n][b]!==tv ||
           bank_id[n][b]!==1'(b) || (fv && fault_row[n][b*15+:15]!==15'(fr)) ||
           (tv && tile_id[n][b*2+:2]!==2'(ft)))$fatal(1,"fault aggregation tick=%0d instance=%0d bank=%0d",ticks,n,b);
        if(north_valid[n][b]!==current_valid[b][3] ||
           (current_valid[b][3] && north[n][b*32+:32]!==current[b][3]))$fatal(1,"north wave tick=%0d",ticks);
      end
      if(rv[n]!==expected_rv || local_consume[n]!==expected_local)$fatal(1,"response/local consume tick=%0d",ticks);
    end
    // Check every physical row, including inactive rows, after every safety step.
    for(integer r=0;r<64;r=r+1)begin
      probe_row=r;#1;
      for(integer n=0;n<1;n=n+1)for(integer b=0;b<2;b=b+1)for(integer t=0;t<4;t=t+1)
        if(observed[n*8+b*4+t]!==memory[n][b][t][r])$fatal(1,"safety storage tick=%0d instance=%0d bank=%0d tile=%0d row=%0d",ticks,n,b,t,r);
    end
    for(integer b=0;b<2;b=b+1)begin
      for(integer t=3;t>1;t=t-1)begin pipeline[b][t]=pipeline[b][t-1];pipe_valid[b][t]=rst_n&&pipe_valid[b][t-1];end
      pipeline[b][1]=command[b*32+:32];pipe_valid[b][1]=rst_n&&valid[b]&&legal(command[b*32+:32]);
      if(!rst_n)for(integer t=1;t<4;t=t+1)pipe_valid[b][t]=0;
    end
    clk=0;#1;ticks=ticks+1;
  endtask

  initial begin
    for(integer n=0;n<1;n=n+1)for(integer b=0;b<2;b=b+1)for(integer t=0;t<4;t=t+1)
      for(integer r=0;r<64;r=r+1)memory[n][b][t][r]=0;
    for(integer b=0;b<2;b=b+1)for(integer t=1;t<4;t=t+1)begin pipeline[b][t]=0;pipe_valid[b][t]=0;end
    tick();rst_n=1;
    state_valid='1;
    for(integer c=0;c<256;c=c+1)state_data[c*64+:64]=64'hf0e1d2c3b4a59687^(64'h102030405060708*c);
    // Seed all tile memories, then mix reads/writes, missing data, new bad
    // commands and diagnostic feedback without stopping the old command wave.
    for(integer c=0;c<96;c=c+1)begin
      valid=3;feedback=0;state_valid='1;
      command[31:0]=cmd(c%3==0?0:1,c%16,c%64,c%3==2);
      command[63:32]=cmd(c%2,(c+7)%16,(c*3+32)%64,0);
      if(c>=12 && c%4==0)begin command[31:0]=cmd(1,32,c%64,c%2);feedback='1;end
      if(c>=12 && c%7==0)begin command[63:32]=cmd(2,5,0,0);feedback='1;end
      if(c>=12 && c%9==0)command[31:0]=cmd(0,1,0,1);
      if(c>=12 && c%11==0)command[31:0]=cmd(0,1,0,0)|32'h40000000;
      if(c>=12 && c%13==0)command[31:0]=cmd(0,1,0,0)|32'h00000200;
      if(c>=12 && c%3==0)begin state_valid=0;state_data='x;end
      else for(integer q=0;q<256;q=q+1)state_data[q*64+:64]=64'h13579bdf02468ace^(64'h102030405060708*(q+c));
      if(c%5==0)feedback='1;
      if(c==47)begin rst_n=0;valid=0;end
      if(c==48)rst_n=1;
      tick();
    end
    valid=0;feedback=0;state_valid='1;state_data='0;repeat(5)tick();
    if(rejected==0 || missing==0 || collision_cases==0)$fatal(1,"safety coverage empty");
    $display("MEM_SAFETY TEST_PASS ticks=%0d rejected=%0d missing=%0d diagnostic_collisions=%0d storage_checks=%0d",ticks,rejected,missing,collision_cases,ticks*512);
    $finish;
  end
endmodule

module mem_p1_group_collision_tb;
  logic clk=0,rst_n=0;
  logic[7:0] valid=0;
  logic[255:0] command=0;
  logic[31:0] feedback=0;
  wire[31:0] left_valid,right_valid,internal_collision;
  wire[2047:0] data;
  wire[7:0] fault;
  wire[23:0] code;
  mem_group #(.P_MEM_BANK_DEPTH_ROWS(64)) dut(.clk_i(clk),.rst_ni(rst_n),
    .group_issue_valid_i(valid),.group_issue_i(command),
    .left_boundary_state_valid_i(256'b0),.left_boundary_state_data_i(16384'bx),
    .right_boundary_state_valid_i(256'b0),.right_boundary_state_data_i(16384'bx),
    .external_producer_collision_i(feedback),.left_boundary_inject_valid_o(left_valid),
    .right_boundary_inject_valid_o(right_valid),.boundary_inject_data_o(data),
    .internal_mem_collision_o(internal_collision),.slice_fault_valid_o(fault),.slice_fault_code_o(code));
  initial begin
    #2;clk=1;#1;clk=0;rst_n=1;
    // Two banks in slice0 and a third producer in slice1 share E0.
    valid=8'b00000111;
    #2;clk=1;#1;clk=0;valid=0;
    for(integer t=0;t<4;t=t+1)begin
      if(t!=0)begin #2;clk=1;#1;clk=0;end
      for(integer p=0;p<32;p=p+1)begin
        if(right_valid[p]!==((p==t)||(p==4+t)||(p==8+t)) || left_valid[p]!==1'b0 ||
           internal_collision[p]!==right_valid[p])$fatal(1,"MEM internal collision lost candidate tile=%0d p=%0d",t,p);
        if(right_valid[p] && data[p*64+:64]!==64'b0)$fatal(1,"cold collision response bytes");
      end
      if(fault!==8'b00000111 || code[2:0]!==3'd3 || code[5:3]!==3'd3 || code[8:6]!==3'd3)
        $fatal(1,"MEM internal collision diagnostics");
    end
    #2;clk=1;#1;clk=0;
    if(right_valid || left_valid || internal_collision || fault)$fatal(1,"stale MEM collision");
    $display("MEM_GROUP_DIAGNOSTIC TEST_PASS producers=3 tiles=4 raw_valid_preserved=1 SRF_NOT_TESTED");
    $finish;
  end
endmodule
