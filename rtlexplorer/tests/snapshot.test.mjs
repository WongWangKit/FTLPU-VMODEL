import test from 'node:test'
import assert from 'node:assert/strict'
import { promises as fs } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { attachArchitectureModel, loadArchitectureRules } from '../server/architecture-model.mjs'
import { loadPhysicalArchitectureRules } from '../server/physical-architecture-model.mjs'
import { signalSemanticPresentation } from '../src/lib/signal-presentation.ts'

const appRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const storedSnapshot = JSON.parse(await fs.readFile(path.join(appRoot, 'public', 'data', 'architecture-snapshot.json'), 'utf8'))
const snapshot = attachArchitectureModel(
  storedSnapshot,
  await loadArchitectureRules(path.join(appRoot, 'data', 'architecture-rules.json')),
  await loadPhysicalArchitectureRules(path.join(appRoot, 'data', 'physical-architecture-rules.json')),
)

test('real local RTL inventory and top are captured', () => {
  assert.equal(snapshot.summary.sourceFileCount, 151)
  assert.equal(snapshot.summary.primaryFilelistRtlFileCount, 63)
  assert.equal(snapshot.summary.autoTop, 'lpu_top')
  assert.equal(snapshot.summary.selectedTop, 'lpu_top')
  assert.ok(snapshot.summary.definitionCount > 100)
  assert.ok(snapshot.modules.some((module) => module.name === 'lpu_program_distribute_relay'))
  for (const name of ['lpu_program_load_controller', 'lpu_program_load_system', 'lpu_program_load_path', 'lpu_program_distributor', 'lpu_program_distribute_system']) assert.ok(snapshot.modules.some((module) => module.name === name), `${name} must be scanned`)
  assert.ok(snapshot.sourceFiles.every((file) => file.file.startsWith('rtl/') || file.file === 'sim/models/vxm/lpu_vxm_lut_storage.sv'))
  assert.ok(snapshot.sourceFiles.every((file) => /^[0-9a-f]{64}$/.test(file.sha256)))
})

test('obsolete frontend and pre-refactor Program Load shells are absent while the split formal path remains', () => {
  const moduleNames = new Set(snapshot.modules.map((module) => module.name))
  for (const name of ['lpu_frontend_cluster', 'lpu_program_load_segment', 'lpu_program_control_system', 'lpu_program_loader', 'lpu_program_load_subsystem', 'lpu_mxm_instruction_decode', 'lpu_vxm_instruction_decode', 'lpu_sxm_instruction_header_decode']) {
    assert.equal(moduleNames.has(name), false, `${name} must not remain in the current RTL snapshot`)
    assert.equal(snapshot.hierarchy.nodes.some((node) => node.moduleName === name), false)
  }
  for (const name of ['lpu_program_load_controller', 'lpu_program_load_system', 'lpu_program_load_path', 'lpu_program_distributor', 'lpu_program_distribute_system', 'lpu_program_distribute_elastic_stage', 'lpu_program_distribute_relay_chain', 'lpu_fu_subsystem_cluster']) {
    assert.equal(moduleNames.has(name), true, `${name} must remain in the formal path`)
  }
  assert.equal(snapshot.physicalArchitecture.blocks.some((block) => block.kind === 'hemisphere-router'), false)
})

test('top-level API reflects the current Program systems and removes the old ICU schedule/dispatch surface', () => {
  const top = snapshot.modules.find((module) => module.name === 'lpu_top')
  assert.ok(top)
  assert.equal(top.file, 'rtl/lpu_top.sv')
  assert.equal(top.ports.find((port) => port.name === 'program_schedule_cycle_o')?.direction, 'output')
  assert.equal(top.ports.find((port) => port.name === 'program_schedule_cycle_o')?.width, 32)
  for (const name of ['schedule_valid_i', 'schedule_payload_i', 'dispatch_valid_o', 'dispatch_payload_o', 'queue_fault_o']) assert.equal(top.ports.some((port) => port.name === name), false)
  for (const name of ['ICU_QUEUE_DEPTH', 'ENABLE_DISTRIBUTED_PROGRAM_FRONTEND']) assert.equal(top.parameters.some((parameter) => parameter.name === name), false)
  assert.ok(top.parameters.some((parameter) => parameter.name === 'QCTL_QUEUE_COUNT'))
})

test('lpu_top exposes Program Load, Program Distribution and FU Cluster as direct siblings', () => {
  const top = snapshot.modules.find((module) => module.name === 'lpu_top')
  assert.deepEqual(top.instances.map((instance) => [instance.name, instance.moduleName]), [
    ['u_program_load_system', 'lpu_program_load_system'],
    ['u_program_distribute_system', 'lpu_program_distribute_system'],
    ['u_fu_subsystems', 'lpu_fu_subsystem_cluster'],
  ])
  assert.equal(top.instances.find((instance) => instance.name === 'u_program_load_system')?.connections.find((connection) => connection.port === 'load_distribute_valid_o')?.expression, 'load_distribute_valid')
  assert.equal(top.instances.find((instance) => instance.name === 'u_program_distribute_system')?.connections.find((connection) => connection.port === 'load_distribute_valid_i')?.expression, 'load_distribute_valid')
  assert.equal(top.instances.some((instance) => instance.name === 'u_icu'), false)
  const repeatedType = snapshot.modules.find((module) => {
    const counts = new Map()
    for (const instance of module.instances) counts.set(instance.moduleName, (counts.get(instance.moduleName) ?? 0) + 1)
    return [...counts.values()].some((count) => count > 1)
  })
  assert.ok(repeatedType, 'expected at least one parent with multiple instances of the same module definition')
  assert.equal(new Set(repeatedType.instances.map((instance) => instance.id)).size, repeatedType.instances.length)
})

test('generate templates and black boxes are explicit rather than invented', () => {
  assert.ok(snapshot.summary.generatedTemplateCount > 0)
  const generated = snapshot.modules.flatMap((module) => module.instances).filter((instance) => instance.generated)
  assert.ok(generated.some((instance) => instance.name === 'u_mem_subsystem'))
  assert.equal(snapshot.summary.unresolvedInstanceCount, 0)
  assert.equal(snapshot.warnings.some((warning) => warning.code === 'UNRESOLVED_MODULE' && /lpu_qctl_(fabric|queue_controller)/.test(warning.message)), false)
  assert.equal(snapshot.warnings.some((warning) => warning.code === 'UNRESOLVED_MODULE'), false)
})

