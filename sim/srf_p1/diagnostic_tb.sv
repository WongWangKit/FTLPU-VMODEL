`timescale 1ns/1ps
module srf_p1_diagnostic_tb;
  logic clk=0,rst_n=0;
  logic [15:0] up,sv,down;
  logic [127:0] ud,sd,dd;
  logic [31:0] inject,consume;
  logic [255:0] data_in;
  logic col,inv;
  integer which,checks=0;
  logic legacy_valid,legacy_down,legacy_col,legacy_inv;
  logic [63:0] legacy_data,legacy_dd;
  ftlpu_sr_superlane_col_dir_lane #(.STREAMS(2)) leaf(.clk_i(clk),.rst_ni(rst_n),
    .upstream_valid_i(up),.upstream_data_i(ud),.state_valid_o(sv),.state_data_o(sd),
    .consume_i(consume),.downstream_valid_o(down),.downstream_data_o(dd),
    .inject_valid_i(inject),.inject_data_i(data_in),.collision_o(col),.invalid_consume_o(inv));
  ftlpu_sr_superlane_col_dir #(.STREAMS(1)) legacy(.clk_i(clk),.rst_ni(rst_n),
    .upstream_valid_i(1'b0),.upstream_data_i(64'b0),.state_valid_o(legacy_valid),.state_data_o(legacy_data),
    .consume_i(2'b0),.downstream_valid_o(legacy_down),.downstream_data_o(legacy_dd),
    .inject_valid_i(2'b0),.inject_data_i(128'b0),.collision_o(legacy_col),.invalid_consume_o(legacy_inv));
  // Small non-default geometry; two independent direction instances.
  logic [47:0] small_up[0:1],small_out[0:1];
  logic [383:0] small_data[0:1],small_od[0:1];
  logic [143:0] small_state[0:1],model[0:1],next_model[0:1];
  logic [1151:0] small_sd[0:1],model_data[0:1],next_model_data[0:1];
  logic [287:0] small_cons[0:1];
  logic [5:0] small_col[0:1],small_inv[0:1];
  for(genvar d=0;d<2;d=d+1)begin: directions
    ftlpu_sr_direction_fabric_lane #(.COLUMNS(3),.SUPERLANES(2),.STREAMS(3),.DIRECTION(d)) dir(
      .clk_i(clk),.rst_ni(rst_n),.stream_valid_i(small_up[d]),.stream_data_i(small_data[d]),
      .stream_valid_o(small_out[d]),.stream_data_o(small_od[d]),.inject_valid_i(288'b0),.inject_data_i(2304'b0),
      .consume_i(small_cons[d]),.collision_o(small_col[d]),.invalid_consume_o(small_inv[d]),
      .state_valid_o(small_state[d]),.state_data_o(small_sd[d]));
  end
  always #5 clk=~clk;
  task clear;
    begin
      up=0;ud='x;inject=0;data_in='x;consume=0;
      for(integer d=0;d<2;d=d+1)begin small_up[d]=0;small_data[d]=0;small_cons[d]=0;end
    end
  endtask
  task tick;
    begin @(posedge clk);#1;checks=checks+1;end
  endtask
  initial begin
    clear();if(!$value$plusargs("CASE=%d",which))which=0;
    repeat(2)@(negedge clk);rst_n=1;
    if(which==0)begin
      // Exhaust all masks, with invalid payload intentionally X.
      for(integer m=0;m<256;m=m+1)begin
        @(negedge clk);clear();up[7:0]=m[7:0];
        for(integer l=0;l<8;l=l+1)if(m[l])ud[l*8+:8]=8'(m+l*23);
        tick();if(sv!=={8'b0,m[7:0]})$fatal(1,"all-mask valid m=%0d",m);
        for(integer l=0;l<8;l=l+1)if(m[l] && sd[l*8+:8]!==8'(m+l*23))$fatal(1,"all-mask byte m=%0d lane=%0d",m,l);
      end
      // Each lane: current-valid, upstream, two producers, two consumers (64).
      for(integer l=0;l<8;l=l+1)for(integer bits=0;bits<64;bits=bits+1)begin
        @(negedge clk);clear();up[l]=bits[0];ud[l*8+:8]=8'h31;tick();
        @(negedge clk);clear();up[l]=bits[1];ud[l*8+:8]=8'h42;
        inject[l]=bits[2];data_in[l*8+:8]=8'h53;
        inject[16+l]=bits[3];data_in[(16+l)*8+:8]=8'h64;
        consume[l]=bits[4];consume[16+l]=bits[5];#1;
        if(col!==(int'(bits[1])+int'(bits[2])+int'(bits[3])>1))$fatal(1,"truth collision bits=%0d lane=%0d",bits,l);
        if(inv!==(!bits[0]&&(bits[4]||bits[5])))$fatal(1,"truth invalid bits=%0d lane=%0d",bits,l);
        if(down[l]!==(bits[0]&&!bits[4]&&!bits[5]))$fatal(1,"truth downstream bits=%0d lane=%0d",bits,l);
        tick();
        if(sv[l]!==(int'(bits[1])+int'(bits[2])+int'(bits[3])==1))$fatal(1,"truth next bits=%0d lane=%0d",bits,l);
        if(sv[l] && sd[l*8+:8] !== (bits[1]?8'h42:bits[2]?8'h53:8'h64))$fatal(1,"truth byte bits=%0d lane=%0d",bits,l);
      end
      $display("SRF_DIAGNOSTIC TEST_PASS masks=256 lane_truth_cases=512 checks=%0d",checks);$finish;
    end else if(which==1)begin
      for(integer d=0;d<2;d=d+1)begin model[d]=0;model_data[d]=0;end
      for(integer cycle=0;cycle<272;cycle=cycle+1)begin
        @(negedge clk);clear();
        for(integer d=0;d<2;d=d+1)begin
          for(integer t=0;t<2;t=t+1)for(integer s=0;s<3;s=s+1)begin
            small_up[d][(t*3+s)*8+:8]=8'(cycle+t*17+s*31+d*53);
            for(integer l=0;l<8;l=l+1)small_data[d][((t*3+s)*8+l)*8+:8]=8'(cycle+t*37+s*13+l*19+d*71);
          end
          for(integer c=0;c<3;c=c+1)for(integer t=0;t<2;t=t+1)for(integer s=0;s<3;s=s+1)for(integer l=0;l<8;l=l+1)
            if((cycle+c+t+s+l)%5==0)small_cons[d][((c*2+t)*2*3+s)*8+l]=model[d][((c*2+t)*3+s)*8+l];
          next_model[d]=0;next_model_data[d]=0;
          for(integer c=0;c<3;c=c+1)for(integer t=0;t<2;t=t+1)for(integer s=0;s<3;s=s+1)for(integer l=0;l<8;l=l+1)begin
            integer src,here;src=c+(d==0?-1:1);here=((c*2+t)*3+s)*8+l;
            if(src<0||src>=3)begin next_model[d][here]=small_up[d][(t*3+s)*8+l];next_model_data[d][here*8+:8]=small_data[d][((t*3+s)*8+l)*8+:8];end
            else begin next_model[d][here]=model[d][((src*2+t)*3+s)*8+l]&&!small_cons[d][((src*2+t)*2*3+s)*8+l];next_model_data[d][here*8+:8]=model_data[d][(((src*2+t)*3+s)*8+l)*8+:8];end
          end
        end
        #1;
        for(integer d=0;d<2;d=d+1)begin
          if(small_col[d]!==0||small_inv[d]!==0)$fatal(1,"small fault cycle=%0d dir=%0d",cycle,d);
          for(integer t=0;t<2;t=t+1)for(integer s=0;s<3;s=s+1)for(integer l=0;l<8;l=l+1)begin
            integer endc,b;endc=d==0?2:0;b=(t*3+s)*8+l;
            if(small_out[d][b] !== (model[d][((endc*2+t)*3+s)*8+l]&&!small_cons[d][((endc*2+t)*2*3+s)*8+l]))$fatal(1,"small boundary cycle=%0d",cycle);
          end
        end
        tick();
        for(integer d=0;d<2;d=d+1)begin
          if(small_state[d]!==next_model[d])$fatal(1,"small valid cycle=%0d dir=%0d",cycle,d);
          for(integer b=0;b<144;b=b+1)if(next_model[d][b]&&small_sd[d][b*8+:8]!==next_model_data[d][b*8+:8])$fatal(1,"small byte cycle=%0d dir=%0d cell=%0d",cycle,d,b);
          model[d]=next_model[d];model_data[d]=next_model_data[d];
        end
      end
      $display("SRF_SMALL_GEOMETRY TEST_PASS cycles=272 C=3 T=2 S=3 directions=2");$finish;
    end else begin
      @(negedge clk);clear();
      case(which)
        2: force legacy.u_lane.valid_state_q=8'h01;
        3: up[0]=1'bx;
        4: inject[0]=1'bx;
        5: consume[0]=1'bx;
        6: begin up[0]=1;ud[7:0]='x;end
        7: begin inject[0]=1;data_in[7:0]='x;end
        8: rst_n=1'bx;
        default:$fatal(1,"invalid CASE");
      endcase
      tick();$display("UNEXPECTED_DIAGNOSTIC_SUCCESS");$finish;
    end
  end
  initial begin #100000;$fatal(1,"diagnostic watchdog");end
endmodule
