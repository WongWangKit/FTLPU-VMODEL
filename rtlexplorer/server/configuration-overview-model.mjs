const source = (file, line, symbol, expression, status = 'rtl-confirmed') => ({ file, line, symbol, expression, status })

function moduleParameter(snapshot, moduleName, parameterName) {
  const module = snapshot.modules?.find((item) => item.name === moduleName)
  const parameter = module?.parameters?.find((item) => item.name === parameterName)
  if (!parameter) return null
  return {
    value: Number.isFinite(parameter.resolvedDefault) ? parameter.resolvedDefault : null,
    expression: parameter.default,
    evidence: source(module.file, module.line, `${moduleName}.${parameterName}`, parameter.raw),
  }
}

function globalParameter(snapshot, name, sourceFile = null) {
  const matches = (snapshot.configuration?.globalParameters ?? []).filter((item) =>
    item.name === name && (!sourceFile || item.sourceFile === sourceFile))
  const parameter = matches[0]
  if (!parameter) return null
  return {
    value: Number.isFinite(parameter.resolvedDefault) ? parameter.resolvedDefault : null,
    expression: parameter.default,
    evidence: source(parameter.sourceFile, parameter.line, `${parameter.packageName}::${parameter.name}`, parameter.raw),
  }
}

function physicalFact(physicalArchitecture, blockId, label) {
  const fact = physicalArchitecture?.blocks?.find((block) => block.id === blockId)?.structure?.facts?.find((item) => item.label === label)
  if (!fact) return null
  return {
    value: fact.value,
    expression: fact.expression,
    evidence: source(fact.source.file, fact.source.line, label, fact.expression, fact.evidenceStatus),
  }
}

function instanceSource(snapshot, parentModule, instanceName, symbol, expression) {
  const definition = snapshot.modules?.find((item) => item.name === parentModule)
  const instance = definition?.instances?.find((item) => item.name === instanceName)
  return source(definition?.file ?? 'snapshot', instance?.line ?? definition?.line ?? 1, symbol ?? instanceName, expression, instance ? 'rtl-confirmed' : 'needs-review')
}

function resolved(primary, fallback, label) {
  if (primary && Number.isFinite(primary.value)) return primary
  if (fallback && Number.isFinite(fallback.value)) return fallback
  return {
    value: null,
    expression: primary?.expression ?? fallback?.expression ?? 'unresolved',
    evidence: source(primary?.evidence?.file ?? fallback?.evidence?.file ?? 'snapshot', primary?.evidence?.line ?? fallback?.evidence?.line ?? 1, label, primary?.expression ?? fallback?.expression ?? 'unresolved', 'needs-review'),
  }
}

const multiply = (...values) => values.every(Number.isFinite) ? values.reduce((result, value) => result * value, 1) : null
const divideCeil = (numerator, denominator) => Number.isFinite(numerator) && Number.isFinite(denominator) && denominator > 0 ? Math.ceil(numerator / denominator) : null

function unit(id, name, unitType, category, count, expression, evidence, status = evidence?.status ?? 'rtl-confirmed', detail = null) {
  return { id, name, unitType, category, count, expression, evidence: evidence ? [evidence] : [], status, detail }
}