test('hierarchy keeps definitions and symbolic instances separate', () => {
  assert.equal(snapshot.hierarchy.nodes[0].moduleName, 'lpu_top')
  assert.ok(snapshot.hierarchy.nodes.some((node) => node.generated && node.path.includes('[*]')))
  assert.equal(new Set(snapshot.hierarchy.nodes.map((node) => node.id)).size, snapshot.hierarchy.nodes.length)
  assert.equal(snapshot.hierarchy.edges.length, snapshot.hierarchy.nodes.length - 1)
})

test('subsystem organization is the only FU execution hierarchy after direct instances were removed', () => {
  assert.equal(snapshot.architecture.policy.defaultView, 'architecture')
  const top = snapshot.architecture.containers.find((node) => !node.parentId)
  const topChildren = snapshot.architecture.containers.filter((node) => node.parentId === top.id)
  assert.ok(topChildren.find((node) => node.name === 'u_program_load_system' && node.primary))
  assert.ok(topChildren.find((node) => node.name === 'u_program_distribute_system' && node.primary))
  assert.ok(topChildren.find((node) => node.name === 'u_fu_subsystems' && node.primary))
  for (const legacyName of ['u_mem', 'u_sxm', 'u_mxm', 'u_vxm']) assert.equal(topChildren.find((node) => node.name === legacyName), undefined)
  assert.equal(snapshot.architecture.containment.length, snapshot.hierarchy.edges.length)
})

test('semantic interfaces trace back to confirmed raw connections and signal groups', () => {
  assert.ok(snapshot.architecture.interfaces.length > 0)
  const rawIds = new Set(snapshot.architecture.rawConnections.map((raw) => raw.id))
  for (const item of snapshot.architecture.interfaces) {
    assert.equal(item.connectionStatus, 'rtl-confirmed')
    assert.ok(item.rawConnectionIds.length > 0)
    assert.ok(item.rawConnectionIds.every((id) => rawIds.has(id)))
    assert.ok(item.signalGroups.every((group) => group.rawConnectionIds.every((id) => rawIds.has(id))))
  }
  assert.ok(snapshot.architecture.rawConnections.some((raw) => raw.evidence.includes('continuous-assignment')))
  assert.ok(snapshot.architecture.rawConnections.filter((raw) => raw.connectionStatus === 'rtl-confirmed').every((raw) => raw.line && raw.sourceFile))
})

test('MEM, MXM, and VXM subsystem views expose real interface evidence', () => {
  const containers = snapshot.architecture.containers
  const interfaces = snapshot.architecture.interfaces
  const mem = containers.find((node) => node.moduleName === 'lpu_mem_subsystem' && node.primary)
  const mxm = containers.find((node) => node.moduleName === 'lpu_mxm_subsystem' && node.primary)
  const vxm = containers.find((node) => node.moduleName === 'lpu_vxm_subsystem' && node.primary)
  assert.ok(mem && mxm && vxm)
  const memFrontend = containers.find((node) => node.parentId === mem.id && node.displayName === 'frontend[bank]' && node.template)
  assert.ok(memFrontend)
  assert.ok(containers.some((node) => node.parentId === memFrontend.id && node.displayName === 'macro_frontend'))
  assert.ok(containers.some((node) => node.parentId === memFrontend.id && node.displayName === 'fetch' && node.moduleName === 'lpu_mem_imem_fetch'))
  assert.equal(containers.some((node) => node.parentId === memFrontend.id && node.displayName === 'instruction_queue'), false)
  assert.equal(containers.some((node) => node.parentId === mem.id && node.displayName === 'timed_queue[bank]'), false)
  assert.ok(interfaces.some((item) => item.scopeId === mem.id && item.semanticName === 'Program Load Interface'))
  assert.equal(interfaces.some((item) => item.scopeId === mxm.id && item.semanticName === 'Queue Enqueue Interface'), false)
  assert.ok(interfaces.some((item) => item.scopeId === mxm.id && item.semanticName === 'Issue Interface'))
  assert.ok(interfaces.some((item) => item.scopeId === vxm.id && item.semanticName === 'East Stream Interface'))
  assert.ok(interfaces.some((item) => item.scopeId === vxm.id && item.semanticName === 'West Stream Interface'))
})

test('physical architecture is independent from RTL hierarchy wrappers', () => {
  const physical = snapshot.physicalArchitecture
  assert.equal(physical.policy.defaultView, 'physical')
  assert.equal(physical.summary.functionalBlockCount, 12)
  assert.equal(physical.summary.dataInterfaceCount, 15)
  assert.equal(physical.blocks.some((block) => block.kind === 'organization-wrapper'), false)
  assert.ok(physical.wrapperMappings.some((mapping) => mapping.moduleName === 'lpu_fu_subsystem_cluster' && !mapping.showAsFunctionalBlock))
  assert.deepEqual(physical.blocks.filter((block) => block.kind === 'mem').map((block) => [block.regionId, block.instanceCount]).sort(), [['east', 1], ['west', 1]])
  assert.deepEqual(physical.blocks.filter((block) => block.kind === 'sxm').map((block) => [block.regionId, block.instanceCount]).sort(), [['east', 1], ['west', 1]])
  assert.deepEqual(physical.blocks.filter((block) => block.kind === 'mxm').map((block) => [block.regionId, block.instanceCount]).sort(), [['east', 2], ['west', 2]])
  assert.equal(physical.blocks.find((block) => block.kind === 'vxm')?.instanceCount, 1)
  assert.equal(physical.blocks.some((block) => block.kind === 'instruction-control'), false)
  assert.equal(physical.interfaces.some((item) => item.direction === 'instruction-dispatch'), false)
})

test('global instruction distribution uses confirmed command storage, reconstruction and the integrated Relay fabric', () => {
  const physical = snapshot.physicalArchitecture
  const byId = new Map(physical.blocks.map((block) => [block.id, block]))
  const pipeline = byId.get('physical:control:program-load')
  assert.equal(pipeline?.displayName, 'Program Load System + Program Distribution System')
  assert.equal(pipeline?.structure.facts.find((fact) => fact.label === 'Command descriptors')?.value, 32)
  assert.equal(pipeline?.structure.facts.find((fact) => fact.label === 'Image context entries')?.value, 16)
  assert.equal(pipeline?.structure.facts.find((fact) => fact.label === 'Byte reservoir')?.value, 64)
  assert.equal(pipeline?.structure.facts.find((fact) => fact.label === 'Word FIFO depth')?.value, 8)
  assert.equal(pipeline?.structure.facts.find((fact) => fact.label === 'Scope width')?.value, 2)
  assert.equal(pipeline?.structure.facts.find((fact) => fact.label === 'Destination width')?.value, 13)
  assert.equal(pipeline?.structure.facts.find((fact) => fact.label === 'Elastic depth')?.value, 2)
  assert.match(pipeline?.structure.namingNote ?? '', /register array, not instruction-payload SRAM/i)
  for (const id of ['physical:control:west-router', 'physical:control:east-router']) assert.equal(byId.has(id), false)
})

