  // Simulation elaboration ledger. Combinational variables and wire views do
  // not count as state. Vivado mapping/replication is reported independently.
  wire [31:0] source_payload_bits [0:T-1],source_control_bits[0:T-1];
  for(genvar bs=0;bs<T;bs++)begin:g_bits
    assign source_payload_bits[bs]=$bits(dut.u_storage.g_source[bs].data_q);
    assign source_control_bits[bs]=$bits(dut.u_storage.g_source[bs].occupied_q)+$bits(dut.u_storage.g_source[bs].complete_q)+
      $bits(dut.u_storage.g_source[bs].due_q)+$bits(dut.u_storage.g_source[bs].dest_q)+$bits(dut.u_storage.g_source[bs].matrix_q)+
      $bits(dut.u_storage.g_source[bs].wr_q)+$bits(dut.u_storage.g_source[bs].rd_q)+$bits(dut.u_storage.g_source[bs].received_q)+$bits(dut.u_storage.g_source[bs].bad_q);
  end
  initial begin:ledger
    integer payload,typed,rows,row_payload,legacy_bits;
    #1;payload=0;typed=$bits(dut.u_storage.active_q)+$bits(dut.u_storage.fault_q)+$bits(dut.u_storage.fp32_q)+$bits(dut.u_storage.mode_q)+
      $bits(dut.u_storage.count_q)+$bits(dut.u_storage.lane_q)+$bits(dut.u_storage.tile_q)+$bits(dut.u_storage.timer_q)+$bits(dut.u_storage.sent_q);
    for(integer s=0;s<T;s++)begin payload+=int'(source_payload_bits[s]);typed+=int'(source_control_bits[s]);end
    rows=$bits(dut.u_core.context_q)+$bits(dut.u_core.tile_q)+$bits(dut.u_core.context_valid_q)+$bits(dut.u_core.tile_valid_q)+
      $bits(dut.u_core.slot_valid_q)+$bits(dut.u_core.slot_owner_q)+$bits(dut.u_core.slot_claimed_q)+$bits(dut.u_core.written_q)+$bits(dut.u_core.read_q)+$bits(dut.u_core.slot_dest_q)+
      $bits(dut.u_core.pipe_valid_q)+$bits(dut.u_core.pipe_ctx_q)+$bits(dut.u_core.pipe_dest_q)+$bits(dut.u_core.pipe_branches_q)+
      $bits(dut.u_core.pair_fill_q)+$bits(dut.u_core.pair_ready_q)+$bits(dut.u_core.pair_ctx_q)+$bits(dut.u_core.pair_sequence_q)+
      $bits(dut.u_core.run_active_q)+$bits(dut.u_core.run_ctx_q)+$bits(dut.u_core.high_q)+$bits(dut.u_core.timer_q)+$bits(dut.u_core.interval_q)+$bits(dut.u_core.remaining_q)+$bits(dut.u_core.sequence_q);
    row_payload=$bits(dut.u_core.pipe_data_q)+$bits(dut.u_core.pair_data_q);
    legacy_bits=$bits(dut.u_legacy.north_q)+$bits(dut.u_legacy.north_valid_q)+$bits(dut.u_legacy.rows_q)+$bits(dut.u_legacy.metadata_q)+$bits(dut.u_legacy.claimed_q)+$bits(dut.u_legacy.destination_q);
    if(payload!=T*(T+1)/2*2048 || row_payload!=512*(T+1))$fatal(1,"state ledger mismatch");
    $display("STATE_BITS T=%0d source_payload=%0d typed_control=%0d row_control=%0d row_pair_payload=%0d legacy_control=%0d",T,payload,typed,rows,row_payload,legacy_bits);
  end
