`timescale 1ns/1ps
// Verification-only dual-hemisphere caller of the EXISTING integration.
// Canonical32 remains its API; c7raw32 adapters live in this upstream caller.
module mem_profiles_integration_tb #(parameter integer PROFILE=16);
  localparam integer T=lpu_native_config_pkg::tile_rows(PROFILE);
  localparam integer P=lpu_native_config_pkg::mem_depth_rows(PROFILE);
  localparam integer M=104*T, N=64*T, STATES=2*16*T*32, LEAVES=2*M;
  logic clk=0,rst_n=0;
  logic [103:0] issue_valid[0:1],native_valid[0:1],command_fault[0:1];
  logic [3327:0] issue[0:1],native_issue[0:1];
  logic [N-1:0] boundary_valid[0:1];
  logic [N*64-1:0] boundary_data[0:1];
  wire [STATES-1:0] state_valid[0:1];
  wire [STATES*64-1:0] state_data[0:1];
  wire [M-1:0] read_valid[0:1],read_dir[0:1],internal_collision[0:1];
  wire [M*64-1:0] read_data[0:1];
  wire [M*5-1:0] read_stream[0:1];
  wire [M*4-1:0] read_boundary[0:1];
  wire [14*N-1:0] consume[0:1];
  wire [2*16*T-1:0] collision[0:1],invalid_consume[0:1];
  wire [103:0] bank_fault[0:1];
  wire fault[0:1],busy[0:1];
  logic [STATES-1:0] expected_state_valid[0:1];
  logic [STATES*64-1:0] expected_state_data[0:1];
  logic [M-1:0] expected_read_valid[0:1],expected_read_dir[0:1];
  logic [M*64-1:0] expected_read_data[0:1];
  logic [M*5-1:0] expected_read_stream[0:1];
  logic [M*4-1:0] expected_read_boundary[0:1];
  logic [14*N-1:0] expected_consume[0:1];
  logic audit=0;
  logic [63:0] signature[0:LEAVES-1];
  integer bound_leaves=0;
  for(genvar h=0;h<2;h=h+1)begin:gen_hemi
    for(genvar bank=0;bank<104;bank=bank+1)begin:gen_c7
      mem_c7_primitive_adapter #(.P_MEM_BANK_DEPTH_ROWS(P),.P_MEM_ACTIVE_ROWS(P)) adapter(
        .issue_valid_i(issue_valid[h][bank]),.issue_instruction_i(issue[h][bank*32+:32]),
        .native_valid_o(native_valid[h][bank]),.native_command_o(native_issue[h][bank*32+:32]),
        .command_fault_o(command_fault[h][bank]));
    end
    lpu_mem_srf_integration #(.P_LPU_PROFILE(PROFILE)) dut(
      .clk_i(clk),.rst_ni(rst_n),.bank_issue_valid_i(native_valid[h]),.bank_issue_i(native_issue[h]),
      .boundary_valid_i(boundary_valid[h]),.boundary_data_i(boundary_data[h]),
      .boundary_valid_o(),.boundary_data_o(),.state_valid_o(state_valid[h]),.state_data_o(state_data[h]),
      .mem_boundary_consume_o(consume[h]),.mem_producer_valid_o(read_valid[h]),.mem_producer_data_o(read_data[h]),
      .mem_producer_direction_o(read_dir[h]),.mem_producer_stream_o(read_stream[h]),
      .mem_producer_boundary_o(read_boundary[h]),.srf_collision_o(collision[h]),
      .srf_invalid_consume_o(invalid_consume[h]),.mem_internal_collision_o(internal_collision[h]),
      .mem_bank_fault_valid_o(bank_fault[h]),.mem_fault_valid_o(fault[h]),.mem_busy_o(busy[h]));
    for(genvar g=0;g<13;g=g+1)begin:gen_g
      for(genvar s=0;s<4;s=s+1)begin:gen_s
        for(genvar b=0;b<2;b=b+1)begin:gen_b
          for(genvar t=0;t<T;t=t+1)begin:gen_t
            localparam integer ID=((h*52+g*4+s)*2+b)*T+t;
            initial begin
              #0;
              // Referencing the actual bound instance makes an absent checker
              // an elaboration error instead of an empty PASS.
              if($isunknown(dut.u_mem.gen_group[g].u_group.gen_slice[s].u_slice.gen_bank[b].u_logical_bank.gen_leaf[t].u_leaf.u_mem_input_checker.reset_seen))
                $fatal(1,"unknown bound checker state");
              if($size(dut.u_mem.gen_group[g].u_group.gen_slice[s].u_slice.gen_bank[b].u_logical_bank.gen_leaf[t].u_leaf.mem_array)!=P)
                $fatal(1,"physical SRAM depth not clipped to profile");
              bound_leaves=bound_leaves+1;
            end
            integer row;
            reg [63:0] digest;
            always @(audit) begin
              digest=64'hcbf29ce484222325;
              for(row=0;row<P;row=row+1)
                digest=(digest^dut.u_mem.gen_group[g].u_group.gen_slice[s].u_slice.gen_bank[b].u_logical_bank.gen_leaf[t].u_leaf.mem_array[row])*64'h100000001b3;
              signature[ID]=digest;
            end
          end
        end
      end
    end
  end
  integer fd,rc,version,profile,tiles,depth,cycles,c,seq,reset,ni,nb,ns,nr,nc;
  integer h,s,b,t,d,col,stream,id,index;
  logic [31:0] word;
  logic [63:0] data;
  string magic,path;
  initial begin
    for(integer q=0;q<2;q=q+1)begin
      issue_valid[q]=0;issue[q]=0;boundary_valid[q]=0;boundary_data[q]='0;
    end
    if(!$value$plusargs("VECTORS=%s",path))$fatal(1,"missing integration vectors");
    fd=$fopen(path,"r");if(!fd)$fatal(1,"cannot open integration vectors");
    rc=$fscanf(fd,"%s %d %d %d %d %d",magic,version,profile,tiles,depth,cycles);
    if(rc!=6 || magic!="MEM_INTEGRATION" || version!=1 || profile!=PROFILE || tiles!=T || depth!=P)
      $fatal(1,"integration configuration identity mismatch");
    for(c=0;c<cycles;c=c+1)begin
      rc=$fscanf(fd,"%d %d %d %d %d %d %d",seq,reset,ni,nb,ns,nr,nc);
      if(rc!=7 || seq!=c)$fatal(1,"truncated integration frame cycle=%0d",c);
      rst_n=!reset;
      for(integer q=0;q<2;q=q+1)begin
        issue_valid[q]=0;issue[q]=0;boundary_valid[q]=0;boundary_data[q]='0;
        expected_state_valid[q]=0;expected_state_data[q]=0;
        expected_read_valid[q]=0;expected_read_dir[q]=0;expected_read_data[q]=0;
        expected_read_stream[q]=0;expected_read_boundary[q]=0;expected_consume[q]=0;
      end
      for(integer q=0;q<ni;q=q+1)begin
        rc=$fscanf(fd,"%d %d %d %h",h,s,b,word);if(rc!=4)$fatal(1,"issue truncation");
        issue_valid[h][s*2+b]=1;issue[h][(s*2+b)*32+:32]=word;
      end
      for(integer q=0;q<nb;q=q+1)begin
        rc=$fscanf(fd,"%d %d %d %d %h",h,d,t,stream,data);if(rc!=5)$fatal(1,"boundary truncation");
        index=(d*T+t)*32+stream;boundary_valid[h][index]=1;boundary_data[h][index*64+:64]=data;
      end
      for(integer q=0;q<ns;q=q+1)begin
        rc=$fscanf(fd,"%d %d %d %d %d %h",h,d,col,t,stream,data);if(rc!=6)$fatal(1,"state truncation");
        index=((d*16+col)*T+t)*32+stream;expected_state_valid[h][index]=1;expected_state_data[h][index*64+:64]=data;
      end
      for(integer q=0;q<nr;q=q+1)begin
        rc=$fscanf(fd,"%d %d %d %d %d %h",h,id,d,stream,col,data);if(rc!=6)$fatal(1,"response truncation");
        expected_read_valid[h][id]=1;expected_read_dir[h][id]=d;
        expected_read_stream[h][id*5+:5]=stream;expected_read_boundary[h][id*4+:4]=col;
        expected_read_data[h][id*64+:64]=data;
      end
      for(integer q=0;q<nc;q=q+1)begin
        rc=$fscanf(fd,"%d %d %d %d %d",h,col,d,stream,t);if(rc!=5)$fatal(1,"consume truncation");
        expected_consume[h][col*N+(d*32+stream)*T+t]=1;
      end
      #4;
      for(integer q=0;q<2;q=q+1)begin
        if(command_fault[q] !== '0 || consume[q] !== expected_consume[q])$fatal(1,"integration consume/adapter cycle=%0d h=%0d",c,q);
        if(collision[q] !== '0 || invalid_consume[q] !== '0)$fatal(1,"unexpected legal-domain collision/consume cycle=%0d h=%0d",c,q);
      end
      clk=1;#1;
      for(integer q=0;q<2;q=q+1)begin
        if(read_valid[q] !== expected_read_valid[q])$fatal(1,"integration response valid cycle=%0d h=%0d",c,q);
        for(integer k=0;k<M;k=k+1)if(expected_read_valid[q][k])
          if(read_data[q][k*64+:64] !== expected_read_data[q][k*64+:64] || read_dir[q][k] !== expected_read_dir[q][k] || read_stream[q][k*5+:5] !== expected_read_stream[q][k*5+:5] || read_boundary[q][k*4+:4] !== expected_read_boundary[q][k*4+:4])
            $fatal(1,"integration response payload/identity cycle=%0d h=%0d source=%0d",c,q,k);
        if(state_valid[q] !== expected_state_valid[q])$fatal(1,"integration SRF state valid cycle=%0d h=%0d expected=%h actual=%h",c,q,expected_state_valid[q],state_valid[q]);
        for(integer k=0;k<STATES;k=k+1)if(expected_state_valid[q][k] && state_data[q][k*64+:64] !== expected_state_data[q][k*64+:64])
          $fatal(1,"integration SRF byte cycle=%0d h=%0d cell=%0d expected=%h actual=%h",c,q,k,expected_state_data[q][k*64+:64],state_data[q][k*64+:64]);
        if(fault[q] !== 0 || bank_fault[q] !== '0 || internal_collision[q] !== '0)$fatal(1,"unexpected MEM fault cycle=%0d h=%0d",c,q);
      end
      clk=0;#1;
    end
    rc=$fscanf(fd,"%s %d",magic,ni);if(rc!=2 || magic!="END" || ni!=LEAVES)$fatal(1,"missing storage audit");
    audit=~audit;#1;
    for(integer q=0;q<ni;q=q+1)begin
      rc=$fscanf(fd,"%d %d %d %d %h",h,s,b,t,data);id=((h*52+s)*2+b)*T+t;
      if(rc!=5 || signature[id] !== data)$fatal(1,"integration storage audit h=%0d s=%0d b=%0d t=%0d",h,s,b,t);
    end
    if(bound_leaves!=LEAVES)$fatal(1,"missing checker instances %0d/%0d",bound_leaves,LEAVES);
    if(busy[0] || busy[1] || read_valid[0] !== '0 || read_valid[1] !== '0)$fatal(1,"integration did not drain");
    $display("MEM_PROFILES_INTEGRATION TEST_PASS profile=%0d cycles=%0d leaves=%0d checker_instances=%0d",PROFILE,cycles,LEAVES,bound_leaves);
    $finish;
  end
endmodule