test('grouped Program Load view exposes the real FIFO, handoff mux and elastic-stage boundary', () => {
  const drill = snapshot.physicalArchitecture.drilldown
  const byId = new Map(drill.nodes.map((node) => [node.id, node]))
  const root = byId.get('arch:control:program-load')
  assert.equal(root?.layout, 'program-load-overview')
  assert.deepEqual(root?.childIds, [
    'arch:control:program-load:instruction-dma',
    'arch:control:program-load:response',
    'arch:control:program-load:assembler',
    'arch:control:program-load:word-fifo',
    'arch:control:program-load:elastic',
    'arch:control:program-load:relay-fabric',
    'arch:control:program-load:fu-entry',
  ])
  assert.deepEqual([...new Set(root?.childIds.map((id) => byId.get(id)?.architectureContainer))].sort(), ['distribution-main', 'load-main'])
  assert.equal(byId.get('arch:control:program-load:word-fifo')?.handoffStage, 'reassembly-output')
  assert.equal(byId.get('arch:control:program-load:elastic')?.handoffStage, 'distributor-input')
  assert.equal(byId.get('arch:control:program-load:relay-fabric')?.nodeType, 'program-relay-fabric')
  assert.equal(byId.get('arch:control:program-load:relay-fabric')?.confidenceStatus, 'rtl-confirmed')
  const interfaces = drill.interfaces.filter((item) => item.scopeNodeId === root.id)
  for (const name of ['DMA → 响应缓冲', '缓冲 → Assembler', 'Assembler → Word FIFO', 'Word FIFO → Elastic Stage', 'Elastic Stage → Relay Chain', 'Relay Chain → FU Frontends / local iMEM', 'VXM Direct · Elastic / Distributor → Frontend Boundary']) assert.ok(interfaces.some((item) => item.name === name), `${name} main-chain edge must be present`)
  assert.match(root?.displayName ?? '', /Program Load.*Program Distribution.*FU-local Frontends/)
  assert.match(byId.get('arch:control:program-load:relay-fabric')?.displayName ?? '', /Relay Chain · West \+ East/)
  assert.ok(drill.nodes.every((node) => !/East Load Router|West Load Router|East Router|West Router/i.test(node.displayName)))
  const obsolete = new Set(['lpu_program_control_system', 'lpu_program_loader', 'lpu_program_load_subsystem'])
  assert.ok(drill.nodes.every((node) => node.rtlModuleRefs.every((name) => !obsolete.has(name))))
  assert.ok(drill.nodes.every((node) => node.sourceEvidence.every((evidence) => !/lpu_program_(control_system|loader|load_subsystem)\.sv/.test(evidence.file))))
})

test('program load buses include integrated SXM native calendars while VXM remains boundary-only', () => {
  const physical = snapshot.physicalArchitecture
  const programEdges = physical.interfaces.filter((item) => item.direction === 'program-load')
  assert.equal(programEdges.some((item) => /Concrete Destination/.test(item.name)), false)
  assert.ok(programEdges.some((item) => item.name === 'MEM Local iMEM Load · west'))
  assert.ok(programEdges.some((item) => item.name === 'MXM Local iMEM Load · east'))
  const boundaryEdges = programEdges.filter((item) => item.pathKind === 'blocked-boundary')
  assert.equal(boundaryEdges.length, 1)
  const sxmIntegrated = programEdges.filter((item) => /:sxm:program$/.test(item.id))
  const vxmBoundary = boundaryEdges.find((item) => item.id === 'physical-interface:control:central:vxm:program-boundary')
  assert.equal(sxmIntegrated.length, 2)
  assert.ok(sxmIntegrated.every((item) => item.pathKind === 'processed-path' && item.topologyStatus === 'rtl-confirmed'))
  assert.match(vxmBoundary?.notes.join(' ') ?? '', /Boundary Connected.*Endpoint Not Integrated/i)
  assert.ok(boundaryEdges.every((item) => item.topologyStatus === 'needs-review'))
  assert.ok(programEdges.some((item) => item.id === 'physical-interface:control:central:vxm:program-boundary' && /bypass/i.test(item.classificationBasis)))
  assert.ok(programEdges.every((item) => item.rawConnectionIds.length > 0))
  assert.equal(physical.interfaces.some((item) => item.direction === 'program-flow'), false)
  assert.ok(programEdges.filter((item) => /Concrete Destination/.test(item.name)).every((item) => item.sourceBlockId === 'physical:control:program-load'))
})

test('program-load endpoint contract uses 128-bit words, four 32-bit strobes and no Sequence ID', () => {
  const physical = snapshot.physicalArchitecture
  const branch = physical.interfaces.find((item) => item.id === 'physical-interface:control:west:mem:program')
  const rawById = new Map(snapshot.architecture.rawConnections.map((raw) => [raw.id, raw]))
  const signalNames = branch?.rawConnectionIds.map((id) => rawById.get(id)?.signalName ?? '') ?? []
  for (const field of ['control', 'data', 'strb', 'destination', 'address', 'last']) assert.ok(signalNames.some((name) => name.endsWith(`_${field}`)))
  assert.equal(signalNames.some((name) => name.endsWith('_scope')), false)
  assert.equal(signalNames.some((name) => /sequence/i.test(name)), false)
  const programRaw = snapshot.architecture.rawConnections.filter((raw) => /program_(load|loader|word|config|reassembler|distributor)/.test(raw.scopeModule))
  assert.equal(programRaw.some((raw) => /sequence/i.test(`${raw.signalName} ${raw.connectionExpression}`)), false)
  assert.ok(programRaw.some((raw) => /scope/i.test(raw.signalName)))
  assert.ok(programRaw.some((raw) => /destination/i.test(raw.signalName)))
  const decode = physical.drilldown.nodes.find((node) => node.id === 'arch:control:program-load:decode')
  assert.equal(decode?.displayName, 'Scope Expansion + Destination Decode')
})

test('per-hemisphere ordered commit contract replaces Sequence Commit semantics', () => {
  const commit = snapshot.configurationOverview.programLoad.commit
  assert.deepEqual(commit.signals, ['valid', 'ready', 'error'])
  assert.match(commit.ordering, /per-endpoint 1-bit token FIFO/i)
  assert.equal(commit.sequenceIdPresent, false)
  assert.equal(snapshot.physicalArchitecture.drilldown.interfaces.some((item) => /sequence commit/i.test(item.name)), false)
})

