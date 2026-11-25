# ICU source ordering; paths are relative to the repository root.
# The containing SoC must compile its compatible lpu_pkg, lpu_mxm_config_pkg,
# lpu_mxm_backend_isa_pkg and lpu_vxm_math_pkg before this manifest.
# lpu_fifo/lpu_sram and the FU execution/stream modules remain external
# dependencies. Do not add a second copy of the same package/module through
# another filelist. This manifest does not replace the SoC integration list.
rtl/icu/icu_program_load/lpu_program_load_pkg.sv
rtl/icu/icu_mxm/lpu_mxm_isa_pkg.sv
rtl/icu/icu_qctl/lpu_qctl_pkg.sv
rtl/icu/icu_program_load/lpu_instruction_dma.sv
rtl/icu/icu_program_load/lpu_program_load_config_fifo.sv
rtl/icu/icu_program_load/lpu_program_load_controller.sv
rtl/icu/icu_program_load/lpu_program_load_path.sv
rtl/icu/icu_program_load/lpu_program_load_reassembler.sv
rtl/icu/icu_program_load/lpu_program_load_system.sv
rtl/icu/icu_program_load/lpu_program_load_word_fifo.sv
rtl/icu/icu_program_distribute/lpu_program_distribute_elastic_stage.sv
rtl/icu/icu_program_distribute/lpu_program_distribute_relay.sv
rtl/icu/icu_program_distribute/lpu_program_distribute_relay_chain.sv
rtl/icu/icu_program_distribute/lpu_program_distribute_system.sv
rtl/icu/icu_program_distribute/lpu_program_distributor.sv
rtl/icu/icu_mem/lpu_mem_local_imem.sv
rtl/icu/icu_mem/lpu_mem_imem_fetch.sv
rtl/icu/icu_mem/lpu_mem_macro_decoder.sv
rtl/icu/icu_mem/lpu_mem_macro_scheduler.sv
rtl/icu/icu_mem/lpu_mem_macro_frontend.sv
rtl/icu/icu_mem/lpu_mem_local_imem_frontend.sv
rtl/icu/icu_mem/lpu_mem_subsystem.sv
rtl/icu/icu_mxm/lpu_mxm_local_imem.sv
rtl/icu/icu_mxm/lpu_mxm_imem_fetch.sv
rtl/icu/icu_mxm/lpu_mxm_macro_decoder_core.sv
rtl/icu/icu_mxm/lpu_mxm_macro_scheduler_core.sv
rtl/icu/icu_mxm/lpu_mxm_macro_frontend.sv
rtl/icu/icu_mxm/lpu_mxm_local_imem_frontend.sv
rtl/icu/icu_mxm/lpu_mxm_subsystem.sv
rtl/icu/icu_qctl/lpu_qctl_load_manager.sv
rtl/icu/icu_qctl/lpu_qctl_relay.sv
rtl/icu/icu_qctl/lpu_qctl_relay_chain.sv
rtl/icu/icu_qctl/lpu_qctl_controller.sv
rtl/icu/icu_qctl/lpu_qctl_endpoint.sv
rtl/icu/icu_qctl/lpu_qctl_event_buffer.sv
rtl/icu/icu_qctl/lpu_qctl_fabric.sv
rtl/icu/icu_qctl/lpu_qctl_global_subsystem.sv
rtl/icu/icu_sxm/lpu_sxm_native_issue_calendar.sv
rtl/icu/icu_sxm/lpu_sxm_native_subsystem.sv
rtl/icu/icu_vxm/lpu_vxm_sequential_decoder.sv
rtl/icu/icu_vxm/lpu_vxm_local_imem_frontend.sv
rtl/icu/icu_vxm/lpu_vxm_instruction_controller.sv
rtl/icu/icu_vxm/lpu_vxm_subsystem.sv