export function buildConfigurationOverviewModel(snapshot, physicalArchitecture) {
  const pkg = 'rtl/core/lpu_pkg.sv'
  const hemispheres = resolved(globalParameter(snapshot, 'HEMISPHERES', pkg), null, 'HEMISPHERES')
  const memColumns = resolved(moduleParameter(snapshot, 'lpu_mem_subsystem', 'ACTIVE_COLUMNS'), physicalFact(physicalArchitecture, 'physical:west:mem', 'Active columns / hemisphere'), 'ACTIVE_COLUMNS')
  const memGroups = resolved(globalParameter(snapshot, 'MEM_GROUPS', pkg), physicalFact(physicalArchitecture, 'physical:west:mem', 'Column groups'), 'MEM_GROUPS')
  const columnsPerGroup = resolved(globalParameter(snapshot, 'MEM_SLICES_PER_GROUP', pkg), physicalFact(physicalArchitecture, 'physical:west:mem', 'Columns / group'), 'MEM_SLICES_PER_GROUP')
  const banksPerColumn = resolved(globalParameter(snapshot, 'MEM_BANKS_PER_SLICE', pkg), physicalFact(physicalArchitecture, 'physical:west:mem', 'Banks / column'), 'MEM_BANKS_PER_SLICE')
  const tileRows = resolved(globalParameter(snapshot, 'TILE_ROWS', pkg), physicalFact(physicalArchitecture, 'physical:west:mem', 'Tile slices / bank'), 'TILE_ROWS')
  const lanesPerTile = resolved(globalParameter(snapshot, 'LANES_PER_TILE', pkg), physicalFact(physicalArchitecture, 'physical:central:vxm', 'Lanes / tile'), 'LANES_PER_TILE')
  const packageStreamColumns = resolved(globalParameter(snapshot, 'STREAM_REGISTER_COLUMNS', pkg), null, 'STREAM_REGISTER_COLUMNS')
  const activeStreamColumns = resolved(
    moduleParameter(snapshot, 'lpu_mem_srf_command_integration', 'COLUMNS'),
    moduleParameter(snapshot, 'ftlpu_sr_hemisphere_fabric', 'COLUMNS'),
    'lpu_mem_srf_command_integration.COLUMNS',
  )
  const depthRows = resolved(globalParameter(snapshot, 'SRAM_DEPTH_ROWS', pkg), null, 'SRAM_DEPTH_ROWS')
  const memInstructionWidth = resolved(globalParameter(snapshot, 'MEM_INSTRUCTION_WIDTH', pkg), null, 'MEM_INSTRUCTION_WIDTH')
  const nativeCommandWidth = resolved(globalParameter(snapshot, 'MEM_NATIVE_COMMAND_WIDTH', pkg), null, 'MEM_NATIVE_COMMAND_WIDTH')
  const memAddressWidth = resolved(globalParameter(snapshot, 'MEM_ADDRESS_WIDTH', pkg), null, 'MEM_ADDRESS_WIDTH')
  const memBankCount = resolved(globalParameter(snapshot, 'MEM_BANK_COUNT', pkg), null, 'MEM_BANK_COUNT')
  const mxmCount = resolved(globalParameter(snapshot, 'MXM_COUNT', pkg), null, 'MXM_COUNT')
  const sxmCount = resolved(globalParameter(snapshot, 'SXM_COUNT', pkg), null, 'SXM_COUNT')
  const vxmAluCount = resolved(globalParameter(snapshot, 'VXM_ALU_COUNT', pkg), null, 'VXM_ALU_COUNT')
  const vxmLocalQueueCount = resolved(globalParameter(snapshot, 'VXM_LOCAL_QUEUE_COUNT', pkg), null, 'VXM_LOCAL_QUEUE_COUNT')
  const mxmAccumulatorBlocks = resolved(globalParameter(snapshot, 'MXM_ACCUMULATOR_BLOCK_COUNT', pkg), null, 'MXM_ACCUMULATOR_BLOCK_COUNT')
  const streamsPerDirection = resolved(globalParameter(snapshot, 'STREAMS_PER_DIRECTION', pkg), null, 'STREAMS_PER_DIRECTION')
  const useSramMacroParameter = moduleParameter(snapshot, 'lpu_top', 'USE_SRAM_MACRO')
  const qctlParameter = moduleParameter(snapshot, 'lpu_top', 'ENABLE_QCTL')
  const qctlQueueCount = resolved(moduleParameter(snapshot, 'lpu_top', 'QCTL_QUEUE_COUNT'), globalParameter(snapshot, 'QCTL_QUEUE_COUNT', 'rtl/icu/lpu_qctl_pkg.sv'), 'QCTL_QUEUE_COUNT')
  const qctlTotalCapacity = resolved(moduleParameter(snapshot, 'lpu_qctl_global_subsystem', 'TOTAL_CAPACITY'), null, 'lpu_qctl_global_subsystem.TOTAL_CAPACITY')
  const qctlRegionDepth = resolved(moduleParameter(snapshot, 'lpu_qctl_global_subsystem', 'REGION_DEPTH'), null, 'lpu_qctl_global_subsystem.REGION_DEPTH')
  const qctlRelayBufferDepth = resolved(moduleParameter(snapshot, 'lpu_qctl_global_subsystem', 'RELAY_BUFFER_DEPTH'), null, 'lpu_qctl_global_subsystem.RELAY_BUFFER_DEPTH')
  const qctlQueueEntryLimit = resolved(moduleParameter(snapshot, 'lpu_qctl_global_subsystem', 'QUEUE_ENTRY_LIMIT'), null, 'lpu_qctl_global_subsystem.QUEUE_ENTRY_LIMIT')
  const qctlRelayCount = resolved(globalParameter(snapshot, 'QCTL_RELAY_COUNT', 'rtl/icu/lpu_qctl_pkg.sv'), null, 'QCTL_RELAY_COUNT')
  const qctlRelayCountPerHemisphere = resolved(globalParameter(snapshot, 'QCTL_RELAY_COUNT_PER_HEMISPHERE', 'rtl/icu/lpu_qctl_pkg.sv'), null, 'QCTL_RELAY_COUNT_PER_HEMISPHERE')
  const qctlEventDepth = resolved(moduleParameter(snapshot, 'lpu_qctl_global_subsystem', 'EVENT_DEPTH'), null, 'lpu_qctl_global_subsystem.EVENT_DEPTH')
  const useNativeMemParameter = moduleParameter(snapshot, 'lpu_top', 'USE_NATIVE_MEM')
  const relayDefinition = snapshot.modules?.find((item) => item.name === 'lpu_program_distribute_relay')
  const relayChainDefinition = snapshot.modules?.find((item) => item.name === 'lpu_program_distribute_relay_chain')
  const distributionNetworkDefinition = snapshot.modules?.find((item) => item.name === 'lpu_program_distribute_system')
  const topDefinition = snapshot.modules?.find((item) => item.name === 'lpu_top')
  const clusterDefinition = snapshot.modules?.find((item) => item.name === 'lpu_fu_subsystem_cluster')
  const sxmSubsystemDefinition = snapshot.modules?.find((item) => item.name === 'lpu_sxm_native_subsystem')
  const vxmSubsystemDefinition = snapshot.modules?.find((item) => item.name === 'lpu_vxm_subsystem')
  const requiredProgramPorts = ['program_valid_i', 'program_ready_o', 'program_control_i', 'program_destination_i', 'program_address_i', 'program_data_i', 'program_strb_i', 'program_last_i', 'program_error_o']
  const hasProgramBoundary = (definition) => requiredProgramPorts.every((port) => definition?.ports?.some((item) => item.name === port))
  const hasConnectedProgramBoundary = (instanceName) => {
    const instance = clusterDefinition?.instances?.find((item) => item.name === instanceName)
    return requiredProgramPorts.every((port) => instance?.connections?.some((item) => item.port === port))
  }
  const sxmBoundaryConnected = hasProgramBoundary(sxmSubsystemDefinition) && hasConnectedProgramBoundary('u_sxm_subsystem')
  const vxmBoundaryConnected = hasProgramBoundary(vxmSubsystemDefinition) && hasConnectedProgramBoundary('u_vxm_subsystem')
  const networkIntegrated = topDefinition?.instances?.some((item) => item.name === 'u_program_distribute_system' && item.moduleName === 'lpu_program_distribute_system') ?? false
  const relayChainIntegrated = distributionNetworkDefinition?.instances?.some((item) => item.moduleName === 'lpu_program_distribute_relay_chain') ?? false
  const relayStagesGenerated = relayChainDefinition?.instances?.some((item) => item.moduleName === 'lpu_program_distribute_relay') ?? false
  const relayIntegrated = networkIntegrated && relayChainIntegrated && relayStagesGenerated
  const relayBufferDepth = resolved(moduleParameter(snapshot, 'lpu_program_distribute_relay', 'BUFFER_DEPTH'), null, 'lpu_program_distribute_relay.BUFFER_DEPTH')
  const relayGroupsPerStage = resolved(globalParameter(snapshot, 'PROGRAM_RELAY_MEM_GROUPS_PER_STAGE', 'rtl/program_load/lpu_program_load_pkg.sv'), moduleParameter(snapshot, 'lpu_program_distribute_relay', 'MEM_GROUPS_PER_RELAY'), 'PROGRAM_RELAY_MEM_GROUPS_PER_STAGE')
  const relayCountParameter = resolved(globalParameter(snapshot, 'PROGRAM_RELAY_COUNT', 'rtl/program_load/lpu_program_load_pkg.sv'), null, 'PROGRAM_RELAY_COUNT')
  const relayPortCountParameter = resolved(globalParameter(snapshot, 'PROGRAM_RELAY_PORT_COUNT', 'rtl/program_load/lpu_program_load_pkg.sv'), null, 'PROGRAM_RELAY_PORT_COUNT')
  const useSramMacro = resolved(useSramMacroParameter, null, 'USE_SRAM_MACRO')
  const qctl = resolved(qctlParameter, null, 'ENABLE_QCTL')
  const useNativeMem = resolved(useNativeMemParameter, null, 'USE_NATIVE_MEM')
  const memCount = Number.isFinite(hemispheres.value) ? hemispheres.value : null
  const sxmTotal = sxmCount.value
  const mxmTotal = mxmCount.value
  const vxmTotal = 1
  const columnsPerMem = memColumns.value
  const banksPerMem = multiply(columnsPerMem, banksPerColumn.value)
  const slicesPerMem = multiply(banksPerMem, tileRows.value)
  const wordWidthBits = Number.isFinite(lanesPerTile.value) ? lanesPerTile.value * 8 : null
  const macroWidthBits = 64
  const macroDepthRows = 2048
  const widthBanks = divideCeil(wordWidthBits, macroWidthBits)
  const depthBanks = divideCeil(depthRows.value, macroDepthRows)
  const macrosPerSlice = multiply(widthBanks, depthBanks)
  const mappedMacrosPerMem = multiply(slicesPerMem, macrosPerSlice)
  const mappedMacrosSystem = multiply(mappedMacrosPerMem, memCount)
  const macroSelectEnabled = useSramMacro.value === 1
  const macroDefineEnabled = (snapshot.configuration?.defines ?? []).some((item) => item === 'FTLPU_USE_SRAM64X2048_MACRO' || item.startsWith('FTLPU_USE_SRAM64X2048_MACRO='))
  const physicalMacroActive = macroSelectEnabled && macroDefineEnabled
  const activeDefines = snapshot.configuration?.defines ?? []
  const mxmDotRows = activeDefines.some((item) => item === 'FTLPU_DISABLE_BLOCK8' || item.startsWith('FTLPU_DISABLE_BLOCK8=')) ? 1 : 8
  const mxmAccumulatorMacroActive = activeDefines.some((item) => item === 'FTLPU_USE_SRAM128X512_MACRO' || item.startsWith('FTLPU_USE_SRAM128X512_MACRO='))
  const activePhysicalMacros = physicalMacroActive ? mappedMacrosSystem : 0
  const frontendCount = banksPerMem
  const localControlDomains = [memCount, mxmTotal, sxmTotal, vxmTotal].every(Number.isFinite)
    ? memCount + mxmTotal + sxmTotal + vxmTotal
    : null
  const memLocalIssuePathsSystem = multiply(memCount, frontendCount)
  const mxmLocalStreamsSystem = multiply(mxmTotal, 5)
  const confirmedLocalStreams = mxmLocalStreamsSystem
  const queueEntryBits = null
  const leafSramsPerBank = tileRows.value
  const leafSramsPerMem = multiply(banksPerMem, leafSramsPerBank)
  const leafSramsSystem = multiply(leafSramsPerMem, memCount)
  const memMappedStreamBoundaries = Number.isFinite(memGroups.value) ? memGroups.value + 1 : null
  const relayCountPerHemisphere = relayCountParameter.value ?? divideCeil(memGroups.value, relayGroupsPerStage.value)
  const relayTotalStages = relayPortCountParameter.value ?? multiply(hemispheres.value, relayCountPerHemisphere)
  const relayBanksPerGroup = multiply(columnsPerGroup.value, banksPerColumn.value)
  const relayStages = Array.from({ length: relayCountPerHemisphere ?? 0 }, (_, index) => {
    const groupStart = index * relayGroupsPerStage.value
    const groupEnd = Math.min(memGroups.value - 1, groupStart + relayGroupsPerStage.value - 1)
    const bankStart = groupStart * relayBanksPerGroup
    const bankEnd = (groupEnd + 1) * relayBanksPerGroup - 1
    return { index, groupStart, groupEnd, bankStart, bankEnd, bankCount: bankEnd - bankStart + 1 }
  })
  const streamColumnCountConflict = Number.isFinite(activeStreamColumns.value)
    && Number.isFinite(packageStreamColumns.value)
    && activeStreamColumns.value !== packageStreamColumns.value
  const streamRegisterStatus = streamColumnCountConflict ? 'needs-review' : 'rtl-confirmed'
  const streamRegisterMappingEvidence = source(
    'rtl/integration/lpu_mem_srf_integration.sv',
    103,
    'MEM boundary to SRF column mapping',
    'boundary b maps directly to sreg column b; MEM_BOUNDARIES <= 14 and active COLUMNS == 16',
    streamRegisterStatus,
  )

  const memEvidence = [memGroups.evidence, columnsPerGroup.evidence, memColumns.evidence, banksPerColumn.evidence, tileRows.evidence, depthRows.evidence, activeStreamColumns.evidence, packageStreamColumns.evidence]
  const macroEvidence = [
    useSramMacro.evidence,
    source('rtl/mem/lpu_mem_tile_slice_select.sv', 24, 'gen_sram', 'if (USE_SRAM_MACRO)'),
    source('rtl/mem/lpu_mem_tile_slice_sram.sv', 58, 'u_memory', 'WIDTH = LANES * 8, DEPTH = DEPTH_ROWS'),
    source('rtl/mem/lpu_sram_1rw_banked.sv', 18, 'WIDTH_BANKS', '(WIDTH + 64 - 1) / 64'),
    source('rtl/mem/lpu_sram_1rw_banked.sv', 19, 'DEPTH_BANKS', '(DEPTH + 2048 - 1) / 2048'),
    source('rtl/mem/lpu_sram_1rw_banked.sv', 75, 'FTLPU_USE_SRAM64X2048_MACRO', 'conditional physical sram_64_2048 instantiation', macroDefineEnabled ? 'rtl-confirmed' : 'needs-review'),
  ]

  const summary = [
    { id: 'hemisphere', label: 'Hemispheres', total: hemispheres.value, perHemisphere: 1, availability: 'Enabled', status: hemispheres.evidence.status, evidence: [hemispheres.evidence] },
    { id: 'mem', label: 'MEM', total: memCount, perHemisphere: 1, availability: 'Enabled', status: 'rtl-confirmed', evidence: [hemispheres.evidence] },
    { id: 'sxm', label: 'SXM Native Subsystem', total: sxmTotal, perHemisphere: Number.isFinite(sxmTotal) && Number.isFinite(hemispheres.value) ? sxmTotal / hemispheres.value : null, availability: 'Program + ROW integrated', status: 'rtl-confirmed', evidence: [sxmCount.evidence, source('rtl/core/lpu_fu_subsystem_cluster.sv', 455, 'u_sxm_subsystem', 'one native Program/ROW subsystem per Hemisphere'), source('rtl/sxm/lpu_sxm_native_subsystem.sv', 71, 'CTRL / EXEC calendars', 'two 64-event calendars per Hemisphere')] },
    { id: 'mxm', label: 'MXM', total: mxmTotal, perHemisphere: Number.isFinite(mxmTotal) && Number.isFinite(hemispheres.value) ? mxmTotal / hemispheres.value : null, availability: 'Enabled', status: mxmCount.evidence.status, evidence: [mxmCount.evidence] },
    { id: 'vxm', label: 'VXM', total: vxmTotal, perHemisphere: null, availability: 'Enabled', status: 'rtl-confirmed', evidence: [instanceSource(snapshot, 'lpu_fu_subsystem_cluster', 'u_vxm_subsystem', 'u_vxm_subsystem', 'single central VXM subsystem')] },
    { id: 'fu-control', label: 'FU-local Control Domains', total: localControlDomains, perHemisphere: null, availability: 'Distributed', status: 'architecture-inferred', evidence: [instanceSource(snapshot, 'lpu_fu_subsystem_cluster', 'gen_hemisphere', 'FU-local subsystem control', 'MEM, MXM and SXM are organized per hemisphere; VXM is a single central subsystem')] },
    { id: 'local-queue', label: 'MXM FU-local Stream Paths', total: confirmedLocalStreams, perHemisphere: Number.isFinite(confirmedLocalStreams) && Number.isFinite(hemispheres.value) ? confirmedLocalStreams / hemispheres.value : null, availability: '20 MXM streams · direct native-port issue', status: 'rtl-confirmed', evidence: [instanceSource(snapshot, 'lpu_mxm_subsystem', 'gen_frontend', 'five generated MXM local frontends', '5 per MXM'), source('rtl/mxm/icu/lpu_mxm_macro_frontend.sv', 1, 'lpu_mxm_macro_frontend', 'Macro Scheduler drives the native command ready/valid boundary directly; no post-Scheduler Instruction Queue')] },
    { id: 'mem-bank-queue', label: 'MEM Bank-local Direct Issue Paths', total: memLocalIssuePathsSystem, perHemisphere: banksPerMem, availability: 'Global 0..207 → local 0..103', status: 'rtl-confirmed', evidence: [memBankCount.evidence, source('rtl/mem/lpu_mem_subsystem.sv', 192, 'gen_bank_frontend[*].u_frontend', '104 bank-local Frontends per hemisphere; Scheduler outputs feed the lane adapter directly')] },
    { id: 'program-load-relay', label: 'Program Load Relay Stages', total: relayTotalStages, perHemisphere: relayCountPerHemisphere, availability: relayIntegrated ? 'Integrated' : 'Needs Review', status: relayIntegrated ? 'rtl-confirmed' : 'needs-review', evidence: [source(distributionNetworkDefinition?.file ?? 'rtl/program_load/lpu_program_distribute_system.sv', distributionNetworkDefinition?.instances?.find((item) => item.moduleName === 'lpu_program_distribute_relay_chain')?.line ?? 255, 'gen_relay_chain[0:1].u_program_relay_chain', 'Distribution System instantiates East + West chains and each chain generates seven Relay stages', relayIntegrated ? 'rtl-confirmed' : 'needs-review'), source('handoff/latest-rtl-change.md', 1, 'Relay-local Program Port handoff', '14 Distribution handshakes and one-Hemisphere seven-way iMEM writes verified', 'rtl-confirmed')] },
    { id: 'mem-local-program-port', label: 'MEM Local Program Ports', total: relayTotalStages, perHemisphere: relayCountPerHemisphere, availability: 'Independent Valid / Ready', status: relayIntegrated ? 'rtl-confirmed' : 'needs-review', evidence: [source('rtl/program_load/lpu_program_distribute_system.sv', 18, 'mem_program_*', 'PROGRAM_RELAY_PORT_COUNT independent MEM Program ports', relayIntegrated ? 'rtl-confirmed' : 'needs-review'), source('rtl/mem/lpu_mem_subsystem.sv', 23, 'program_valid_i / program_ready_o', 'PROGRAM_PORT_COUNT independent MEM Subsystem ports', relayIntegrated ? 'rtl-confirmed' : 'needs-review')] },
    { id: 'qctl', label: 'QCTL Formal Endpoints', total: qctlQueueCount.value, perHemisphere: null, availability: qctl.value === 1 ? 'Enabled' : 'RTL Integrated · Default Gated', status: 'rtl-confirmed', evidence: [qctl.evidence, qctlQueueCount.evidence, instanceSource(snapshot, 'lpu_fu_subsystem_cluster', 'u_qctl_global_subsystem', 'gen_qctl.u_qctl_global_subsystem', 'distributed QCTL store plus 228 FU-local endpoints')] },
    { id: 'qctl-relay-store', label: 'QCTL Regional Relay Stores', total: qctlRelayCount.value, perHemisphere: qctlRelayCountPerHemisphere.value, availability: 'East / West Distributed', status: 'rtl-confirmed', evidence: [qctlRelayCount.evidence, instanceSource(snapshot, 'lpu_qctl_global_subsystem', 'u_east_relay_chain', 'East / West QCTL Relay chains', 'two chains, seven regional stores per hemisphere')] },
  ]

  const compositions = [
    {
      id: 'mem', name: 'MEM', fu: 'mem', instanceCount: memCount, status: 'rtl-confirmed', evidence: memEvidence,
      units: [
        unit('mem-groups', 'Column Groups', 'group', 'structure', memGroups.value, memGroups.expression, memGroups.evidence),
        unit('mem-columns', 'Native Slices / MEM', 'slice', 'structure', columnsPerMem, memColumns.expression, memColumns.evidence),
        unit('mem-banks', 'Banks / MEM', 'bank', 'storage', banksPerMem, `${columnsPerMem} columns × ${banksPerColumn.value} banks`, banksPerColumn.evidence),
        unit('mem-slices', 'Native SRAM Leaves / MEM', 'sram-leaf', 'storage', leafSramsPerMem, `${columnsPerMem} slices × ${banksPerColumn.value} banks × ${leafSramsPerBank} superlanes`, source('rtl/mem_native/mem_slice.sv', 1, 'mem_slice', '2 independent banks × 4 superlane SRAM leaves')),
        unit('mem-local-issue-paths', 'Bank-local Macro Frontend + Direct Issue', 'frontend-direct-issue', 'control', frontendCount, 'ACTIVE_COLUMNS × BANKS; one Frontend and direct Scheduler issue path per logical Bank', source('rtl/mem/lpu_mem_subsystem.sv', 192, 'gen_bank_frontend[*]', 'u_frontend mem_issue_* feeds the matching adapter lane directly'), 'rtl-confirmed', 'Local iMEM, Macro Decoder, Context FIFO and Macro Scheduler form one bank-local instruction-supply path. The Scheduler directly emits MEM64 plus issue cycle; no independent Instruction Queue exists.'),
        unit('mem-native-adapters', 'MEM64 → Native32 Adapters', 'adapter', 'interface', frontendCount, 'one adapter per bank-local issue lane', source('rtl/integration/lpu_mem_srf_command_integration.sv', 1, 'lpu_mem_srf_command_integration', '104 lane adapters / MEM')),
        unit(
          'mem-stream-registers',
          'Active Stream Register Columns',
          'stream-register',
          'register',
          activeStreamColumns.value,
          activeStreamColumns.expression,
          activeStreamColumns.evidence,
          streamRegisterStatus,
          streamColumnCountConflict
            ? `Active SRF instantiates ${activeStreamColumns.value} columns; lpu_pkg names ${packageStreamColumns.value}. MEM boundaries 0..${(memMappedStreamBoundaries ?? 1) - 1} map directly, column 14 is the named MXM boundary, and the remaining active column stays Needs Review.`
            : 'Bidirectional registered Stream fabric columns.',
        ),
        unit('mem-execution', 'Native MEM Hemisphere', 'execution', 'compute', 1, 'USE_NATIVE_MEM default branch', instanceSource(snapshot, 'lpu_mem_subsystem', 'u_native_execution', 'u_native_execution', 'single native integration instance')),
      ],
    },
    {
      id: 'mxm', name: 'MXM', fu: 'mxm', instanceCount: mxmTotal, status: 'rtl-confirmed', evidence: [mxmCount.evidence],
      units: [
        unit('mxm-local-stream-paths', 'Five FU-local Macro Frontend Paths', 'frontend-direct-issue', 'control', 5, 'Load + Compute + Dequant + Param Load + Backend', source('rtl/mxm/lpu_mxm_subsystem.sv', 1, 'gen_frontend[0:4]', 'Five generated stream-local Frontends'), 'rtl-confirmed', 'Each stream owns local iMEM, Fetch, Word FIFO, an independent instance of the shared Decoder architecture, Context FIFO and stream-specific Scheduler.'),
        unit('mxm-shared-decoder', 'Shared 12-State Decoder Architecture', 'decoder', 'control', 1, 'one RTL architecture × five independent instances', source('rtl/mxm/icu/lpu_mxm_macro_decoder_core.sv', 1, 'lpu_mxm_macro_decoder_core', 'shared decoder implementation instantiated once per stream')),
        unit('mxm-qctl-gates', 'QCTL Endpoint Gates / MXM', 'qctl-gate', 'control', 5, 'one formal QCTL endpoint per stream', source('rtl/mxm/lpu_mxm_subsystem.sv', 1, 'gen_qctl_endpoint[0:4]', 'five generated QCTL endpoint/controller/counter paths')),
        unit('mxm-native-ports', 'Native Command Ports / MXM', 'native-port', 'interface', 5, 'Scheduler ready/valid directly drives the matching native port', source('rtl/mxm/lpu_mxm_subsystem.sv', 1, 'frontend_issue_*', 'no post-Scheduler Issue Queue and no Local Coordinator')),
        unit('mxm-control-wave', 'Four-row Execution Control Wave', 'control-wave', 'control', 4, 'Compute + Load + Param Load + Dequant', source('rtl/mxm/lpu_mxm_frontend.sv', 1, 'control streams', 'four execution-side command waves; Backend uses its native backend port')),
        unit('mxm-supercells', '4×4 Supercell Array', 'supercell', 'compute', 16, 'SC_ROWS × SC_COLS = 4 × 4', source('rtl/mxm/lpu_mxm_frontend.sv', 1, 'generated supercell array', 'sixteen current-core Supercells')),
        unit('mxm-dot-groups', 'BF16 Dot Groups / MXM', 'dot-group', 'compute', 128, '16 Supercells × 8 groups', source('rtl/mxm/lpu_mxm_supercell.sv', 1, 'g_output[0:7]', 'eight dot/partial groups per Supercell')),
        unit('mxm-multipliers', 'BF16 Multipliers / MXM', 'multiplier', 'compute', 1024, '16 Supercells × 8 groups × 8 multipliers', source('rtl/mxm/lpu_mxm_config_pkg.sv', 1, 'MULTIPLIER_COUNT', 'current parameterized Core multiplier count')),
        unit('mxm-backend-columns', 'Backend Columns', 'backend-column', 'compute', 4, 'SC_COLS = 4', source('rtl/mxm/lpu_mxm_backend.sv', 1, 'g_column[0:3]', 'four independent accumulator columns')),
        unit('mxm-backend-banks', 'Logical Accumulator Banks', 'accumulator-bank', 'storage', 8, '4 columns × 2 logical 1RW banks', source('rtl/mxm/lpu_mxm_backend_column.sv', 1, 'two banks per column', 'eight logical 512×256-bit banks')),
      ],
    },
    {
      id: 'sxm', name: 'SXM', fu: 'sxm', instanceCount: sxmTotal, status: 'rtl-confirmed', evidence: [sxmCount.evidence],
      units: [
        unit('sxm-native-subsystems', 'Native Program Subsystems', 'native-subsystem', 'control', 2, 'one per Hemisphere', source('rtl/core/lpu_fu_subsystem_cluster.sv', 455, 'gen_hemisphere[*].u_sxm_subsystem', 'formal lpu_sxm_native_subsystem instances')),
        unit('sxm-native-calendars', 'CTRL + EXEC Calendars / Hemisphere', 'instruction-calendar', 'control', 2, 'target 5 CTRL + target 6 EXEC', source('rtl/sxm/lpu_sxm_native_subsystem.sv', 71, 'u_ctrl_calendar / u_exec_calendar', 'two independent calendars per native subsystem')),
        unit('sxm-calendar-events', 'Events / Calendar', 'event-store', 'storage', 64, 'EVENT_DEPTH=64', source('rtl/sxm/lpu_sxm_native_subsystem.sv', 6, 'EVENT_DEPTH', 'each event stores 128-bit payload plus timing word')),
        unit('sxm-triangle-core', 'Native Triangle ROW Core', 'triangle-core', 'compute', 1, 'one full core per native subsystem', source('rtl/sxm/lpu_sxm_native_subsystem.sv', 141, 'u_execution', 'sxm_triangle_full_core owns ROW CAP/P/RUN')),
        unit('sxm-triangle-sources', 'Triangle ROW Sources', 'capture-source', 'structure', 4, 'T=4', source('rtl/sxm/lpu_sxm_native_subsystem.sv', 5, 'T', 'four source rows per Hemisphere')),
        unit('sxm-triangle-slots', 'Triangle Slots / Hemisphere', 'triangle-slot', 'storage', 10, '1+2+3+4, each 8×8×32 bit', source('rtl/sxm/sxm_triangle_row_frontend.sv', 1, 'sxm_triangle_row_frontend', 'left-aligned slot storage')),
        unit('sxm-stream-boundary', 'MEM ↔ SXM ↔ MXM Boundary', 'stream-boundary', 'interface', 1, 'bidirectional stream hop per Hemisphere', source('rtl/sxm/lpu_sxm_native_subsystem.sv', 115, 'u_stream_boundary', 'east/west streams enter and leave the native subsystem')),
        unit('sxm-batch-writetap', 'Separate Batch WriteTap Path', 'separate-path', 'interface', 1, 'not the formal Program endpoint', source('rtl/sxm/lpu_sxm_subsystem.sv', 1, 'lpu_sxm_subsystem', 'typed batch path remains independent')),
        unit('sxm-raw416', 'Independent Raw416 Compatibility', 'compatibility', 'control', 1, 'formal native Program ties raw input low', source('rtl/sxm/sxm_triangle_full_core.sv', 1, 'sxm_triangle_full_core', 'raw416 is core compatibility, not Program payload')),
        unit('sxm-vcs', 'Native SXM System Regression', 'verification', 'control', 2787, '5 scenarios · 2787 checks', source('handoff/history/20261125_193000_sxm_native_program.md', 1, 'final unified VCS regression', 'matrix/vector timing, early-P fault and Reset reload PASS')),
      ],
    },
    {
      id: 'vxm', name: 'VXM', fu: 'vxm', instanceCount: vxmTotal, status: 'rtl-confirmed', evidence: [instanceSource(snapshot, 'lpu_vxm_subsystem', 'u_execution', 'u_execution', 'single VXM slice')],
      units: [
        unit('vxm-control', 'Vector Control', 'control', 'control', 1, 'single lpu_vxm_control', instanceSource(snapshot, 'lpu_vxm_slice', 'u_control', 'u_control', 'single control instance')),
        unit('vxm-local-queues', 'Local Instruction Queues', 'local-queue', 'control', vxmLocalQueueCount.value, vxmLocalQueueCount.expression, vxmLocalQueueCount.evidence),
        unit('vxm-global-config', 'Global Configuration Channel', 'global-config', 'control', 1, 'one 15-bit global config channel', source('rtl/core/lpu_pkg.sv', 46, 'VXM_GLOBAL_CONFIG_WIDTH', '15-bit flow / chain / width / dtype configuration')),
        unit('vxm-control-waves', 'Four-row Control Waves', 'control-wave', 'register', 9, '8 local waves + 1 global wave; each has 4 rows', source('rtl/vxm/lpu_vxm_control.sv', 53, 'u_global_wave + gen_local_wave[0:7]', 'nine lpu_control_pipeline instances, ROWS = 4')),
        unit('vxm-stream-bridge', 'Two-hemisphere Stream Bridge', 'stream-bridge', 'interface', 1, '2 hemispheres × 4 tiles × 32 streams', instanceSource(snapshot, 'lpu_vxm_slice', 'u_stream_bridge', 'u_stream_bridge', 'one central direction-aware stream bridge')),
        unit('vxm-tiles', 'Vector Tiles', 'tile', 'compute', tileRows.value, 'TILES = 4', source('rtl/vxm/lpu_vxm_slice.sv', 39, 'TILES', 'localparam integer TILES = 4')),
        unit('vxm-lanes', 'Lanes / Tile', 'lane', 'compute', lanesPerTile.value, lanesPerTile.expression, lanesPerTile.evidence),
        unit('vxm-alus', 'ALU Stages / Lane', 'alu', 'compute', vxmAluCount.value, vxmAluCount.expression, vxmAluCount.evidence),
        unit('vxm-alu-cells', 'Lane-ALU Cells / VXM', 'alu-cell', 'compute', multiply(tileRows.value, lanesPerTile.value, vxmAluCount.value), `${tileRows.value} tiles × ${lanesPerTile.value} lanes × ${vxmAluCount.value} stages`, source('rtl/vxm/lpu_vxm_tile_execution.sv', 2, 'STAGES', 'VXM_ALU_COUNT')),
        unit('vxm-stream-blocks', 'Stream Blocks / Tile', 'stream-block', 'compute', divideCeil(vxmAluCount.value, 2), 'STAGES / 2', source('rtl/vxm/lpu_vxm_tile_execution.sv', 101, 'STREAM_BLOCKS', 'STAGES / 2')),
        unit('vxm-lut-functions', 'LUT Functions / Tile', 'lut-function', 'storage', 4, 'LUT_FUNCTIONS = 4', source('rtl/vxm/lpu_vxm_slice.sv', 44, 'LUT_FUNCTIONS', 'four independently addressed functions per tile')),
        unit('vxm-lut', 'Lane LUT SRAMs / VXM', 'lut-sram', 'storage', multiply(tileRows.value, 4, lanesPerTile.value), `${tileRows.value} tiles × 4 functions × ${lanesPerTile.value} lanes`, source('rtl/vxm/lpu_vxm_tile_lut.sv', 51, 'SRAM_COUNT', 'FUNCTION_COUNT * LANES')),
        unit('vxm-lut-entries', 'LUT Entries / VXM', 'lut-entry', 'storage', multiply(tileRows.value, 4, lanesPerTile.value, 64), `${tileRows.value} tiles × 4 functions × ${lanesPerTile.value} lanes × 64 entries`, source('rtl/vxm/lpu_vxm_lut_sram.sv', 7, 'ENTRY_COUNT', '64 entries per lane-local LUT SRAM')),
        unit('vxm-program-endpoint', 'Program Endpoint Adapter', 'missing-adapter', 'interface', null, 'Central boundary connected; resident-config adapter missing', source('rtl/vxm/lpu_vxm_subsystem.sv', 30, 'program_ready_o', "constant 1'b0; no Commit path", 'needs-review'), 'needs-review'),
      ],
    },
    {
      id: 'instruction', name: 'Distributed FU-local Instruction Control', fu: 'control', instanceCount: localControlDomains, status: 'architecture-inferred', evidence: [instanceSource(snapshot, 'lpu_mem_subsystem', 'u_frontend', 'MEM FU-local control', 'local iMEM frontend + macro decode + direct issue'), instanceSource(snapshot, 'lpu_mxm_subsystem', 'gen_frontend', 'MXM FU-local control', 'five local macro frontends + direct native-port issue')],
      units: [
        unit('distributed-mem-issue-paths', 'MEM Bank-local Frontend + Direct Issue Paths', 'frontend-direct-issue', 'control', memLocalIssuePathsSystem, `${memCount} MEM × ${frontendCount} bank-local paths`, source('rtl/mem/lpu_mem_subsystem.sv', 192, 'gen_bank_frontend[*]', '208 system-wide bank-local Scheduler-to-adapter lanes; no independent Instruction Queue')),
        unit('distributed-mxm-issue-paths', 'MXM Local Frontend + Direct Native Paths', 'frontend-direct-issue', 'control', mxmLocalStreamsSystem, `${mxmTotal} MXM × 5 stream-local paths`, source('rtl/mxm/lpu_mxm_subsystem.sv', 1, 'gen_frontend[0:4]', '20 system-wide MXM stream paths with no post-Scheduler queue')),
        unit('distributed-sxm-control', 'SXM Native Program / ROW', 'native-program', 'control', 2, 'one formal native subsystem per Hemisphere', source('rtl/core/lpu_fu_subsystem_cluster.sv', 455, 'u_sxm_subsystem', 'R6 Program target 5/6 reaches native CTRL/EXEC calendars'), 'rtl-confirmed', 'SXM QCTL endpoint is still absent; batch WriteTap is a separate path.'),
        unit('distributed-vxm-control', 'VXM Local Control Domain', 'local-control', 'control', vxmTotal, 'single central VXM subsystem', instanceSource(snapshot, 'lpu_vxm_subsystem', 'u_slice', 'VXM local/global issue control', 'Program Load closure remains VERIFY_REQUIRED'), 'needs-review', 'Program Load to local instruction storage is not confirmed in the current cluster routing.'),
        unit('distributed-qctl', 'QCTL Distributed Relay Store · 228', 'queue-control-system', 'control', qctlQueueCount.value, qctlQueueCount.expression, qctlQueueCount.evidence, 'rtl-confirmed', 'MEM 0..207 and five MXM stream classes 208..227 read their QCTL records from fourteen regional Relay stores. VXM and SXM have no formal QCTL Queue number or Controller chain in the current RTL.'),
      ],
    },
  ]

  const layoutByComposition = {
    mem: {
      tiers: [['mem-execution'], ['mem-slices'], ['mem-banks'], ['mem-columns'], ['mem-groups'], ['mem-native-adapters', 'mem-stream-registers'], ['mem-local-issue-paths']],
      links: [
        ['mem-groups', 'mem-columns', 'Group contains columns'],
        ['mem-columns', 'mem-banks', 'Column contains banks'],
        ['mem-banks', 'mem-slices', 'Bank contains superlane SRAM leaves'],
        ['mem-local-issue-paths', 'mem-native-adapters', 'South → North · 64-bit MEM machine code'],
        ['mem-native-adapters', 'mem-execution', 'Private 32-bit Native command'],
        ['mem-stream-registers', 'mem-execution', 'Stream ingress / egress'],
      ],
    },
    mxm: {
      tiers: [['mxm-local-stream-paths'], ['mxm-shared-decoder'], ['mxm-qctl-gates', 'mxm-native-ports'], ['mxm-control-wave'], ['mxm-supercells'], ['mxm-dot-groups', 'mxm-multipliers'], ['mxm-backend-columns', 'mxm-backend-banks']],
      links: [
        ['mxm-local-stream-paths', 'mxm-shared-decoder', 'five independent Decoder instances'],
        ['mxm-shared-decoder', 'mxm-qctl-gates', 'Context → stream Scheduler → QCTL gate'],
        ['mxm-qctl-gates', 'mxm-native-ports', 'direct ready / valid · no Issue Queue'],
        ['mxm-native-ports', 'mxm-control-wave', 'Load / Compute / Dequant / Param Load commands'],
        ['mxm-control-wave', 'mxm-supercells', 'fixed four-row execution waves'],
        ['mxm-supercells', 'mxm-dot-groups', '8 groups per Supercell'],
        ['mxm-dot-groups', 'mxm-backend-columns', 'static result return'],
      ],
    },
    sxm: {
      tiers: [['sxm-native-subsystems'], ['sxm-native-calendars', 'sxm-calendar-events'], ['sxm-triangle-core', 'sxm-stream-boundary'], ['sxm-triangle-sources', 'sxm-triangle-slots'], ['sxm-vcs'], ['sxm-batch-writetap', 'sxm-raw416']],
      links: [
        ['sxm-native-subsystems', 'sxm-native-calendars', 'Program target 5/6'],
        ['sxm-native-calendars', 'sxm-triangle-core', 'absolute-cycle CTRL/EXEC issue'],
        ['sxm-stream-boundary', 'sxm-triangle-core', 'ROW read / write'],
        ['sxm-triangle-core', 'sxm-triangle-slots', 'CAP → P → RUN'],
      ],
    },
    vxm: {
      tiers: [['vxm-program-endpoint'], ['vxm-local-queues', 'vxm-global-config'], ['vxm-control', 'vxm-control-waves'], ['vxm-stream-bridge'], ['vxm-tiles'], ['vxm-lanes', 'vxm-alus', 'vxm-stream-blocks'], ['vxm-alu-cells', 'vxm-lut-functions', 'vxm-lut', 'vxm-lut-entries']],
      links: [
        ['vxm-local-queues', 'vxm-control', '8 heterogeneous local instructions'],
        ['vxm-global-config', 'vxm-control', '15-bit global configuration'],
        ['vxm-control', 'vxm-control-waves', 'Registered four-row propagation'],
        ['vxm-control-waves', 'vxm-tiles', 'Configure then fixed execute pulse'],
        ['vxm-stream-bridge', 'vxm-tiles', 'Direction-selected stream ingress'],
        ['vxm-lut', 'vxm-tiles', 'Lane-local lookup response'],
        ['vxm-tiles', 'vxm-stream-bridge', 'Vector result egress'],
      ],
    },
    instruction: {
      tiers: [['distributed-mem-issue-paths', 'distributed-mxm-issue-paths'], ['distributed-sxm-control', 'distributed-vxm-control'], ['distributed-qctl']],
      links: [
        ['distributed-mem-issue-paths', 'distributed-qctl', 'Optional MEM lane map · 0..207'],
        ['distributed-mxm-issue-paths', 'distributed-qctl', 'Optional MXM lane map · 208..227'],
      ],
    },
  }
  for (const composition of compositions) {
    const layout = layoutByComposition[composition.id] ?? { tiers: [composition.units.map((item) => item.id)], links: [] }
    const tierMap = new Map(layout.tiers.flatMap((ids, tier) => ids.map((id) => [id, tier])))
    composition.units = composition.units.map((item) => ({ ...item, tier: tierMap.get(item.id) ?? 0 }))
    composition.links = layout.links.map(([sourceUnitId, targetUnitId, label], index) => {
      const statuses = [sourceUnitId, targetUnitId].map((id) => composition.units.find((item) => item.id === id)?.status)
      const status = statuses.includes('needs-review') ? 'needs-review' : statuses.includes('partially-verified') ? 'partially-verified' : 'rtl-confirmed'
      return { id: `${composition.id}:composition-link:${index}`, sourceUnitId, targetUnitId, label, status }
    })
  }

  const stage = (id, name, role, file, line, symbol, expression, status = 'rtl-confirmed') => ({
    id,
    name,
    role,
    status,
    specs: [],
    evidence: [source(file, line, symbol, expression, status)],
  })
  const frontends = [
    {
      id: 'mem',
      label: 'MEM Frontend',
      fu: 'mem',
      instanceCount: frontendCount,
      status: 'rtl-confirmed',
      integration: 'Integrated · one bank-local path per MEM Bank',
      summary: 'Program words are stored in a Bank-local iMEM, fetched into a Word FIFO, macro-decoded and scheduled. The Scheduler then drives MEM64 plus issue cycle directly into the matching adapter lane.',
      variants: [{
        id: 'mem-bank',
        name: 'Bank-local Macro Frontend',
        count: frontendCount,
        status: 'rtl-confirmed',
        stages: [
          stage('mem-imem', 'Local iMEM', 'FU-local program storage', 'rtl/mem/lpu_mem_local_imem_frontend.sv', 115, 'u_imem', 'lpu_mem_local_imem'),
          stage('mem-fetch', 'iMEM Fetch', 'Committed-word fetch and program counter', 'rtl/mem/lpu_mem_local_imem_frontend.sv', 140, 'u_fetch', 'lpu_mem_imem_fetch'),
          stage('mem-word-fifo', 'Word FIFO', 'Absorbs iMEM latency', 'rtl/mem/lpu_mem_macro_frontend.sv', 83, 'u_word_fifo', 'lpu_queue_fifo'),
          stage('mem-decoder', 'MEM Macro Decoder', '12-state architectural FSM · Queue-driven IDLE completion', 'rtl/mem/lpu_mem_macro_frontend.sv', 98, 'u_decoder', 'lpu_mem_macro_decoder'),
          stage('mem-context-fifo', 'Context FIFO', 'Decouples decode from admission', 'rtl/mem/lpu_mem_macro_frontend.sv', 130, 'u_context_fifo', 'lpu_queue_fifo'),
          stage('mem-scheduler', 'MEM Macro Scheduler', 'Expands Context and directly emits MEM64 plus issue cycle', 'rtl/mem/lpu_mem_macro_frontend.sv', 146, 'u_scheduler', 'lpu_mem_macro_scheduler'),
        ],
      }],
      evidence: [source('rtl/mem/lpu_mem_subsystem.sv', 192, 'gen_bank_frontend[*].u_frontend', 'one complete bank-local Frontend per logical MEM Bank'), source('rtl/mem/lpu_mem_local_imem_frontend.sv', 170, 'u_macro_frontend mem_issue_*', 'Macro Scheduler output is the terminal instruction-generation boundary and feeds the subsystem lane directly')],
    },
    {
      id: 'mxm',
      label: 'MXM Frontend',
      fu: 'mxm',
      instanceCount: 5,
      status: 'rtl-confirmed',
      integration: 'Integrated · Load / Compute / Dequant / Param Load / Backend',
      summary: 'Each MXM owns five independent FU-local program streams. Every stream instantiates the shared 12-state Decoder architecture and a stream-specific Scheduler; the Scheduler then drives its matching native command port directly through QCTL endpoint gating.',
      variants: [
        ['load', 'Load Frontend'],
        ['compute', 'Compute Frontend'],
        ['dequant', 'Dequant Frontend'],
        ['param-load', 'Param Load Frontend'],
        ['backend', 'Backend Frontend'],
      ].map(([id, name]) => ({
        id,
        name,
        count: 1,
        status: 'rtl-confirmed',
        stages: [
          stage(`${id}-imem`, 'Local iMEM', 'FU-local program storage', 'rtl/mxm/lpu_mxm_local_imem_frontend.sv', 122, 'u_imem', 'lpu_mxm_local_imem'),
          stage(`${id}-fetch`, 'iMEM Fetch', 'Committed-word fetch and program counter', 'rtl/mxm/lpu_mxm_local_imem_frontend.sv', 147, 'u_fetch', 'lpu_mxm_imem_fetch'),
          stage(`${id}-word-fifo`, 'Word FIFO', 'Buffers macro words', 'rtl/mxm/icu/lpu_mxm_macro_frontend.sv', 1, 'u_word_fifo', 'lpu_queue_fifo'),
          stage(`${id}-decoder`, 'MXM Shared Macro Decoder', 'Shared 12-state architecture · independent per-stream state', 'rtl/mxm/icu/lpu_mxm_macro_frontend.sv', 1, 'u_decoder', 'lpu_mxm_macro_decoder_core'),
          stage(`${id}-context-fifo`, 'Context FIFO', 'Buffers decoded Context', 'rtl/mxm/icu/lpu_mxm_macro_frontend.sv', 1, 'u_context_fifo', 'lpu_queue_fifo'),
          stage(`${id}-scheduler`, `${name.replace(' Frontend', '')} Scheduler`, 'Stream-specific Context expansion and direct native-port issue', 'rtl/mxm/icu/lpu_mxm_macro_frontend.sv', 1, 'u_scheduler', 'lpu_mxm_macro_scheduler_core'),
          stage(`${id}-qctl-gate`, 'QCTL Endpoint Gate', 'Per-stream Scheduler Cycle Counter enable', 'rtl/mxm/lpu_mxm_subsystem.sv', 1, 'gen_qctl_endpoint', 'lpu_qctl_endpoint + lpu_qctl_controller'),
          stage(`${id}-native-port`, `${name.replace(' Frontend', '')} Native Port`, 'Direct ready/valid handoff · no post-Scheduler queue', 'rtl/mxm/lpu_mxm_subsystem.sv', 1, 'frontend_issue_*', 'native command port'),
        ],
      })),
      evidence: [source('rtl/mxm/lpu_mxm_subsystem.sv', 1, 'gen_frontend[0:4]', 'five generated local iMEM frontends'), source('rtl/mxm/icu/lpu_mxm_macro_frontend.sv', 1, 'u_decoder / u_scheduler', 'shared Decoder architecture and stream-specific Scheduler with direct native issue')],
    },
    {
      id: 'sxm',
      label: 'SXM Native Program / ROW Integration',
      fu: 'sxm',
      instanceCount: 2,
      status: 'rtl-confirmed',
      integration: 'Integrated · two Hemisphere native Program endpoints',
      summary: 'Each Hemisphere owns target 5 CTRL and target 6 EXEC calendars. Absolute-cycle issue drives native ROW CAP/P/RUN; QCTL remains outside this SXM path.',
      variants: [{
        id: 'sxm-native',
        name: 'Native SXM Program Path',
        count: 2,
        status: 'rtl-confirmed',
        stages: [
          stage('sxm-program-native', 'R6 Outer Local Program Endpoint', 'Target 5 CTRL / target 6 EXEC · local index 0', 'rtl/core/lpu_fu_subsystem_cluster.sv', 455, 'u_sxm_subsystem', 'native Program port binding'),
          stage('sxm-native-calendar', 'CTRL + EXEC Calendars', 'Two 64-event tables per Hemisphere', 'rtl/sxm/lpu_sxm_native_subsystem.sv', 71, 'u_ctrl_calendar / u_exec_calendar', 'absolute-cycle issue'),
          stage('sxm-native-row', 'ROW CAP / P / RUN', 'One-stage P pipeline then finite RUN output', 'rtl/sxm/lpu_sxm_native_subsystem.sv', 141, 'u_execution', 'sxm_triangle_full_core'),
        ],
      }],
      evidence: [source('rtl/core/lpu_fu_subsystem_cluster.sv', 455, 'u_sxm_subsystem', 'formal native SXM instance per Hemisphere'), source('rtl/sxm/lpu_sxm_native_subsystem.sv', 71, 'u_ctrl_calendar / u_exec_calendar', 'native Program schedules CTRL and EXEC')],
    },
    {
      id: 'vxm',
      label: 'VXM Frontend',
      fu: 'vxm',
      instanceCount: null,
      status: 'needs-review',
      integration: 'RTL defined · resident-config / Execute endpoint not integrated',
      summary: 'The VXM macro frontend is defined as a queue-local packet/decode/schedule path, while the active VXM Subsystem keeps the Program endpoint unacknowledged.',
      variants: [{
        id: 'vxm-config',
        name: 'VXM Config Frontend',
        count: null,
        status: 'needs-review',
        stages: [
          stage('vxm-program-boundary', 'VXM Local Instruction Entry', 'Direct boundary connected; local load adapter not integrated', 'rtl/vxm/lpu_vxm_subsystem.sv', 5, 'Program Load boundary', 'resident-config/Execute endpoint is not implemented yet', 'needs-review'),
          stage('vxm-word-fifo', 'Word FIFO', 'Buffers RUN_2D packet words', 'rtl/vxm/lpu_vxm_macro_frontend.sv', 107, 'u_word_fifo', 'lpu_queue_fifo'),
          stage('vxm-decoder', 'VXM Macro Decoder', 'RUN_2D macro decode', 'rtl/vxm/lpu_vxm_macro_frontend.sv', 122, 'u_decoder', 'lpu_vxm_macro_decoder'),
          stage('vxm-context-fifo', 'Context FIFO', 'Buffers decoded Context', 'rtl/vxm/lpu_vxm_macro_frontend.sv', 152, 'u_context_fifo', 'lpu_queue_fifo'),
          stage('vxm-scheduler', 'VXM Macro Scheduler', 'Absolute-cycle Compact Config expansion', 'rtl/vxm/lpu_vxm_macro_frontend.sv', 167, 'u_scheduler', 'lpu_vxm_macro_scheduler'),
          stage('vxm-timed-queue', 'VXM Timed Issue Queue', 'Deadline-qualified Compact issue', 'rtl/vxm/lpu_vxm_macro_frontend.sv', 196, 'u_timed_issue_queue', 'lpu_vxm_timed_issue_queue'),
        ],
      }],
      evidence: [source('rtl/vxm/lpu_vxm_subsystem.sv', 5, 'VXM Program Load boundary', 'resident-config/Execute endpoint not implemented; request not acknowledged', 'needs-review'), source('rtl/vxm/lpu_vxm_macro_frontend.sv', 3, 'lpu_vxm_macro_frontend', 'defined standalone frontend')],
    },
  ]

  const spec = (label, value, status = 'rtl-confirmed') => ({ label, value, status })
  const frontendStageSpecs = new Map()
  const setSpecs = (id, items) => frontendStageSpecs.set(id, items)

  setSpecs('mem-imem', [spec('Program words', '131,072'), spec('Word width', '96 bit'), spec('Address width', '17 bit'), spec('Response buffering', '4 entries')])
  setSpecs('mem-fetch', [spec('Fetch range', '131,072 words'), spec('Word width', '96 bit'), spec('Ordering', 'In order'), spec('Completion', 'Last-word tagged')])
  setSpecs('mem-word-fifo', [spec('Depth', '4 entries'), spec('Entry width', '97 bit'), spec('Contents', '96-bit macro word + last')])
  setSpecs('mem-decoder', [
    spec('Input', '96-bit packed-v1 macro word'),
    spec('Output', '271-bit Context'),
    spec('Controller', 'Architectural FSM · 12 RTL states'),
    spec('Control[0]', 'Valid = 1'),
    spec('Completion', 'IDLE / IDLE_GLOBAL with zero Macro count'),
    spec('Control[3:2]', "Mode = 2'b01"),
    spec('Control[27:4]', 'Command Count · 24 bit'),
    spec('Context Valid', 'OUTPUT_CONTEXT until handshake'),
  ])
  setSpecs('mem-context-fifo', [spec('Depth', '4 entries'), spec('Entry width', '271 bit'), spec('Contents', 'Decoded MEM Context')])
  setSpecs('mem-scheduler', [spec('Active contexts', '4'), spec('Issue lookahead', '2 cycles'), spec('Independent issue queue', 'None'), spec('Output instruction', '64 bit'), spec('Output cycle', '32 bit')])

  const mxmContextWidth = 288
  for (const id of ['load', 'compute', 'dequant', 'param-load', 'backend']) {
    setSpecs(`${id}-imem`, [spec('Program words', '65,536'), spec('Word width', '128 bit'), spec('Address width', '16 bit'), spec('Response buffering', '4 entries')])
    setSpecs(`${id}-fetch`, [spec('Fetch range', '65,536 words'), spec('Word width', '128 bit'), spec('Ordering', 'In order'), spec('Completion', 'Last-word tagged')])
    setSpecs(`${id}-word-fifo`, [spec('Depth', '4 entries'), spec('Entry width', '129 bit'), spec('Contents', '128-bit macro word + last')])
    setSpecs(`${id}-decoder`, [spec('Input', '128-bit macro word'), spec('Output', `${mxmContextWidth}-bit Context`), spec('Architecture', 'Shared 12-state FSM'), spec('Instance state', 'Independent per stream')])
    setSpecs(`${id}-context-fifo`, [spec('Depth', '4 entries'), spec('Entry width', `${mxmContextWidth} bit`), spec('Contents', 'Decoded MXM Context')])
    setSpecs(`${id}-scheduler`, [spec('Active contexts', '4'), spec('Issue lookahead', '2 cycles'), spec('Post-Scheduler queue', 'None'), spec('Output instruction', '49 bit')])
    setSpecs(`${id}-qctl-gate`, [spec('Endpoint', 'One formal QCTL endpoint'), spec('Counter control', 'scheduler_counter_ce'), spec('Queue index', '5-bit local directory')])
    setSpecs(`${id}-native-port`, [spec('Handshake', 'ready / valid'), spec('Issue ownership', 'Scheduler direct'), spec('Post-Scheduler queue', 'None')])
  }

  setSpecs('sxm-program-native', [spec('Endpoint', 'Integrated'), spec('Target kinds', '5 CTRL · 6 EXEC'), spec('Local index', '0')])
  setSpecs('sxm-native-calendar', [spec('Calendars / Hemisphere', '2'), spec('Events / calendar', '64'), spec('Issue', 'absolute schedule cycle')])
  setSpecs('sxm-native-row', [spec('ROW phases', 'CAP → P → RUN'), spec('P pipeline', '1 stage'), spec('Triangle slots', '10 / Hemisphere')])

  setSpecs('vxm-program-boundary', [spec('Endpoint', 'Not integrated', 'needs-review'), spec('Program acceptance', 'Disabled', 'needs-review')])
  setSpecs('vxm-word-fifo', [spec('Depth', '4 entries'), spec('Entry width', '97 bit'), spec('Contents', '96-bit RUN_2D word + last')])
  setSpecs('vxm-decoder', [spec('Input', '96-bit macro word'), spec('Output', '288-bit Context'), spec('Local queue', '0')])
  setSpecs('vxm-context-fifo', [spec('Depth', '2 entries'), spec('Entry width', '288 bit'), spec('Contents', 'Decoded VXM Context')])
  setSpecs('vxm-scheduler', [spec('Active contexts', '1'), spec('Issue lookahead', '2 cycles'), spec('Internal issue FIFO', 'None · queue is the register boundary'), spec('Output instruction', '128 bit'), spec('Timing', 'Absolute-cycle expansion')])
  setSpecs('vxm-timed-queue', [spec('Depth', '4 entries'), spec('Entry width', '128 bit'), spec('Contents', 'Compact timed issue record')])

  const specValue = (item, label, fallback) => item.specs.find((entry) => entry.label === label)?.value ?? fallback
  const decoderPipeline = (frontend, variant, item) => {
    const compressedStream = frontend.id === 'mem' || frontend.id === 'mxm'
    const input = specValue(item, 'Input', 'Macro word stream')
    const output = specValue(item, 'Output', 'Decoded Context')
    if (frontend.id === 'mem' || frontend.id === 'mxm') return {
      kind: 'decoder',
      visualization: 'state-machine',
      title: frontend.id === 'mem' ? 'MEM Macro Decoder 状态转移图' : 'MXM Shared Macro Decoder · 12-State FSM',
      stateBadge: frontend.id === 'mem' ? '12 RTL STATES · CURRENT LOCAL RTL' : '1 SHARED ARCHITECTURE · 5 INDEPENDENT INSTANCES',
      summary: frontend.id === 'mem' ? '首个 Macro 先完成全局控制、字典和初始状态装载；后续 Macro 在 Run、Template、Delta 与 Context 输出之间循环。' : `五条 MXM 流复用同一个 12 状态 Decoder RTL 架构；当前 ${variant.name} 拥有独立的状态寄存器、字典和 Macro 计数。`,
      inputLabel: `${input} · ready/valid from Word FIFO · bit zero consumed first`,
      outputLabel: `${output} · ready/valid to Context FIFO`,
      timingNote: '图中重复的 Run、Template、Output 框是同一 RTL 状态在首个 Macro 与后续循环中的路径视图；Queue Macro 计数清零后，IDLE 自循环并令 done_o=1。',
      steps: [
        { id: 'idle-global', name: 'IDLE_GLOBAL', description: '等待并检查全局控制字。', boundary: 'IDLE_GLOBAL', tone: 'idle', rtlStates: ['IDLE_GLOBAL'], position: { x: 520, y: 40, width: 230, height: 100 } },
        { id: 'fault-global', name: 'FAULT', description: '控制字非法；错误保持至复位。', boundary: 'FAULT', tone: 'fault', rtlStates: ['FAULT'], position: { x: 870, y: 40, width: 210, height: 100 } },
        { id: 'dict-store', name: 'DICT_STORE', description: '装载 Delta 字典数量与条目。', boundary: 'DICT_STORE', tone: 'dictionary', rtlStates: ['DICT_STORE'], position: { x: 520, y: 180, width: 230, height: 100 } },
        { id: 'init-global', name: 'INIT_GLOBAL', description: '建立首个绝对周期与地址。', boundary: 'INIT_GLOBAL', tone: 'main', rtlStates: ['INIT_GLOBAL'], position: { x: 520, y: 320, width: 230, height: 100 } },
        { id: 'run-header-first', name: 'RUN_HEADER', description: '解析首个 Run 的标志与长度。', boundary: 'RUN_HEADER', tone: 'main', rtlStates: ['RUN_HEADER'], position: { x: 520, y: 460, width: 230, height: 100 } },
        { id: 'template-first', name: 'TEMPLATE', description: '解析并校验首个指令模板。', boundary: 'TEMPLATE', tone: 'main', rtlStates: ['TEMPLATE'], position: { x: 520, y: 600, width: 230, height: 100 } },
        { id: 'output-first', name: 'OUTPUT_CONTEXT', description: '输出首个 Macro 的 Context。', boundary: 'OUTPUT_CONTEXT', tone: 'main', rtlStates: ['OUTPUT_CONTEXT'], position: { x: 520, y: 740, width: 230, height: 100 } },
        { id: 'fault-runtime', name: 'FAULT', description: '解析非法或输入截断；保持至复位。', boundary: 'FAULT', tone: 'fault', rtlStates: ['FAULT'], position: { x: 40, y: 900, width: 210, height: 100 } },
        { id: 'idle', name: 'IDLE', description: 'Run 边界；Queue 空时保持并置 done_o。', boundary: 'IDLE', tone: 'idle', rtlStates: ['IDLE'], position: { x: 330, y: 900, width: 230, height: 100 } },
        { id: 'run-header-next', name: 'RUN_HEADER', description: 'Queue 非空时解析下一 Run。', boundary: 'RUN_HEADER', tone: 'main', rtlStates: ['RUN_HEADER'], position: { x: 650, y: 900, width: 230, height: 100 } },
        { id: 'template-next', name: 'TEMPLATE', description: '解析后续 Macro 的模板。', boundary: 'TEMPLATE', tone: 'main', rtlStates: ['TEMPLATE'], position: { x: 970, y: 900, width: 230, height: 100 } },
        { id: 'get-delta', name: 'GET_DELTA', description: '解析 Delta 前缀并选择来源。', boundary: 'GET_DELTA', tone: 'main', rtlStates: ['GET_DELTA'], position: { x: 1290, y: 900, width: 230, height: 100 } },
        { id: 'escape', name: 'ESCAPE', description: '读取 Compact 或 Wide Delta。', boundary: 'ESCAPE', tone: 'escape', rtlStates: ['ESCAPE'], position: { x: 1600, y: 740, width: 230, height: 100 } },
        { id: 'dict-lookup', name: 'DICT_LOOKUP', description: '按 Symbol 读取已装载 Delta。', boundary: 'DICT_LOOKUP', tone: 'dictionary', rtlStates: ['DICT_LOOKUP'], position: { x: 1600, y: 1040, width: 230, height: 100 } },
        { id: 'apply-delta', name: 'APPLY_DELTA', description: '累加周期和地址并生成 Context。', boundary: 'APPLY_DELTA', tone: 'main', rtlStates: ['APPLY_DELTA'], position: { x: 1920, y: 900, width: 230, height: 100 } },
        { id: 'output-loop', name: 'OUTPUT_CONTEXT', description: '保持有效 Context，等待下游握手。', boundary: 'OUTPUT_CONTEXT', tone: 'main', rtlStates: ['OUTPUT_CONTEXT'], position: { x: 2250, y: 900, width: 230, height: 100 } },
      ],
      transitions: [
        { id: 'global-wait', source: 'idle-global', target: 'idle-global', label: '等待控制字 / Macro 数为 0', sourceHandle: 'top-source', targetHandle: 'top-target', tone: 'loop', offset: 48 },
        { id: 'global-fault', source: 'idle-global', target: 'fault-global', label: '控制字非法', sourceHandle: 'right-source', targetHandle: 'left-target', tone: 'fault' },
        { id: 'global-dict', source: 'idle-global', target: 'dict-store', label: '控制合法 · Macro 数 > 0', sourceHandle: 'bottom-source-center', targetHandle: 'top-target-center' },
        { id: 'dict-init', source: 'dict-store', target: 'init-global', label: '无需字典 / 装载完成', sourceHandle: 'bottom-source-center', targetHandle: 'top-target-center', tone: 'dictionary' },
        { id: 'init-run-first', source: 'init-global', target: 'run-header-first', label: '初始字段完整', sourceHandle: 'bottom-source-center', targetHandle: 'top-target-center' },
        { id: 'run-template-first', source: 'run-header-first', target: 'template-first', label: 'Run 长度合法', sourceHandle: 'bottom-source-center', targetHandle: 'top-target-center' },
        { id: 'template-output-first', source: 'template-first', target: 'output-first', label: '首个 Macro · 校验通过', sourceHandle: 'bottom-source-center', targetHandle: 'top-target-center' },
        { id: 'first-output-delta', source: 'output-first', target: 'get-delta', label: '握手完成 · Run 中仍有 Macro', sourceHandle: 'right-source', targetHandle: 'top-target-center', tone: 'loop', offset: 54 },
        { id: 'first-output-idle', source: 'output-first', target: 'idle', label: '首个 Run 结束', sourceHandle: 'left-source', targetHandle: 'top-target-center', tone: 'loop', offset: 60 },
        { id: 'runtime-fault-summary', source: 'idle', target: 'fault-runtime', label: '解析非法 / 输入截断（汇总）', sourceHandle: 'top-source', targetHandle: 'top-target', tone: 'fault', offset: 34 },
        { id: 'idle-complete', source: 'idle', target: 'idle', label: 'Queue Macro 数 = 0 · done_o = 1', sourceHandle: 'bottom-source-right', targetHandle: 'bottom-target', tone: 'loop', offset: 54 },
        { id: 'idle-next-run', source: 'idle', target: 'run-header-next', label: 'Queue 中仍有 Macro', sourceHandle: 'top-source', targetHandle: 'top-target', offset: 30 },
        { id: 'run-template-next', source: 'run-header-next', target: 'template-next', label: 'Run 长度合法', sourceHandle: 'top-source', targetHandle: 'top-target', offset: 30 },
        { id: 'template-delta-next', source: 'template-next', target: 'get-delta', label: '后续 Macro · 校验通过', sourceHandle: 'top-source', targetHandle: 'top-target', offset: 30 },
        { id: 'delta-escape', source: 'get-delta', target: 'escape', label: 'Escape Symbol', sourceHandle: 'top-source', targetHandle: 'left-target', tone: 'escape' },
        { id: 'delta-dictionary', source: 'get-delta', target: 'dict-lookup', label: '匹配字典条目', sourceHandle: 'bottom-source-right', targetHandle: 'left-target', tone: 'dictionary' },
        { id: 'escape-apply', source: 'escape', target: 'apply-delta', label: 'Payload 完整', sourceHandle: 'right-source', targetHandle: 'top-target-center', tone: 'escape' },
        { id: 'dictionary-apply', source: 'dict-lookup', target: 'apply-delta', label: '取得 Delta', sourceHandle: 'right-source', targetHandle: 'bottom-target', tone: 'dictionary' },
        { id: 'apply-output', source: 'apply-delta', target: 'output-loop', label: '累加结果有效', sourceHandle: 'right-source', targetHandle: 'left-target' },
        { id: 'output-wait', source: 'output-loop', target: 'output-loop', label: '等待下游 Ready', sourceHandle: 'top-source', targetHandle: 'top-target', tone: 'loop', offset: 46 },
        { id: 'output-delta', source: 'output-loop', target: 'get-delta', label: '握手完成 · Run 中仍有 Macro', sourceHandle: 'bottom-source-left', targetHandle: 'bottom-target', tone: 'loop', offset: 170 },
        { id: 'output-idle', source: 'output-loop', target: 'idle', label: '握手完成 · Run 结束', sourceHandle: 'bottom-source-right', targetHandle: 'bottom-target', tone: 'loop', offset: 245 },
      ],
    }
    return {
      kind: 'decoder',
      title: `${item.name} · ${compressedStream ? 'Decompression' : 'Packet Decode'} Pipeline`,
      summary: compressedStream
        ? 'Macro words are consumed by a state-machine parser. A cross-word reservoir, dictionary/template decode and delta reconstruction produce one normalized scheduling Context.'
        : 'RUN_2D packet words are collected, reordered into one logical payload, validated and converted into one normalized scheduling Context.',
      inputLabel: `${input} · ready/valid from Word FIFO`,
      outputLabel: `${output} · ready/valid to Context FIFO`,
      timingNote: compressedStream
        ? 'Functional processing pipeline: the boxes are parser phases, not fixed one-cycle stages. The RTL uses an FSM plus a registered Context output that remains stable under backpressure.'
        : 'Functional processing pipeline: packet collection and decode_pending are registered phases; the Context output remains stable until the Context FIFO accepts it.',
      steps: compressedStream ? [
        { id: 'word-intake', name: 'Word Intake + Bit Reservoir', description: `Accept ${input} words and append them to the cross-word bit reservoir.`, boundary: 'READY / VALID · WORD_LAST' },
        { id: 'control-dictionary', name: 'Control + Delta Dictionary', description: 'Decode command count, initial state and up to seven reusable start/operand delta entries.', boundary: 'FSM · CONTROL / DICTIONARY' },
        { id: 'template-decompress', name: 'Run + Template Decompress', description: 'Expand Run length and compact/extended Template fields into native instruction and two-level loop schedule.', boundary: 'FSM · RUN / TEMPLATE' },
        { id: 'delta-normalize', name: 'Delta Apply + Normalize', description: 'Reconstruct absolute start cycle and induced operand/address, then validate target and schedule legality.', boundary: 'FSM · DELTA / VALIDATE' },
        { id: 'context-output', name: 'Registered Context Output', description: `Pack instruction, timing, count, interval, stride and target fields into ${output}.`, boundary: '1-ENTRY HOLD · BACKPRESSURE SAFE' },
      ] : [
        { id: 'word-intake', name: 'Packet Word Intake', description: `Accept ${input} words from the frontend Word FIFO.`, boundary: 'READY / VALID · WORD_LAST' },
        { id: 'packet-assembly', name: 'Logical Packet Assembly', description: 'Collect the multi-word RUN_2D packet and close physical header/subtype gaps into one logical payload.', boundary: 'REGISTERED WORD COLLECTION' },
        { id: 'header-validation', name: 'Header + Reserved Validation', description: 'Check opcode/subtype, required word count and reserved fields before any Context is exposed.', boundary: 'DECODE_PENDING · FAULT CHECK' },
        { id: 'context-decode', name: 'Schedule + Instruction Decode', description: 'Extract base/wait cycle, inner/outer loop fields and the FU-specific base instruction.', boundary: 'COMBINATIONAL FIELD DECODE' },
        { id: 'context-output', name: 'Registered Context Output', description: `Hold the complete ${output} stable until the Context FIFO accepts it.`, boundary: '1-ENTRY HOLD · BACKPRESSURE SAFE' },
      ],
    }
  }
  const schedulerPipeline = (variant, item, stageIndex) => {
    const contextStage = variant.stages[stageIndex - 1]
    const queueStage = variant.stages[stageIndex + 1]
    const contextWidth = contextStage ? specValue(contextStage, 'Entry width', 'Context') : 'Context'
    const activeContexts = specValue(item, 'Active contexts', '1')
    const outputInstruction = specValue(item, 'Output instruction', 'Base instruction')
    const queueName = queueStage?.name ?? 'FU-local Instruction Queue'
    const directNativeIssue = ['load-scheduler', 'compute-scheduler', 'dequant-scheduler', 'param-load-scheduler', 'backend-scheduler'].includes(item.id)
    const directContextAdmission = item.id === 'mem-scheduler' || directNativeIssue
    const hasOuterSpatialTransition = ['mem-scheduler', 'load-scheduler', 'compute-scheduler'].includes(item.id)
    const outerTransitionNote = hasOuterSpatialTransition
      ? 'outer_cycle_transition advances from the previous row final issue to the next row first issue; outer_spatial_transition applies the matching address or operand transition.'
      : 'outer_cycle_transition advances from the previous row final issue to the next row first issue.'
    return {
      kind: 'scheduler',
      title: `${item.name} · Context Expansion Pipeline`,
      summary: directContextAdmission
        ? `${directNativeIssue ? 'The MXM stream Scheduler' : 'The MEM Scheduler'} validates and converts the Context FIFO head, admits it directly into an originally free Active Context slot, then selects work ahead of the absolute issue cycle and directly emits one ${directNativeIssue ? 'native MXM command' : 'MEM64 instruction'} plus issue cycle. ${outerTransitionNote}`
        : `The Scheduler captures and admits a decoded Context through distinct ownership boundaries, retains its loop/timing state, selects work ahead of the absolute issue cycle and emits one FU base instruction into the paired Instruction Queue. ${outerTransitionNote}`,
      inputLabel: `${contextWidth} Context · ready/valid from Context FIFO`,
      outputLabel: directContextAdmission
        ? `${outputInstruction} instruction + 32-bit issue cycle → ${directNativeIssue ? `${variant.name.replace(' Frontend', '')} native command port through QCTL gating` : 'MEM64 / Native32 adapter'}`
        : `${outputInstruction} instruction + 32-bit issue cycle → ${queueName}`,
      timingNote: directContextAdmission
        ? `Registered ownership boundaries are the upstream Context FIFO and Active Context state. The ${directNativeIssue ? 'MXM stream' : 'MEM'} Scheduler has no second ingress register and no independent post-Scheduler output queue: context_admit_fire is the direct Context FIFO handshake into an originally free Active Context slot. Active Context advances only on schedule_select_fire, when the downstream ${directNativeIssue ? 'native command port' : 'adapter'} accepts the issue handshake. ${outerTransitionNote}`
        : `Registered ownership boundaries are Context ingress, Active Context state and the FU-local Instruction Queue. context_capture_fire captures Context FIFO data; context_admit_fire moves the ingress record into a slot that was already free before the current edge. Active Context advances only on schedule_select_fire, when the queue accepts the generated instruction. ${outerTransitionNote}`,
      steps: directContextAdmission ? [
        { id: 'context-fifo-head', name: 'Context FIFO Head', description: 'Observe the current Context FIFO output fields directly; the FIFO retains the head while context_ready_o is low.', boundary: 'UPSTREAM FIFO STORAGE · READY / VALID' },
        { id: 'validate-convert', name: 'Validation + Conversion', description: 'Check target, native instruction, loop counts, intervals, strides, address range and absolute deadline while deriving the Active Context schedule state directly from context_*_i.', boundary: 'COMBINATIONAL · FAULT ARBITRATION' },
        { id: 'direct-admit', name: 'Direct Active Context Admission', description: 'context_admit_fire writes the validated and converted Context directly into the first originally free Active Context slot.', boundary: 'context_admit_fire · FREE SLOT' },
        { id: 'active-context', name: 'Active Context State', description: `Store up to ${activeContexts} active Context${activeContexts === '1' ? '' : 's'} with remaining loop counts, next issue cycle and normalized outer transition state.`, boundary: hasOuterSpatialTransition ? 'outer_cycle_transition · outer_spatial_transition' : 'outer_cycle_transition' },
        { id: 'lookahead-select', name: 'Lookahead Due Select', description: 'Compare next-issue cycles against schedule_cycle + 2 and detect conflicts, missed generation or overflow.', boundary: 'ISSUE_LOOKAHEAD = 2' },
        { id: 'instruction-generate', name: 'Base Instruction Generate', description: `Apply the current induced address or operand and form the ${outputInstruction} ${directNativeIssue ? 'MXM native command' : 'MEM instruction'}.`, boundary: 'INSTRUCTION + ABSOLUTE CYCLE' },
        { id: 'direct-issue', name: directNativeIssue ? 'Direct Native-Port Issue' : 'Direct MEM64 Issue', description: directNativeIssue ? 'schedule_select_fire transfers the generated command directly through QCTL endpoint gating to the matching MXM native ready/valid port; no Instruction Queue or Local Coordinator exists after the Scheduler.' : 'schedule_select_fire transfers mem_issue_instruction_o and mem_issue_cycle_o directly through the ready/valid boundary to the matching MEM64 / Native32 adapter lane; only this accepted handshake advances or retires the Context.', boundary: directNativeIssue ? 'native_valid / ready · QCTL CE · schedule_select_fire' : 'mem_issue_valid / ready · schedule_select_fire' },
      ] : [
        { id: 'context-ingress', name: 'Context Ingress Register', description: 'context_capture_fire captures one Context through ready/valid without exposing Active Context storage latency upstream.', boundary: 'context_capture_fire · BACKPRESSURE SAFE' },
        { id: 'validate-admit', name: 'Validate + Admit', description: 'context_admit_fire checks target, instruction, loop counts, transitions and deadline lead time, then writes only a slot that was already free before the current edge.', boundary: 'context_admit_fire · PRE-EDGE FREE SLOT' },
        { id: 'active-context', name: 'Active Context State', description: `Store up to ${activeContexts} active Context${activeContexts === '1' ? '' : 's'} with remaining loop counts, next issue cycle and normalized outer transition state.`, boundary: hasOuterSpatialTransition ? 'outer_cycle_transition · outer_spatial_transition' : 'outer_cycle_transition' },
        { id: 'lookahead-select', name: 'Lookahead Due Select', description: 'Compare next-issue cycles against schedule_cycle + 2 and detect conflicts, missed generation or overflow.', boundary: 'ISSUE_LOOKAHEAD = 2' },
        { id: 'instruction-generate', name: 'Base Instruction Generate', description: `Apply the current induced operand/address and form the ${outputInstruction} FU instruction.`, boundary: 'INSTRUCTION + ABSOLUTE CYCLE' },
        { id: 'queue-handoff', name: 'Instruction Queue Handoff', description: `schedule_select_fire transfers the timed instruction to ${queueName}; only this accepted handshake advances or retires the Context.`, boundary: 'schedule_select_fire · ISSUE VALID / READY' },
      ],
    }
  }

  for (const frontend of frontends) for (const variant of frontend.variants) for (const [stageIndex, item] of variant.stages.entries()) {
    item.specs = frontendStageSpecs.get(item.id) ?? []
    if (item.id.endsWith('-decoder')) item.pipeline = decoderPipeline(frontend, variant, item)
    if (item.id.endsWith('-scheduler')) item.pipeline = schedulerPipeline(variant, item, stageIndex)
  }

  const programLoad = {
    controlDomain: {
      widthBits: 1,
      values: ['WRITE', 'PRIME'],
      relationship: 'Separate encoding domain from FU instruction opcodes',
      status: 'rtl-confirmed',
      evidence: [source('rtl/program_load/lpu_program_load_pkg.sv', 62, 'lpu_program_load_control_e', 'PROGRAM_LOAD_CONTROL_WIDTH=1; WRITE=0 / PRIME=1')],
    },
    wordTransport: {
      dataBits: 128,
      strobeBits: 4,
      bitsPerStrobe: 32,
      addressBits: 17,
      scopeBits: 2,
      destinationBits: 13,
      sequenceIdPresent: false,
      status: 'rtl-confirmed',
      evidence: [
        source('rtl/program_load/lpu_program_load_pkg.sv', 11, 'PROGRAM_WORD_STRB_WIDTH', '4 strobes × 32-bit segments'),
        source('rtl/program_load/lpu_program_word_fifo.sv', 11, 'enqueue_scope_i / enqueue_destination_i', '2-bit Scope + 13-bit Destination travel with every Program Word; no Sequence ID field'),
      ],
    },
    routing: {
      scope: {
        widthBits: 2,
        values: [
          { name: 'EAST', encoding: 0, meaning: 'Send to the concrete East endpoint.' },
          { name: 'WEST', encoding: 1, meaning: 'Send to the concrete West endpoint.' },
          { name: 'BOTH', encoding: 2, meaning: 'Distributor expands one record into independent East and West handshakes.' },
        ],
        relationship: 'Scope controls fanout. It is not part of the 13-bit Destination and is not an FU instruction field.',
        status: 'rtl-confirmed',
        evidence: [source('rtl/program_load/lpu_program_load_pkg.sv', 30, 'lpu_program_hemisphere_scope_e', 'PROGRAM_SCOPE_EAST=0, WEST=1, BOTH=2')],
      },
      destination: {
        widthBits: 13,
        fields: [
          { name: 'Hemisphere', bits: '12', widthBits: 1, meaning: 'Concrete endpoint: East=0, West=1.' },
          { name: 'Target Kind', bits: '11:8', widthBits: 4, meaning: 'MEM, five MXM stream classes, VXM or legacy-reserved SXM kinds.' },
          { name: 'Local Target Index', bits: '7:0', widthBits: 8, meaning: 'Index is local to the selected Hemisphere and Kind.' },
        ],
        relationship: 'Destination names exactly one physical target: {hemisphere[12], kind[11:8], local_target_index[7:0]}.',
        status: 'rtl-confirmed',
        evidence: [source('rtl/program_load/lpu_program_load_pkg.sv', 6, 'PROGRAM_DESTINATION_*', '13-bit Destination field boundaries, 4-bit Target Kind and program_destination_pack()')],
      },
      kinds: [
        { name: 'MEM', encoding: 0, status: 'rtl-confirmed' },
        { name: 'MXM_LOAD', encoding: 1, status: 'rtl-confirmed' },
        { name: 'MXM_DEQUANT', encoding: 2, status: 'rtl-confirmed' },
        { name: 'MXM_COMPUTE', encoding: 3, status: 'rtl-confirmed' },
        { name: 'VXM', encoding: 4, status: vxmBoundaryConnected ? 'partially-verified' : 'needs-review' },
        { name: 'SXM_CTRL · native', encoding: 5, status: 'rtl-confirmed' },
        { name: 'SXM_EXEC · native', encoding: 6, status: 'rtl-confirmed' },
        { name: 'MXM_PARAM_LOAD', encoding: 7, status: 'rtl-confirmed' },
        { name: 'MXM_BACKEND', encoding: 8, status: 'rtl-confirmed' },
      ],
      mappings: [
        { name: 'MEM', localIndex: '0..103 / Hemisphere', status: 'rtl-confirmed', statement: '52 Slices × 2 Banks; no global Queue ID translation remains in the FU Cluster.' },
        { name: 'MXM Load / Compute / Dequant / Param Load / Backend', localIndex: '0..1 / Kind / Hemisphere', status: 'rtl-confirmed', statement: 'Each of the five MXM stream kinds selects one of two local MXM instances per Hemisphere.' },
        { name: 'VXM', localIndex: 'Central direct → Subsystem Boundary', status: vxmBoundaryConnected ? 'partially-verified' : 'needs-review', statement: 'The VXM request bypasses both Relay chains and reaches the real lpu_vxm_subsystem Program Boundary. Ready=0 and no Commit because the local-iMEM / Fetch Adapter is absent.' },
        { name: 'SXM Native CTRL / EXEC', localIndex: '0 / Kind / Hemisphere', status: 'rtl-confirmed', statement: 'Target 5 CTRL and target 6 EXEC reach separate 64-event native calendars. Formal entry is lpu_sxm_native_subsystem; batch WriteTap stays separate.' },
      ],
      controlSystemBoundary: {
        status: 'needs-review',
        statement: 'The Program Command Sequencer carries independent 2-bit Scope, but the current lpu_top / lpu_program_load_controller command-write boundary exposes only Destination and derives EAST or WEST Scope from Destination[12]. A top-level BOTH command input is not exposed in the inspected RTL.',
        evidence: [source('rtl/program_load/lpu_program_load_controller.sv', 248, 'command_scope_w', 'Scope is derived from the Destination Hemisphere bit at the Controller boundary', 'needs-review')],
      },
    },
    relay: {
      recordWidthBits: 165,
      bufferDepth: relayBufferDepth.value ?? 2,
      groupsPerHemisphere: memGroups.value,
      slicesPerGroup: columnsPerGroup.value,
      banksPerSlice: banksPerColumn.value,
      groupsPerRelay: relayGroupsPerStage.value,
      relayCountPerHemisphere,
      totalRelayStages: relayTotalStages,
      stages: relayStages,
      implementationStatus: '2 × 7 RTL Instances',
      verificationStatus: 'System Program-to-FU VCS PASS',
      integrationStatus: 'Integrated',
      vxmBypass: 'Central VXM Direct delivers the complete Program Record to the real lpu_vxm_subsystem Program Boundary and bypasses both Relay chains. Boundary Connected; Ready=0 and No Commit because the local-iMEM / Fetch Adapter is not integrated.',
      peripheralForward: 'R6 Outer Local preserves the complete 13-bit Destination and routes target 5 CTRL / target 6 EXEC to the native SXM Program endpoint in the selected Hemisphere.',
      localProgramPortsPerHemisphere: relayCountPerHemisphere,
      totalLocalProgramPorts: relayTotalStages,
      clusterAdapter: 'Program Distribution is a direct lpu_top child. It exports 7 independent MEM Local Program Ports per Hemisphere across the top-level boundary; the FU Cluster only consumes these ports and owns QCTL, Schedule Cycle and FU-local Frontends/Subsystems.',
      timing: {
        storageMeaning: 'The internal two-entry buffer is one registered Relay boundary plus skid capacity, not two independent pipeline stages.',
        readyBoundary: 'input_ready_o depends on registered occupancy and route validity, not combinationally on downstream forward_ready_i.',
        throughput: 'Steady-state simultaneous dequeue/enqueue targets II=1; Ready may recover one cycle after a full buffer drains.',
      },
      verification: {
        result: 'PROGRAM LOAD SYSTEM → PROGRAM DISTRIBUTION SYSTEM → FU SUBSYSTEM CLUSTER · VCS PASS',
        checks: 77,
        networkChecks: 77,
        topChecks: 340,
        physicalEdges: 569,
        singleStageChecks: 0,
        fixedDefect: 'The current Distribution System keeps two independent seven-stage Relay chains and exposes all 14 Relay-local MEM Program handshakes without a per-Hemisphere 7-to-1 adapter.',
      },
      evidence: [
        source(relayChainDefinition?.file ?? 'rtl/program_load/lpu_program_distribute_relay_chain.sv', relayChainDefinition?.line ?? 1, 'gen_relay[*].u_relay', 'seven serial Relay stages per Hemisphere; R0–R5 cover 16 MEM Banks and R6 covers 8 Banks plus Outer Local', relayStagesGenerated ? 'rtl-confirmed' : 'needs-review'),
        source('rtl/lpu_top.sv', 215, 'u_program_distribute_system', 'Program Distribution is a direct lpu_top child and exports the FU-local Program buses', networkIntegrated ? 'rtl-confirmed' : 'needs-review'),
        source('rtl/program_load/lpu_program_distribute_system.sv', 248, 'gen_program_relay_chain[0:1]', 'Two integrated seven-stage Relay chains expose fourteen Local Program ports', relayChainIntegrated ? 'rtl-confirmed' : 'needs-review'),
        source('handoff/latest-rtl-change.md', 1, 'Program Distribution top-level handoff', 'Both current system regressions passed after the top-level ownership refactor', 'rtl-confirmed'),
      ],
    },
    endpointBoundaries: [
      {
        id: 'sxm',
        name: 'SXM Native CTRL / EXEC',
        route: 'R6 Outer Local → FU Cluster → native calendars',
        boundary: 'Formal native Program endpoint',
        boundaryStatus: 'INTEGRATED',
        endpointStatus: 'Target 5 / 6 accepted',
        ready: 'Ready / Error handshake',
        commit: 'Calendar write / prime',
        missingAdapter: 'none on native Program route',
        frontendStatus: 'Two 64-event calendars per Hemisphere; QCTL not attached',
        status: 'rtl-confirmed',
        evidence: [
          source('rtl/core/lpu_fu_subsystem_cluster.sv', 455, 'u_sxm_subsystem', 'formal native SXM instance per Hemisphere'),
          source('rtl/sxm/lpu_sxm_native_subsystem.sv', 71, 'u_ctrl_calendar / u_exec_calendar', 'target 5/6 calendar endpoints'),
        ],
      },
      {
        id: 'vxm',
        name: 'VXM',
        route: 'Global Distributor → Central Direct · Relay Bypass',
        boundary: 'lpu_vxm_subsystem Program Boundary',
        boundaryStatus: vxmBoundaryConnected ? 'Boundary Connected' : 'Boundary Needs Review',
        endpointStatus: 'Endpoint Not Integrated',
        ready: 'Ready=0',
        commit: 'No Commit',
        missingAdapter: 'local-iMEM / Fetch Adapter',
        frontendStatus: 'Standalone Macro Frontend · TB PASS',
        status: vxmBoundaryConnected ? 'partially-verified' : 'needs-review',
        evidence: [
          source('rtl/program_load/lpu_program_distribute_system.sv', 1, 'vxm_program_valid / ready', 'Central VXM direct Program route bypasses both Relay chains', vxmBoundaryConnected ? 'rtl-confirmed' : 'needs-review'),
          source('rtl/vxm/lpu_vxm_subsystem.sv', 30, 'program_ready_o', "program_ready_o=1'b0; resident-config/Execute adapter is not implemented", 'rtl-confirmed'),
          source('handoff/latest-rtl-change.md', 1, 'lpu_program_load_fu_boundary_tb', 'PASS checks=37; VXM reaches the central Subsystem while both Relay inputs remain free of VXM requests', 'rtl-confirmed'),
        ],
      },
    ],
    resetLifecycle: {
      trigger: 'program_reset_i',
      transportReset: 'program_transport_rst_ni = rst_ni && !program_reset_i',
      effects: ['Clear 14 Relay Record Buffers', 'Clear per-port local handshake state', 'Reset outstanding Commit state'],
      status: 'rtl-confirmed',
      evidence: [
        source('rtl/program_load/lpu_program_distribute_system.sv', 1, 'program_transport_rst_ni', 'Program Reset participates in the active-low Relay transport reset', 'rtl-confirmed'),
        source('rtl/program_load/lpu_program_distribute_system.sv', 255, 'gen_program_relay_chain', 'Both seven-stage Relay chains consume program_transport_rst_ni', 'rtl-confirmed'),
        source('handoff/latest-rtl-change.md', 1, 'Program Reset boundary regression', 'stalled R6 record is cleared and does not leak into the next Program', 'rtl-confirmed'),
      ],
    },
    destinations: [
      {
        id: 'mem', name: 'MEM local iMEM', acceptedStrobe: '0111', validPayloadBits: 96,
        behavior: 'Invalid strobe/address raises load fault and inhibits the iMEM write.', status: 'rtl-confirmed',
        evidence: [source('rtl/mem/lpu_mem_local_imem_frontend.sv', 108, 'load_record_illegal_w', "load_strb_i == 4'b0111; illegal load record is gated from u_imem")],
      },
      {
        id: 'mxm-load', name: 'MXM Load local iMEM', acceptedStrobe: '1111', validPayloadBits: 128,
        behavior: 'Kind=1, Local Index 0..1 per Hemisphere. Invalid strobe/address/index raises a load or route fault.', status: 'rtl-confirmed',
        evidence: [source('rtl/core/lpu_fu_subsystem_cluster.sv', 296, 'PROGRAM_TARGET_MXM_LOAD', 'Destination Kind and local index select one of two local MXM instances')],
      },
      {
        id: 'mxm-dequant', name: 'MXM Dequant local iMEM', acceptedStrobe: '1111', validPayloadBits: 128,
        behavior: 'Kind=2, Local Index 0..1 per Hemisphere. Invalid strobe/address/index raises a load or route fault.', status: 'rtl-confirmed',
        evidence: [source('rtl/core/lpu_fu_subsystem_cluster.sv', 296, 'PROGRAM_TARGET_MXM_DEQUANT', 'Destination Kind and local index select one of two local MXM instances')],
      },
      {
        id: 'mxm-compute', name: 'MXM Compute local iMEM', acceptedStrobe: '1111', validPayloadBits: 128,
        behavior: 'Invalid strobe/address raises load fault and inhibits the iMEM write.', status: 'rtl-confirmed',
        evidence: [source('rtl/core/lpu_fu_subsystem_cluster.sv', 296, 'PROGRAM_TARGET_MXM_COMPUTE', 'Kind=3 and Local Index 0..1 select one of two local MXM instances')],
      },
      {
        id: 'mxm-param-load', name: 'MXM Param Load local iMEM', acceptedStrobe: '1111', validPayloadBits: 128,
        behavior: 'Kind=7, Local Index 0..1 per Hemisphere. The dedicated stream reaches the Param Load native command port directly after scheduling.', status: 'rtl-confirmed',
        evidence: [source('rtl/program_load/lpu_program_load_pkg.sv', 58, 'PROGRAM_TARGET_MXM_PARAM_LOAD', 'fourth MXM stream target kind')],
      },
      {
        id: 'mxm-backend', name: 'MXM Backend local iMEM', acceptedStrobe: '1111', validPayloadBits: 128,
        behavior: 'Kind=8, Local Index 0..1 per Hemisphere. The dedicated stream reaches the Backend native command port directly after scheduling.', status: 'rtl-confirmed',
        evidence: [source('rtl/program_load/lpu_program_load_pkg.sv', 59, 'PROGRAM_TARGET_MXM_BACKEND', 'fifth MXM stream target kind')],
      },
      {
        id: 'sxm-boundary', name: 'SXM Native CTRL / EXEC', acceptedStrobe: '128-bit word', validPayloadBits: 128,
        behavior: 'Target 5 CTRL and target 6 EXEC store payload and timing words in separate 64-event calendars. Local target index is zero; absolute-cycle matching issues the native ROW operation.', status: 'rtl-confirmed',
        evidence: [source('rtl/sxm/lpu_sxm_native_subsystem.sv', 71, 'u_ctrl_calendar / u_exec_calendar', 'formal Program endpoint in both Hemispheres')],
      },
      {
        id: 'vxm-boundary', name: 'VXM Program Boundary', acceptedStrobe: 'BOUNDARY ONLY', validPayloadBits: 128,
        behavior: 'Central Direct reaches lpu_vxm_subsystem without entering either Relay chain. Ready=0 and No Commit until a local-iMEM / Fetch Adapter is integrated.', status: 'partially-verified',
        evidence: [source('rtl/vxm/lpu_vxm_subsystem.sv', 5, 'Program Load boundary', 'Complete Program Record ports exist; resident-config/Execute adapter is not implemented', 'rtl-confirmed')],
      },
    ],
    commit: {
      signals: ['valid', 'ready', 'error'],
      ordering: 'Independent per-endpoint 1-bit token FIFO pairs WRITE responses in issue order; BOTH is retired only after both branch handshakes complete',
      sequenceIdPresent: false,
      status: 'rtl-confirmed',
      evidence: [
        source('rtl/program_load/lpu_program_load_controller.sv', 535, 'u_west_commit_fifo', 'DATA_WIDTH=1 ordered token FIFO'),
        source('rtl/program_load/lpu_program_load_controller.sv', 550, 'u_east_commit_fifo', 'DATA_WIDTH=1 ordered token FIFO'),
        source('rtl/program_load/lpu_program_load_controller.sv', 564, 'west/east_commit_valid/ready/error', 'ordered commit handshake and fault check'),
      ],
    },
    excludedPaths: [{
      name: 'Direct Host → MEM SRAM access / bypass', status: 'rtl-confirmed',
      statement: 'Not present as a current primary architecture interface.',
      evidence: [source('rtl/program_load/lpu_program_distribute_system.sv', 248, 'gen_program_relay_chain', 'Top-level Program Distribution routes through integrated endpoint decode, Relay chains and fourteen independent Local Program Ports')],
    }],
    reviewItems: [
      { name: 'Top-level BOTH Scope exposure', status: 'needs-review', statement: 'Distribution Ingress BOTH expansion is RTL-confirmed, but lpu_program_load_controller currently derives only EAST or WEST Scope from Destination[12].' },
      { name: 'MXM numerical datapath validation', status: 'needs-review', statement: 'Transport and five-stream frontend integration are validated; MXM numerical datapath and CModel-to-RTL cycle comparison remain outside this handoff scope.' },
      { name: 'VXM Program endpoint', status: 'needs-review', statement: 'Boundary Connected through Central Direct and explicitly bypasses Relay. Endpoint Not Integrated: Ready=0, No Commit, missing local-iMEM / Fetch Adapter.' },
      { name: 'SXM QCTL and CModel joint alignment', status: 'needs-review', statement: 'Native Program/ROW integration is present and VCS passes. SXM has no QCTL endpoint; CMODEL main still uses the older FIFO full-block path and has no native ROW Program implementation or joint trace validation.' },
    ],
    validation: {
      status: 'FIVE-STREAM MXM TRANSPORT / SYSTEM VCS PASS',
      scope: 'Five-stream Decoder, Scheduler and Frontend tests; Program Load transport; full Program Load-to-FU integration; QCTL distributed suite; and lpu_top compilation with QCTL disabled and enabled.',
      limitation: 'Native SXM final VCS regression passed five scenarios and 2787 checks. The SXM stream boundary adds one registered cycle to unconsumed pass-through traffic; old cross-FU static schedules were not separately regressed. CMODEL main has no native ROW Program implementation or joint trace comparison.',
      results: [
        'MXM five-stream Decoder / Scheduler / Frontend · VCS PASS',
        'Program Load transport and full Program Load → FU · VCS PASS · 342 checks',
        'MEM regressions and QCTL distributed suite · VCS PASS',
        'lpu_top ENABLE_QCTL=0 / 1 · VCS compile PASS',
        'MXM numerical datapath and CModel↔RTL cycle comparison · OUT OF SCOPE / NOT RUN',
        'SXM Native Program / ROW · VCS PASS · 5 scenarios · 2787 checks',
        'SXM CModel joint alignment · NOT RUN · production model remains older FIFO path',
      ],
      evidence: [source('handoff/latest-rtl-change.md', 1, 'QCTL Distributed Relay Store', 'named module and integration VCS PASS results; full runtime system PASS not claimed', 'rtl-confirmed')],
    },
  }

  return {
    schemaVersion: 12,
    generatedAt: snapshot.generatedAt,
    source: {
      snapshotGeneratedAt: snapshot.generatedAt,
      projectRoot: snapshot.project?.projectRoot ?? null,
      selectedTop: snapshot.summary?.selectedTop ?? null,
      rtlFileCount: snapshot.summary?.sourceFileCount ?? null,
      packageSha256: snapshot.sourceFiles?.find((item) => item.file === 'rtl/core/lpu_pkg.sv')?.sha256 ?? null,
    },
    policy: {
      statement: 'Configuration is generated from the current RTL snapshot, module parameters, package constants, generate formulas, and physical architecture evidence.',
      warning: 'WIP RTL SNAPSHOT: optional or disabled generate paths are shown separately from active default configuration.',
    },
    summary,
    programLoad,
    qctl: {
      laneCount: qctlQueueCount.value,
      enabledByDefault: qctl.value === 1,
      status: 'rtl-confirmed',
      groups: [
        { id: 'mem', name: 'MEM Bank-local Controllers', first: 0, last: 207, count: 208, status: 'rtl-confirmed', statement: 'Two hemispheres × 104 bank-local queues.' },
        { id: 'mxm-load', name: 'MXM Load', first: 208, last: 211, count: 4, status: 'rtl-confirmed', statement: 'One Load lane per MXM.' },
        { id: 'mxm-dequant', name: 'MXM Dequant', first: 212, last: 215, count: 4, status: 'rtl-confirmed', statement: 'One Dequant lane per MXM.' },
        { id: 'mxm-compute', name: 'MXM Compute', first: 216, last: 219, count: 4, status: 'rtl-confirmed', statement: 'One Compute lane per MXM.' },
        { id: 'mxm-param-load', name: 'MXM Param Load', first: 220, last: 223, count: 4, status: 'rtl-confirmed', statement: 'One Param Load lane per MXM.' },
        { id: 'mxm-backend', name: 'MXM Backend', first: 224, last: 227, count: 4, status: 'rtl-confirmed', statement: 'One Backend lane per MXM.' },
      ],
      pipeline: [
        { id: 'load-manager', name: 'Load Manager', count: 1, statement: 'Translates external Partition/Base/Count/Generation and logical Record writes into Queue/Offset packets.', evidence: [source('rtl/icu/lpu_qctl_global_subsystem.sv', 168, 'u_load_manager', 'one lpu_qctl_load_manager')] },
        { id: 'relay-chain', name: 'East / West Relay Chains', count: 2, statement: 'Routes load-time Partition and Record packets through R0–R6 with per-stage backpressure.', evidence: [source('rtl/icu/lpu_qctl_global_subsystem.sv', 184, 'u_east_relay_chain / u_west_relay_chain', 'two lpu_qctl_relay_chain instances')] },
        { id: 'relay-store', name: 'Regional Relay Store', count: qctlRelayCount.value, statement: `Each Relay owns a Directory, ${qctlRegionDepth.value ?? 'parameterized'}-Record Array, matching Valid Bitmap and ${qctlRelayBufferDepth.value ?? 'parameterized'}-entry Transit FIFO.`, evidence: [source('rtl/icu/lpu_qctl_relay_chain.sv', 155, 'gen_relay[*].u_relay', 'fourteen lpu_qctl_relay instances'), qctlRegionDepth.evidence] },
        { id: 'endpoint', name: 'FU-local Endpoint Reader', count: qctlQueueCount.value, statement: 'Each MEM/MXM Scheduler supplies Head Index + Generation and receives only a configured, in-range, written Record.', evidence: [source('rtl/mem/lpu_mem_subsystem.sv', 202, 'gen_qctl_endpoint[*].u_qctl_endpoint', 'one endpoint beside each MEM Scheduler'), source('rtl/mxm/lpu_mxm_subsystem.sv', 1, 'gen_qctl_endpoint[0:4]', 'five endpoints per MXM')] },
        { id: 'controller', name: 'Per-Queue Five-State Controller', count: qctlQueueCount.value, statement: 'The FU-local Controller consumes the regional Head Record and owns the four blocking waits plus exact-cycle Counter CE.', evidence: [source('rtl/icu/lpu_qctl_controller.sv', 34, 'state_t', 'IDLE + four wait states')] },
        { id: 'ce', name: 'scheduler_counter_ce', count: qctlQueueCount.value, statement: 'The blocking Record lowers CE in the same cycle; QCTL does not create a local clock or recalculate the Scheduler Cycle.', evidence: [source('rtl/icu/lpu_qctl_controller.sv', 182, 'scheduler_counter_ce_o', 'run/configured/primed and state-dependent CE')] },
        { id: 'counter', name: 'FU-local Scheduler Cycle Counter', count: qctlQueueCount.value, statement: '208 MEM counters and 20 MXM stream counters live in their owning FU Subsystems.', evidence: [source('rtl/mem/lpu_mem_subsystem.sv', 167, 'qctl_scheduler_cycle_q', 'one Bank-local 32-bit Counter per MEM Queue'), source('rtl/mxm/lpu_mxm_subsystem.sv', 1, 'qctl_scheduler_cycle_q', 'five Stream-local 32-bit Counters per MXM')] },
      ],
      relayTopology: {
        globalCapacity: qctlTotalCapacity.value,
        regionDepth: qctlRegionDepth.value,
        queueEntryLimit: qctlQueueEntryLimit.value,
        transitDepth: qctlRelayBufferDepth.value,
        storeContract: [
          { id: 'directory', name: 'Queue Directory', statement: 'Valid + Local Base + Count + Generation for the Queues owned by this Relay.' },
          { id: 'records', name: 'Record Array', statement: 'Stores 96-bit QCTL Records; the array itself is not reset.' },
          { id: 'valid', name: 'Valid Bitmap', statement: 'Cleared by Reset / Program Clear and set only by a legal Record handshake.' },
          { id: 'transit', name: 'Transit FIFO', statement: 'Buffers packets that belong to a later Relay and propagates backpressure upstream.' },
        ],
        phases: [
          { id: 'load', name: 'PROGRAM LOAD', path: 'Load Manager → Hemisphere select → R0…R6', statement: 'Partition metadata and Records are routed once to the owning regional Store. Global Load Complete requires every configured offset to be valid.' },
          { id: 'run', name: 'RUN', path: 'Endpoint Head Index/Generation → owning Store → Controller', statement: 'RUN reads the local Store directly. There is no refill from a central Pool and no per-Queue Record Cache.' },
        ],
        chains: [
          { id: 'east', name: 'East Chain', scope: 'MEM 0..103 + MXM0/1', stages: [
            { id: 'r0', name: 'R0', queues: 'MEM 0..15', locals: 'L0..15' },
            { id: 'r1', name: 'R1', queues: 'MEM 16..31', locals: 'L0..15' },
            { id: 'r2', name: 'R2', queues: 'MEM 32..47', locals: 'L0..15' },
            { id: 'r3', name: 'R3', queues: 'MEM 48..63', locals: 'L0..15' },
            { id: 'r4', name: 'R4', queues: 'MEM 64..79', locals: 'L0..15' },
            { id: 'r5', name: 'R5', queues: 'MEM 80..95', locals: 'L0..15' },
            { id: 'r6', name: 'R6', queues: 'MEM 96..103 + MXM 208/209, 212/213, 216/217, 220/221, 224/225', locals: 'L0..17 · 5-bit index' },
          ] },
          { id: 'west', name: 'West Chain', scope: 'MEM 104..207 + MXM2/3', stages: [
            { id: 'r0', name: 'R0', queues: 'MEM 104..119', locals: 'L0..15' },
            { id: 'r1', name: 'R1', queues: 'MEM 120..135', locals: 'L0..15' },
            { id: 'r2', name: 'R2', queues: 'MEM 136..151', locals: 'L0..15' },
            { id: 'r3', name: 'R3', queues: 'MEM 152..167', locals: 'L0..15' },
            { id: 'r4', name: 'R4', queues: 'MEM 168..183', locals: 'L0..15' },
            { id: 'r5', name: 'R5', queues: 'MEM 184..199', locals: 'L0..15' },
            { id: 'r6', name: 'R6', queues: 'MEM 200..207 + MXM 210/211, 214/215, 218/219, 222/223, 226/227', locals: 'L0..17 · 5-bit index' },
          ] },
        ],
      },
      states: [
        { id: 'idle', name: 'IDLE', statement: 'Reads the current Head Record and keeps CE high only for nonblocking or already-completed work.' },
        { id: 'sync', name: 'SYNC_WAIT', statement: 'Holds the Queue until the Participant-Mask Barrier broadcasts Release.' },
        { id: 'event', name: 'EVENT_WAIT', statement: 'Holds the Queue until the 32-bit TAG Event broadcast matches the saved operand.' },
        { id: 'notify', name: 'NOTIFY_WAIT', statement: 'Keeps an early NOTIFY request asserted; retirement waits for the current round to release.' },
        { id: 'packet', name: 'MEMPACKET_WAIT', statement: 'Keeps the packet ordinal stable until external mem_packet_retired_i.' },
      ],
      barrier: {
        participantMask: 'Only Queue IDs selected by participant_mask_i participate in the current barrier round.',
        arrival: 'Arrival is an idempotent per-round bit mask, not a token counter.',
        notify: 'An early NOTIFY remains pending and cannot retire before every configured participant arrives.',
        release: 'A successful NOTIFY emits one-cycle Release directly to all participants.',
        roundIsolation: 'Arrival state is cleared on Release and held clear across the Release edge, so consecutive rounds do not leak history.',
      },
      eventBuffer: {
        tagBits: 32,
        depth: qctlEventDepth.value,
        statement: 'The independent Event Buffer retains early DMA completion TAGs outside every Controller; one matching TAG broadcast may release every waiting Controller with that TAG.',
      },
      memPacket: {
        ordinalBits: 32,
        retirement: 'MEM_PACKET ordinal remains stable while waiting and retires only through external mem_packet_retired_i.',
        sramCommitRelationship: 'Packet retirement is not SRAM Commit. QCTL consumes only the final data-completion event; generation of the final SRAM Commit event remains in DMA / data movement.',
      },
      endpointBoundary: {
        connected: ['MEM · 208 Bank Queues', 'MXM · 20 Load / Compute / Dequant / Param Load / Backend Queues'],
        notConnected: ['VXM · no formal QCTL Queue number', 'SXM · no formal QCTL Queue number'],
        statement: 'The global subsystem owns Load Manager, regional Relay Stores and shared runtime resources. One Endpoint + Controller remains physically beside each MEM/MXM Scheduler. Do not draw QCTL as migrated into VXM or SXM.',
      },
      validation: {
        status: 'SCOPED VCS PASS',
        scope: 'Load Manager, Relay, Global Subsystem, Endpoint, Controller, Event Buffer, Runtime Fabric, MEM integration and lpu_top ENABLE_QCTL=0/1 compilation passed the handoff validation.',
        limitation: 'Transport and five-stream integration are validated. MXM numerical datapath and CModel-to-RTL cycle comparison were not run; VXM and SXM remain outside the formal QCTL endpoint map.',
        results: programLoad.validation.results,
      },
      evidence: [qctl.evidence, qctlQueueCount.evidence, source('rtl/core/lpu_fu_subsystem_cluster.sv', 198, 'gen_qctl.u_qctl_global_subsystem', 'East/West Relay Stores plus MEM/MXM FU-local Endpoints; VXM/SXM excluded', 'rtl-confirmed')],
    },
    memIsa: {
      machineCodeBits: memInstructionWidth.value,
      nativeCommandBits: nativeCommandWidth.value,
      queueEntryBits,
      directIssueBits: memInstructionWidth.value,
      issueCycleBits: 32,
      hasIndependentInstructionQueue: false,
      addressBits: memAddressWidth.value,
      status: 'rtl-confirmed',
      notes: [
        { name: 'READ / WRITE', status: 'rtl-confirmed', statement: 'Implemented MEM64 opcodes; the Native branch adapts them to a private Native32 command.' },
        { name: 'GATHER / SCATTER', status: 'rtl-confirmed', statement: 'Architecturally legal in the MEM64 decoder but currently unsupported; the adapter raises unsupported/fault instead of issuing.' },
        { name: 'Opcode 2', status: 'rtl-confirmed', statement: 'Retired/illegal encoding; the decoder rejects it.' },
      ],
      evidence: [memInstructionWidth.evidence, nativeCommandWidth.evidence, memAddressWidth.evidence, source('rtl/core/lpu_isa_decode.sv', 1, 'decode_mem_instruction', 'READ/WRITE implemented; GATHER/SCATTER legal unsupported; opcode2 illegal')],
    },
    frontends,
    compositions,
    memArray: {
      memCount,
      groupsPerMem: memGroups.value,
      columnsPerGroup: columnsPerGroup.value,
      columnsPerMem,
      banksPerColumn: banksPerColumn.value,
      banksPerMem,
      tileSlicesPerBank: tileRows.value,
      logicalTileSlicesPerMem: slicesPerMem,
      logicalTileSlicesSystem: multiply(slicesPerMem, memCount),
      wordWidthBits,
      depthRows: depthRows.value,
      macroWidthBits,
      macroDepthRows,
      widthBanks,
      depthBanks,
      mappedMacrosPerSlice: null,
      mappedMacrosPerMem: null,
      mappedMacrosSystem: null,
      activePhysicalMacros: 0,
      macroSelectEnabled,
      macroDefineEnabled,
      implementationStatus: useNativeMem.value === 1 ? 'Native Default' : 'Legacy Compatibility',
      formula: `${memGroups.value ?? 'GROUPS'} × ${columnsPerGroup.value ?? 'SLICES_PER_GROUP'} × ${banksPerColumn.value ?? 'BANKS_PER_SLICE'} × ${leafSramsPerBank ?? 'SUPERLANES'}`,
      evidence: [useNativeMem.evidence, memGroups.evidence, columnsPerGroup.evidence, banksPerColumn.evidence, depthRows.evidence, source('rtl/mem_native/mem_bank_superlane_leaf.sv', 1, 'mem_bank_superlane_leaf', 'behavioral DEPTH × 64-bit leaf array')],
      samplePath: 'u_fu_subsystems.gen_hemisphere[0].u_mem_subsystem.gen_native_mem.u_native_command_integration.u_srf_integration.u_mem_hemisphere.group_gen[*].u_group.slice_gen[*].u_slice.bank[*].superlane[*].u_leaf',
      activeImplementation: useNativeMem.value === 1 ? 'native' : useNativeMem.value === 0 ? 'legacy' : 'needs-review',
      nativeEnabledByDefault: useNativeMem.value === 1,
      machineCodeBits: memInstructionWidth.value,
      nativeCommandBits: nativeCommandWidth.value,
      queueEntryBits,
      hasIndependentInstructionQueue: false,
      leafSramsPerBank,
      leafSramsPerMem,
      leafSramsSystem,
      streamRegisterColumns: activeStreamColumns.value,
      streamRegisterPackageColumns: packageStreamColumns.value,
      streamRegisterMemBoundaries: memMappedStreamBoundaries,
      streamRegisterStatus,
      streamRegisterNote: streamColumnCountConflict
        ? `Active SRF COLUMNS=${activeStreamColumns.value}; lpu_pkg STREAM_REGISTER_COLUMNS=${packageStreamColumns.value}. The extra active column is displayed and marked Needs Review rather than hidden.`
        : 'Active SRF column count matches the package-level architectural count.',
      streamRegisterEvidence: [activeStreamColumns.evidence, packageStreamColumns.evidence, streamRegisterMappingEvidence],
      leafWidthBits: wordWidthBits,
      leafDepthRows: depthRows.value,
      leafImplementation: 'Behavioral 8192 × 64 bank/superlane array in the current Native default branch; not a claimed physical SRAM macro.',
    },
  }
}