test('local iMEM guards expose MEM 0111 and MXM 1111 while blocking invalid writes', () => {
  const nodes = snapshot.physicalArchitecture.drilldown.nodes
  const mem = nodes.find((node) => node.id === 'arch:west:mem:frontend')
  const destinations = snapshot.configurationOverview.programLoad.destinations
  const mxm = destinations.find((item) => item.id === 'mxm-load')
  assert.match(mem?.description ?? '', /0111.*inhibits the write/i)
  assert.equal(mxm?.acceptedStrobe, '1111')
  assert.match(mxm?.behavior ?? '', /raises a load or route fault/i)
})

test('removed Host-to-MEM SRAM bypass is not represented as a physical interface', () => {
  const physical = snapshot.physicalArchitecture
  const interfaceText = physical.interfaces.map((item) => `${item.name} ${item.classificationBasis}`).join('\n')
  assert.doesNotMatch(interfaceText, /host.{0,24}(mem|sram)|(mem|sram).{0,24}host/i)
  assert.match(physical.blocks.find((block) => block.id === 'physical:control:program-load')?.structure.namingNote ?? '', /not instruction-payload SRAM/i)
})

test('SXM native Program and ROW are integrated while VXM remains boundary-only', () => {
  const drill = snapshot.physicalArchitecture.drilldown
  for (const id of ['arch:west:sxm', 'arch:east:sxm']) {
    const root = drill.nodes.find((node) => node.id === id)
    assert.match(root?.tags.map((tag) => `${tag.label} ${tag.value}`).join(' ') ?? '', /PROGRAM \/ TOP INTEGRATED.*5 CTRL.*6 EXEC.*2787 CHECKS/)
    assert.ok(drill.nodes.some((node) => node.id === `${id}:program-ingress` && node.confidenceStatus === 'rtl-confirmed'))
    assert.ok(drill.nodes.some((node) => node.id === `${id}:ctrl-calendar` && node.confidenceStatus === 'rtl-confirmed'))
    assert.ok(drill.nodes.some((node) => node.id === `${id}:exec-calendar` && node.confidenceStatus === 'rtl-confirmed'))
    assert.ok(drill.nodes.some((node) => node.id === `${id}:triangle-core` && node.confidenceStatus === 'rtl-confirmed'))
    assert.ok(drill.nodes.some((node) => node.id === `${id}:batch-writetap`))
    assert.equal(drill.nodes.some((node) => node.id === `${id}:macro-frontend`), false)
  }
  const vxm = drill.nodes.find((node) => node.id === 'arch:central:vxm')
  assert.match(vxm?.tags.map((tag) => `${tag.label} ${tag.value}`).join(' ') ?? '', /BOUNDARY CONNECTED.*ENDPOINT NOT INTEGRATED/)
  assert.match(vxm?.tags.map((tag) => `${tag.label} ${tag.value}`).join(' ') ?? '', /READY=0.*NO COMMIT/)
  assert.ok(drill.nodes.some((node) => node.id === 'arch:central:vxm:program-boundary' && node.confidenceStatus === 'rtl-confirmed'))
  assert.ok(drill.nodes.some((node) => node.id === 'arch:central:vxm:program-adapter-missing' && node.confidenceStatus === 'needs-review'))
  for (const id of ['arch:west:mxm', 'arch:east:mxm']) {
    const root = drill.nodes.find((node) => node.id === id)
    assert.match(root?.tags.map((tag) => `${tag.label} ${tag.value}`).join(' ') ?? '', /CURRENT TOP-INTEGRATED RTL/)
    assert.ok(root?.rtlModuleRefs.includes('lpu_mxm_core'))
    assert.ok(drill.nodes.some((node) => node.id === `${id}:core` && node.confidenceStatus === 'rtl-confirmed'))
  }
})

test('the explicit Instruction DMA is visible while architecture-only group containers remain identified', () => {
  const physical = snapshot.physicalArchitecture
  const dma = physical.drilldown.nodes.find((node) => node.id === 'arch:control:program-load:instruction-dma')
  assert.equal(dma?.rtlModuleRefs.includes('lpu_instruction_dma'), true)
  const root = physical.drilldown.nodes.find((node) => node.id === 'arch:control:program-load')
  assert.equal(root?.sourceKind, 'architectural-grouping')
  assert.match(root?.description ?? '', /display containers, not extra RTL modules/i)
  const rawById = new Map(snapshot.architecture.rawConnections.map((raw) => [raw.id, raw]))
  const commandBus = physical.drilldown.interfaces.find((item) => item.id === 'arch:control:program-load:interface:dma-command')
  assert.ok(commandBus.rawConnectionIds.some((id) => /instruction_dma_command|dma_cmd/.test(rawById.get(id)?.signalName ?? '')))
})

test('hemisphere and MEM dimensions use current RTL evidence rather than reference-image quantities', () => {
  const physical = snapshot.physicalArchitecture
  const eastMem = physical.blocks.find((block) => block.id === 'physical:east:mem')
  const westMem = physical.blocks.find((block) => block.id === 'physical:west:mem')
  assert.equal(eastMem?.placementStatus, 'rtl-confirmed')
  assert.match(eastMem?.placementBasis ?? '', /gen_east_host_column/)
  assert.match(westMem?.placementBasis ?? '', /gen_west_host_column/)
  assert.deepEqual(eastMem?.structure.array, { groups: 13, slicesPerGroup: 4, banksPerSlice: 2, superlaneLeavesPerBank: 4 })
  assert.equal(eastMem?.structure.facts?.find((fact) => fact.label === 'Native slices / hemisphere')?.value, 52)
  assert.equal(eastMem?.structure.facts?.find((fact) => fact.label === 'Bank-local frontends / hemisphere')?.value, 104)
  assert.equal(eastMem?.structure.facts?.some((fact) => fact.value === 44), false)
})

test('physical buses preserve raw signal evidence and processed paths are explicit', () => {
  const physical = snapshot.physicalArchitecture
  const rawIds = new Set(snapshot.architecture.rawConnections.map((raw) => raw.id))
  assert.ok(physical.interfaces.every((item) => item.rawConnectionIds.every((id) => rawIds.has(id))))
  const direct = physical.interfaces.find((item) => item.id === 'physical-interface:west:mem-to-sxm-east')
  assert.equal(direct?.pathKind, 'processed-path')
  assert.ok(direct?.signalCount > 0)
  const reverse = physical.interfaces.find((item) => item.id === 'physical-interface:west:sxm-to-mem-west')
  assert.equal(reverse?.pathKind, 'processed-path')
  assert.ok(reverse?.signalCount > 0)
  assert.ok(physical.interfaces.some((item) => item.id === 'physical-interface:west:sxm-to-mxm-east'))
  assert.ok(physical.interfaces.some((item) => item.id === 'physical-interface:west:mxm-to-sxm-west'))
})

test('multi-level drilldown covers every physical block with traceable architecture nodes', () => {
  const { drilldown, blocks } = snapshot.physicalArchitecture
  assert.ok(drilldown.summary.nodeCount > 1500)
  assert.ok(drilldown.summary.interfaceCount > 250)
  assert.equal(Object.keys(drilldown.rootNodeIdsByBlock).length, blocks.length)
  const nodeIds = new Set(drilldown.nodes.map((node) => node.id))
  const rawIds = new Set(snapshot.architecture.rawConnections.map((raw) => raw.id))
  for (const block of blocks) assert.ok(nodeIds.has(drilldown.rootNodeIdsByBlock[block.id]), `missing drill root for ${block.id}`)
  for (const item of drilldown.interfaces) {
    assert.ok(nodeIds.has(item.scopeNodeId))
    assert.ok(nodeIds.has(item.sourceNodeId))
    assert.ok(nodeIds.has(item.destinationNodeId))
    assert.ok(item.rawConnectionIds.every((id) => rawIds.has(id)))
  }
})

test('MEM functional decode path selects lpu_mem_macro_decoder and keeps tile decode as implementation detail', () => {
  const drill = snapshot.physicalArchitecture.drilldown
  const root = drill.nodes.find((node) => node.id === 'arch:west:mem')
  const macro = drill.nodes.find((node) => node.id === 'arch:west:mem:macro')
  const macroDecoder = drill.nodes.find((node) => node.id === 'arch:west:mem:macro:decoder')
  assert.deepEqual(root?.childIds.map((id) => drill.nodes.find((node) => node.id === id)?.displayName), [
    'Bank-local Macro Frontend · 104', 'MEM64 → Native32 Command Adapter · 104', 'Native MEM Execution Array',
    'MEM / SRF Parallel Data Plane',
  ])
  assert.ok(macro?.rtlModuleRefs.includes('lpu_mem_macro_decoder'))
  assert.equal(macro?.rtlModuleRefs.includes('lpu_mem_instruction_decode'), false)
  assert.deepEqual(macroDecoder?.rtlModuleRefs, ['lpu_mem_macro_decoder'])
  const leaf = drill.nodes.find((node) => node.id === 'arch:west:mem:execution:column:0:bank:0:tile:0')
  assert.ok(leaf?.rtlModuleRefs.includes('mem_bank_superlane_leaf'))
  assert.match(leaf?.description ?? '', /8192 rows × 64 bits/i)
})

test('MEM Native array drills through 13 groups, 52 slices, 104 banks and four superlane leaves', () => {
  const nodes = snapshot.physicalArchitecture.drilldown.nodes
  const execution = nodes.find((node) => node.id === 'arch:west:mem:execution')
  assert.equal(execution?.childIds.length, 13)
  const group0 = nodes.find((node) => node.id === 'arch:west:mem:execution:group:0')
  assert.equal(group0?.sourceKind, 'generate-structure')
  assert.equal(group0?.childIds.length, 4)
  const column0 = nodes.find((node) => node.id === 'arch:west:mem:execution:column:0')
  assert.equal(column0?.sourceKind, 'generate-structure')
  assert.equal(column0?.displayName, 'Slice[0]')
  assert.equal(column0?.childIds.length, 2)
  const bank0 = nodes.find((node) => node.id === 'arch:west:mem:execution:column:0:bank:0')
  assert.deepEqual(bank0?.childIds.map((id) => nodes.find((node) => node.id === id)?.displayName), [
    'Bank Control Column',
    'Superlane[0] SRAM Leaf',
    'Superlane[1] SRAM Leaf',
    'Superlane[2] SRAM Leaf',
    'Superlane[3] SRAM Leaf',
  ])
  const leaf = nodes.find((node) => node.id === 'arch:west:mem:execution:column:0:bank:0:tile:0')
  assert.deepEqual(leaf?.childIds.map((id) => nodes.find((node) => node.id === id)?.displayName), ['SRAM Row Read', 'SRAM Row Write / WriteTap'])
})

test('MEM Macro Scheduler issues directly into the MEM64 / Native32 adapter without an Instruction Queue', () => {
  const drill = snapshot.physicalArchitecture.drilldown
  const nodes = new Map(drill.nodes.map((node) => [node.id, node]))
  const root = nodes.get('arch:west:mem')
  const localIssue = nodes.get('arch:west:mem:local-issue-path')
  assert.equal(root?.layout, 'mem-interactive-overview')
  assert.equal(localIssue?.layout, 'pipeline')
  assert.equal(nodes.get('arch:west:mem:frontend')?.parentId, localIssue?.id)
  assert.equal(nodes.get('arch:west:mem:macro')?.parentId, 'arch:west:mem:frontend')
  assert.equal(nodes.has('arch:west:mem:timed-queue'), false)
  assert.equal(nodes.has('arch:west:mem:issue-select'), false)
  assert.equal(nodes.get('arch:west:mem:macro:scheduler:issue')?.displayName, 'Direct MEM64 Issue')
  const bank = nodes.get('arch:west:mem:execution:column:0:bank:0')
  assert.equal(bank?.layout, 'south-north-bank')
  assert.ok(bank?.childIds.includes('arch:west:mem:execution:column:0:bank:0:control-column'))
  assert.ok(drill.interfaces.some((item) => item.id === 'arch:west:mem:macro:scheduler:interface:direct-issue' && item.name === 'Direct MEM64 Issue'))
  assert.ok(drill.interfaces.some((item) => item.id === 'arch:west:mem:interface:selector-execution' && /MEM64.*Native32/.test(item.name)))
  const memNodes = drill.nodes.filter((node) => node.id.startsWith('arch:west:mem'))
  assert.equal(memNodes.some((node) => node.rtlModuleRefs.includes('lpu_mem_instruction_queue')), false)
  assert.equal(memNodes.some((node) => node.displayName === 'Instruction Queue · 104'), false)
})

test('MEM direct-issue buses preserve parsed raw bindings', () => {
  const drill = snapshot.physicalArchitecture.drilldown
  const byId = new Map(drill.interfaces.map((item) => [item.id, item]))
  assert.equal(byId.has('arch:west:mem:interface:macro-queue'), false)
  assert.equal(byId.has('arch:west:mem:interface:queue-selector'), false)
  assert.ok((byId.get('arch:west:mem:macro:scheduler:interface:direct-issue')?.signalCount ?? 0) >= 4)
  assert.ok((byId.get('arch:west:mem:interface:selector-execution')?.signalCount ?? 0) >= 4)
  assert.match(byId.get('arch:west:mem:macro:scheduler:interface:direct-issue')?.sourceEvidence[0]?.file ?? '', /lpu_mem_macro_scheduler\.sv/)
})

test('removed central ICU queue-bank architecture is absent from visualization and the current RTL snapshot', () => {
  const physical = snapshot.physicalArchitecture
  assert.equal(physical.blocks.some((block) => block.id === 'physical:control:instruction'), false)
  assert.equal(physical.drilldown.nodes.some((node) => node.id.startsWith('arch:control:instruction:')), false)
  assert.equal(physical.drilldown.interfaces.some((item) => /ICU|138-way|External ICU/.test(item.name)), false)
  assert.equal(snapshot.modules.some((module) => module.name === 'lpu_icu' || module.name === 'lpu_icu_queue'), false)
  assert.equal(snapshot.hierarchy.nodes.some((node) => node.moduleName === 'lpu_icu' || node.moduleName === 'lpu_icu_queue'), false)
})

test('QCTL exposes distributed Relay Stores, FU-local Endpoints, Controllers and runtime blocking semantics', () => {
  const drill = snapshot.physicalArchitecture.drilldown
  const nodes = new Map(drill.nodes.map((node) => [node.id, node]))
  const qctlRoot = drill.nodes.find((node) => node.id === 'arch:control:qctl')
  const relayFabric = drill.nodes.find((node) => node.id === 'arch:control:qctl:relay-fabric')
  assert.equal(qctlRoot?.displayName, 'QCTL Distributed Relay Store · 228 Formal Endpoints')
  assert.deepEqual(qctlRoot?.childIds, [
    'arch:control:qctl:load-manager',
    'arch:control:qctl:relay-fabric',
    'arch:control:qctl:readers',
    'arch:control:qctl:controllers',
    'arch:control:qctl:counters',
    'arch:control:qctl:barrier',
    'arch:control:qctl:events',
    'arch:control:qctl:packet',
    'arch:control:qctl:endpoints',
  ])
  assert.match(relayFabric?.description ?? '', /seven regional Relay stages.*Queue Directory.*64-entry Record Array.*Valid Bitmap.*Transit FIFO/i)
  assert.deepEqual(nodes.get('arch:control:qctl:relay-fabric:east')?.childIds.map((id) => nodes.get(id)?.displayName), ['R0 · MEM 0..15', 'R1 · MEM 16..31', 'R2 · MEM 32..47', 'R3 · MEM 48..63', 'R4 · MEM 64..79', 'R5 · MEM 80..95', 'R6 · MEM 96..103 + 10 MXM stream endpoints'])
  assert.deepEqual(nodes.get('arch:control:qctl:relay-fabric:west')?.childIds.map((id) => nodes.get(id)?.displayName), ['R0 · MEM 104..119', 'R1 · MEM 120..135', 'R2 · MEM 136..151', 'R3 · MEM 152..167', 'R4 · MEM 168..183', 'R5 · MEM 184..199', 'R6 · MEM 200..207 + 10 MXM stream endpoints'])
  assert.deepEqual(nodes.get('arch:control:qctl:relay-fabric:store-anatomy')?.childIds.map((id) => nodes.get(id)?.displayName), ['Queue Directory', '96-bit Record Array', 'Record Valid Bitmap', 'Transit FIFO'])
  assert.deepEqual(nodes.get('arch:control:qctl:readers')?.childIds.map((id) => nodes.get(id)?.displayName), ['Head Index + Generation', 'Store Validity Guard', 'Semantic Retirement'])
  assert.deepEqual(nodes.get('arch:control:qctl:controllers')?.childIds.map((id) => nodes.get(id)?.displayName), ['IDLE', 'SYNC_WAIT', 'EVENT_WAIT', 'NOTIFY_WAIT', 'MEMPACKET_WAIT'])
  assert.deepEqual(nodes.get('arch:control:qctl:endpoints')?.childIds.map((id) => nodes.get(id)?.displayName), ['MEM Banks · 0..207', 'MXM Load · 208..211', 'MXM Dequant · 212..215', 'MXM Compute · 216..219', 'MXM Param Load · 220..223', 'MXM Backend · 224..227', 'VXM · Not Connected', 'SXM · No QCTL Endpoint'])
  assert.match(nodes.get('arch:control:qctl:barrier')?.description ?? '', /early NOTIFY.*every participant.*one Release pulse.*clears the round/i)
  assert.match(nodes.get('arch:control:qctl:events')?.description ?? '', /matching TAG.*every Controller/i)
  assert.match(nodes.get('arch:control:qctl:packet')?.description ?? '', /must not be presented as an SRAM Commit/i)
  const qctlText = drill.nodes.filter((node) => node.id.startsWith('arch:control:qctl')).map((node) => `${node.displayName} ${node.description} ${node.rtlModuleRefs.join(' ')}`).join('\n')
  assert.doesNotMatch(qctlText, /lpu_qctl_system|lpu_qctl_shared_pool|lpu_qctl_queue_cache|lpu_qctl_sync_fabric|Legacy|Compatibility/i)
})

test('Word FIFO quick specification is fully RTL-backed', () => {
  const node = snapshot.physicalArchitecture.drilldown.nodes.find((item) => item.id === 'arch:west:mem:macro:word-fifo')
  assert.equal(node?.parameterRefs.find((item) => item.name === 'DATA_WIDTH')?.value, 97)
  assert.equal(node?.parameterRefs.find((item) => item.name === 'DEPTH')?.value, 4)
})

test('distributed FU-local control keeps direct MEM issue and the current MXM command waves inside their owning subsystems', () => {
  const nodes = new Map(snapshot.physicalArchitecture.drilldown.nodes.map((node) => [node.id, node]))
  assert.equal(nodes.has('arch:west:mem:timed-queue'), false)
  assert.equal(nodes.has('arch:west:mem:issue-select'), false)
  assert.equal(nodes.get('arch:west:mem:macro:scheduler')?.childIds.length, 4)
  for (const kind of ['compute', 'load', 'param-load', 'dequant']) assert.ok(nodes.has(`arch:west:mxm:core:frontend:control:${kind}`))
})

test('explicit FIFO nodes retain RTL-backed width, depth, contents and source mapping', () => {
  const nodes = new Map(snapshot.physicalArchitecture.drilldown.nodes.map((node) => [node.id, node]))
  const value = (id, name) => nodes.get(id)?.parameterRefs.find((item) => item.name === name)?.value
  assert.equal(value('arch:west:mem:macro:word-fifo', 'DATA_WIDTH'), 97)
  assert.equal(value('arch:west:mem:macro:word-fifo', 'DEPTH'), 4)
  assert.equal(value('arch:west:mem:macro:context-fifo', 'DATA_WIDTH'), 271)
  assert.equal(nodes.has('arch:west:mem:timed-queue:fifo'), false)
  assert.equal(value('arch:west:mem:macro:scheduler:issue', 'INSTRUCTION'), 64)
  assert.equal(value('arch:west:mem:macro:scheduler:issue', 'CYCLE'), 32)
  assert.equal(value('arch:west:mxm:core:frontend:control', 'QUEUE_DEPTH'), 16)
  assert.equal(value('arch:west:mxm:core:backend', 'BANK_DEPTH'), 512)
  assert.equal(value('arch:west:mxm:core:backend', 'BANK_WORD_BITS'), 256)
})

test('MXM exposes the integrated core, 4x4 Supercell template and arithmetic pipelines without legacy execution nodes', () => {
  const nodes = new Map(snapshot.physicalArchitecture.drilldown.nodes.map((node) => [node.id, node]))
  const root = nodes.get('arch:west:mxm')
  const core = nodes.get('arch:west:mxm:core')
  const array = nodes.get('arch:west:mxm:core:frontend:array')
  const supercell = nodes.get('arch:west:mxm:core:frontend:array:supercell')
  assert.equal(root?.layout, 'mxm-core-overview')
  assert.deepEqual(core?.childIds.map((id) => nodes.get(id)?.nodeType), ['mxm-frontend', 'mxm-result-return', 'mxm-backend'])
  assert.equal(array?.parameterRefs.find((item) => item.name === 'ROWS')?.value, 4)
  assert.equal(array?.parameterRefs.find((item) => item.name === 'COLS')?.value, 4)
  assert.equal(supercell?.childIds.filter((id) => nodes.get(id)?.nodeType === 'mxm-group').length, 8)
  assert.equal(nodes.get(`${supercell?.id}:group:0:dot`)?.parameterRefs.find((item) => item.name === 'STAGES')?.value, 9)
  assert.equal(nodes.get(`${supercell?.id}:group:0:partial-add`)?.parameterRefs.find((item) => item.name === 'STAGES')?.value, 3)
  assert.match(nodes.get(`${supercell?.id}:group:0:dot:csa`)?.displayName ?? '', /8→6→4→3→2/)
  const mxmNodes = [...nodes.values()].filter((node) => node.id.startsWith('arch:west:mxm'))
  assert.equal(mxmNodes.some((node) => node.rtlModuleRefs.includes('lpu_mxm_slice') || node.rtlModuleRefs.includes('lpu_mxm_shared_accumulator')), false)
})

test('priority Bus Detail interfaces retain raw RTL evidence for program-load and stream directions', () => {
  const interfaces = snapshot.physicalArchitecture.interfaces
  const drillInterfaces = snapshot.physicalArchitecture.drilldown.interfaces
  const rawById = new Map(snapshot.architecture.rawConnections.map((raw) => [raw.id, raw]))
  const priority = [
    drillInterfaces.find((item) => item.name === 'Word FIFO Dequeue + Route Metadata'),
    drillInterfaces.find((item) => item.name === 'Distributor Input Handshake'),
    interfaces.find((item) => item.name === 'MEM Local iMEM Load · west'),
    interfaces.find((item) => item.name === 'MEM Local iMEM Load · east'),
    interfaces.find((item) => item.direction === 'east-stream' && item.pathKind === 'processed-path'),
    interfaces.find((item) => item.direction === 'west-stream' && item.pathKind === 'processed-path'),
  ]
  assert.ok(priority.every(Boolean))
  for (const item of priority) {
    assert.ok(item.rawConnectionIds.length > 0, `${item.name} should retain raw signals`)
    assert.ok(item.signalGroups.length > 0, `${item.name} should retain semantic groups`)
    assert.ok(item.rawConnectionIds.every((id) => rawById.has(id)))
    const raws = item.rawConnectionIds.map((id) => rawById.get(id))
    assert.ok(raws.some((raw) => raw.sourceEndpoints.length || raw.destinationEndpoints.length))
    assert.ok(raws.every((raw) => raw.sourceFile && raw.line))
  }
})

test('priority Program Load buses use specific purpose groups instead of broad buckets', () => {
  const interfaces = snapshot.physicalArchitecture.drilldown.interfaces
  const groupNames = (name) => interfaces.find((item) => item.name === name)?.signalGroups.map((group) => group.name)
  assert.deepEqual(groupNames('Word FIFO Dequeue + Route Metadata'), [
    'Program Load Handshake',
    'Program Word · 128-bit Transport',
    'Program Word Strobe · 4 × 32-bit',
    'Scope / 13-bit Destination / iMEM Address',
  ])
  assert.ok(groupNames('Distributor Input Handshake').includes('Program Load Control · WRITE / PRIME'))
})

test('valid and ready fields retain their channel object in every semantic display name', () => {
  const programSignals = snapshot.architecture.rawConnections.filter((raw) =>
    /^(program_cmd_write|ctrl_load_txn|ctrl_dma_cmd|ddr_read_(?:req|rsp)|config_(?:enqueue|dequeue)|reasm_rsp|word_fifo_enqueue|load_word|load_distribute|load_record|endpoint_load).*(valid|ready)(?:_[ioq])?$/.test(raw.signalName),
  )
  assert.ok(programSignals.length > 10)
  const labels = new Map(programSignals.map((raw) => [raw.signalName, signalSemanticPresentation(raw).displayName]))
  assert.ok([...labels.values()].every((label) => !/^(Valid|Ready)$/i.test(label)))
  assert.equal(labels.get('program_cmd_write_valid_i'), 'Command Descriptor Write Valid')
  assert.equal(labels.get('ctrl_load_txn_valid'), 'Program Load Transaction Valid')
  assert.equal(labels.get('config_enqueue_ready'), 'Image Context Enqueue Ready')
  assert.equal(labels.get('load_word_valid'), 'Reassembled Word FIFO Dequeue Valid')
  assert.equal(labels.get('load_record_ready_o'), 'Distributor Input Ready')
})

test('distributed Program Load terminates at FU-local iMEM and local macro paths', () => {
  const physical = snapshot.physicalArchitecture
  const programEndpoints = physical.interfaces.filter((entry) => /Local iMEM Load/.test(entry.name))
  assert.deepEqual(programEndpoints.map((entry) => entry.destinationBlockId).sort(), ['physical:east:mem', 'physical:east:mxm', 'physical:west:mem', 'physical:west:mxm'])
  const localNames = physical.drilldown.nodes.map((node) => node.displayName)
  for (const name of ['Bank-local Macro Frontend · 104', 'MEM Frontend · Local iMEM + Macro', 'Macro Decode / Schedule Pipeline', 'MEM Macro Scheduler', 'Direct MEM64 Issue', 'MEM64 → Native32 Command Adapter · 104']) assert.ok(localNames.includes(name))
  for (const name of ['Five-Stream MXM ICU Frontends · Direct Native Issue', 'Shared MXM Macro Decoder Architecture · 12 States', 'Integrated MXM Core', 'MXM Frontend · 4×4 Supercell Array', 'Static Diagonal Result Return', 'MXM Backend · Column Accumulator', 'R6 Outer Local → SXM Program', 'CTRL Issue Calendar · 64 Events', 'EXEC Issue Calendar · 64 Events', 'Native Triangle ROW Core', 'Triangle Storage · 10 Slots', 'Separate Batch WriteTap Path', 'VXM Frontend / Local Instruction Entry', 'VXM 指令译码（架构概括）', 'VXM Data Path · Vector Execution Array']) assert.ok(localNames.includes(name))
  for (const removedName of ['SXM Frontend / Local Instruction Entry', 'SXM 指令译码（架构概括）', 'SXM Data Path · Transpose / Permute']) assert.equal(localNames.includes(removedName), false)
})

test('MEM Native visualization preserves the current active RTL boundary', () => {
  const physical = snapshot.physicalArchitecture
  const nodes = new Map(physical.drilldown.nodes.map((node) => [node.id, node]))
  assert.equal(nodes.get('arch:west:mem:native-adapter')?.parameterRefs.find((item) => item.name === 'MEM_INSTRUCTION_WIDTH')?.value, 64)
  assert.equal(nodes.get('arch:west:mem:native-adapter')?.parameterRefs.find((item) => item.name === 'MEM_NATIVE_COMMAND_WIDTH')?.value, 32)
  assert.equal(nodes.has('arch:west:mem:legacy-compatibility'), false)
  assert.match(nodes.get('arch:west:mem:native-adapter:unsupported')?.description ?? '', /GATHER.*SCATTER.*opcode 2/i)
  const qctl = physical.blocks.find((block) => block.id === 'physical:control:qctl')
  assert.equal(qctl?.placementStatus, 'rtl-confirmed')
  assert.equal(qctl?.displayName, 'QCTL Distributed Relay Store · 228 Endpoints')
  assert.equal(qctl?.enabledByDefault, false)
  assert.match(qctl?.function ?? '', /Load Manager.*East\/West QCTL Relay chains.*14 regional Stores.*228 FU-local Endpoint readers.*208 MEM.*20 MXM/i)
  assert.match(qctl?.function ?? '', /VXM and SXM are not formal QCTL endpoints/i)
  assert.deepEqual(qctl?.definitionNames, ['lpu_qctl_global_subsystem', 'lpu_qctl_load_manager', 'lpu_qctl_relay_chain', 'lpu_qctl_relay', 'lpu_qctl_endpoint', 'lpu_qctl_controller', 'lpu_qctl_fabric', 'lpu_qctl_event_buffer'])
})

test('Instruction DMA is RTL-confirmed while DDR and AXI/C2C remain explicit review boundaries', () => {
  const physical = snapshot.physicalArchitecture
  const blocks = new Map(physical.blocks.map((block) => [block.id, block]))
  assert.equal(blocks.get('physical:control:instruction-dma')?.placementStatus, 'rtl-confirmed')
  assert.equal(blocks.get('physical:control:instruction-dma')?.instanceCount, 1)
  assert.equal(blocks.get('physical:external:instruction-ddr')?.placementStatus, 'needs-review')
  assert.equal(blocks.get('physical:external:instruction-ddr')?.instanceCount, 0)
  assert.equal(blocks.get('physical:external:program-bus')?.placementStatus, 'needs-review')
  assert.match(blocks.get('physical:external:program-bus')?.function ?? '', /Standard AXI AR\/AW\/W\/R\/B channels are not present/)

  const request = physical.interfaces.find((item) => item.id === 'physical-interface:dma:external-request')
  const response = physical.interfaces.find((item) => item.id === 'physical-interface:dma:external-response')
  assert.equal(request?.evidenceStatus, 'rtl-confirmed')
  assert.equal(request?.topologyStatus, 'needs-review')
  assert.ok(request.rawConnectionIds.length > 0)
  assert.equal(response?.evidenceStatus, 'rtl-confirmed')
  assert.equal(response?.topologyStatus, 'needs-review')
  assert.ok(response.rawConnectionIds.length > 0)
})

test('Instruction DMA drilldown exposes both FIFOs, generic boundary and terminal fault check', () => {
  const drill = snapshot.physicalArchitecture.drilldown
  assert.equal(drill.rootNodeIdsByBlock['physical:control:instruction-dma'], 'arch:control:instruction-dma')
  const byId = new Map(drill.nodes.map((node) => [node.id, node]))
  assert.equal(byId.get('arch:control:instruction-dma')?.layout, 'instruction-dma-overview')
  assert.equal(byId.get('arch:control:instruction-dma:outstanding')?.parameterRefs.find((item) => item.name === 'DEPTH')?.value, 16)
  assert.equal(byId.get('arch:control:instruction-dma:response-fifo')?.parameterRefs.find((item) => item.name === 'DATA_WIDTH')?.value, 298)
  assert.match(byId.get('arch:control:instruction-dma:request')?.description ?? '', /No AXI channel semantics/)
  assert.match(byId.get('arch:control:instruction-dma:fault')?.description ?? '', /until reset/)
  assert.ok(drill.interfaces.find((item) => item.id === 'arch:control:instruction-dma:interface:fault')?.rawConnectionIds.length > 0)
})

test('external-memory drilldown identifies testbench response stimulus without promoting it to RTL', () => {
  const nodes = snapshot.physicalArchitecture.drilldown.nodes
  const stimulus = nodes.find((node) => node.id === 'arch:external:instruction-ddr:stimulus')
  assert.equal(stimulus?.confidenceStatus, 'simulation-model-confirmed')
  assert.match(stimulus?.description ?? '', /not a DDR implementation/)
  const adapter = nodes.find((node) => node.id === 'arch:external:program-bus:missing')
  assert.equal(adapter?.confidenceStatus, 'needs-review')
  assert.match(adapter?.description ?? '', /No AXI AR\/AW\/W\/R\/B channel bundle/)
})
