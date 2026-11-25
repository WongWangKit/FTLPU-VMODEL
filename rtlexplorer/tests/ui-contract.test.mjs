import test from 'node:test'
import assert from 'node:assert/strict'
import { promises as fs } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const read = (file) => fs.readFile(path.join(root, file), 'utf8')

test('drill navigation is parent-aware and browser-history backed', async () => {
  const [app, detail] = await Promise.all([read('src/App.tsx'), read('src/components/FunctionalBlockDetail.tsx')])
  assert.match(app, /addEventListener\('popstate'/)
  assert.match(app, /navigateDrillParent/)
  assert.match(app, /window\.history\.back\(\)/)
  assert.match(detail, /current\.parentId \? `返回/)
  assert.doesNotMatch(detail, />← L1<\/button>/)
})

test('hardware specifications are hoverable, keyboard reachable and do not force storage drill pages', async () => {
  const [graph, detail, styles] = await Promise.all([read('src/components/FunctionalConnectivityGraph.tsx'), read('src/components/FunctionalBlockDetail.tsx'), read('src/styles.css')])
  assert.match(graph, /tabIndex=\{0\}/)
  assert.match(graph, /hardware-spec-tooltip/)
  assert.match(detail, /node\.childIds\.length && !isStorageNode\(node\) \? navigate/)
  assert.match(styles, /:focus-visible \.hardware-spec-tooltip/)
  assert.match(detail, /node\.id\.startsWith\('arch:control:qctl'\) && node\.childIds\.length/)
})

test('all shared graph edge renderers retain directed arrow markers', async () => {
  const [functional, physical, hierarchy] = await Promise.all([read('src/components/FunctionalConnectivityGraph.tsx'), read('src/components/PhysicalArchitectureGraph.tsx'), read('src/components/ArchitectureGraph.tsx')])
  for (const source of [functional, physical, hierarchy]) {
    assert.match(source, /markerEnd=\{markerEnd\}/)
    assert.match(source, /MarkerType\.ArrowClosed/)
  }
})

test('top navigation removes the standalone connectivity layer', async () => {
  const [app, types, readme] = await Promise.all([read('src/App.tsx'), read('src/types.ts'), read('README.md')])
  assert.doesNotMatch(app, /value: 'connectivity'/)
  assert.doesNotMatch(app, /label: 'Connectivity'/)
  assert.doesNotMatch(types, /'connectivity'/)
  assert.doesNotMatch(readme, /\*\*Connectivity\*\*/)
  assert.match(app, /connectivityMode=\{false\}/)
})

test('RTL hierarchy top level gives the three real direct instances non-overlapping construction', async () => {
  const graph = await read('src/components/ArchitectureGraph.tsx')
  for (const name of ['u_program_load_system', 'u_program_distribute_system', 'u_fu_subsystems', 'u_qctl_global_subsystem', 'u_mem_subsystem', 'u_sxm_subsystem', 'u_mxm_subsystem', 'u_vxm_subsystem']) assert.match(graph, new RegExp(name))
  assert.match(graph, /rootFrame = focus\.depth === 0/)
  assert.match(graph, /width: 1660, height: 820/)
  assert.match(graph, /u_fu_subsystems: \{ x: 50, y: 330, width: 1560, height: 430 \}/)
})

test('QCTL overview is grouped as distributed load storage and FU-local runtime control', async () => {
  const [graph, model] = await Promise.all([
    read('src/components/FunctionalConnectivityGraph.tsx'),
    read('server/architecture-drilldown-model.mjs'),
  ])
  assert.match(model, /layout: 'qctl-overview'/)
  assert.match(graph, /current\.layout === 'qctl-overview'/)
  assert.match(graph, /QCTL SOURCES \+ DISTRIBUTED RELAY/)
  assert.match(graph, /FU-LOCAL QCTL CONTROL/)
  assert.match(graph, /QCTL DISTRIBUTED RELAY STORE/)
  assert.match(graph, /2 × 7 INDEPENDENT RTL RELAYS · NO BROADCAST BUS/)
  assert.match(graph, /fitView=\{current\.layout === 'qctl-overview' \|\| !savedViewport\}/)
  assert.match(graph, /distribution: \{ x: 20, y: 20, width: 900, height: 490/)
  assert.match(graph, /runtime: \{ x: 20, y: 550, width: 900, height: 460/)
  assert.match(graph, /plan\.labelWidth = \/\(\?:barrier-controller\|event-controller\|controller-packet\)\$\//)
  for (const suffix of [':events', ':load-manager', ':relay-fabric', ':readers', ':controllers', ':counters', ':barrier', ':packet', ':endpoints']) assert.match(graph, new RegExp(suffix.replace(':', '\\:')))
})

test('MXM instruction wave launches into bottom Row0 and highlights real SC rows at stage 0 3 6 9', async () => {
  const [component, styles, model] = await Promise.all([
    read('src/components/MxmFunctionalExplorer.tsx'),
    read('src/styles.css'),
    read('server/architecture-drilldown-model.mjs'),
  ])
  assert.match(component, /const arrivals = \[0, 3, 6, 9\]/)
  assert.match(component, /const pipelineStages = Array\.from\(\{ length: 10 \}/)
  assert.match(component, /rowsTopDown\.map/)
  assert.match(component, /10-STAGE REGISTER PIPELINE/)
  assert.match(component, /INTERMEDIATE REG/)
  assert.match(component, /data-wave-stage=\{stage\}/)
  assert.match(component, /FIRST INSTRUCTION LAUNCH/)
  assert.match(component, /stage 0 捕获/)
  assert.match(component, /row_valid_o\[r\] = valid_q\[r × INTERVAL\]/)
  assert.match(styles, /\.mxm-wave-array-row\.active/)
  assert.match(styles, /\.mxm-wave-stage-register\.active/)
  assert.match(styles, /grid-template-rows: repeat\(10, 72px\)/)
  assert.match(styles, /grid-template-columns: 220px minmax\(680px, 980px\)/)
  assert.match(styles, /width: min\(1220px, 100%\)/)
  assert.match(styles, /\.mxm-wave-launch\.active/)
  assert.match(model, /enters stage 0 beside bottom Row0/)
  assert.match(model, /intermediate register stage 1\/2, 4\/5 and 7\/8/)
  assert.match(model, /stage 3\/6\/9/)
})

test('decoder transition conditions use presentation-size labels', async () => {
  const [physical, styles] = await Promise.all([read('src/components/PhysicalArchitectureGraph.tsx'), read('src/styles.css')])
  assert.match(physical, /fontSize: 16, fontWeight: 900/)
  assert.match(styles, /\.mxm-decoder-edge-label[\s\S]*font: 900 16px/)
})

test('global Program Load keeps controller and relay architecture above FU-local frontend entry points', async () => {
  const [source, app, model, readme] = await Promise.all([read('src/components/PhysicalArchitectureGraph.tsx'), read('src/App.tsx'), read('server/architecture-drilldown-model.mjs'), read('README.md')])
  const y = (id) => Number(source.match(new RegExp(`'${id.replaceAll(':', '\\:')}'[^\\n]+y: (\\d+)`))?.[1])
  assert.ok(y('arch:control:program-load:instruction-dma') < y('arch:control:program-load:elastic'))
  assert.equal(y('arch:control:program-load:elastic'), y('arch:control:program-load:fu-entry'))
  for (const layer of ['L1 · PROGRAM LOAD SYSTEM', 'L2 · PROGRAM DISTRIBUTION SYSTEM']) assert.match(source, new RegExp(layer.replace(/[·]/g, '\\·')))
  assert.doesNotMatch(source, /L3 · FU-LOCAL FRONTENDS/)
  for (const node of ['instruction-dma', 'response', 'assembler', 'word-fifo', 'elastic', 'relay-fabric', 'fu-entry']) assert.match(source, new RegExp(`'arch:control:program-load:${node}'`))
  for (const node of ['write', 'array', 'sequencer', 'config-fifo', 'reservoir', 'word-builder', 'prime-fifo', 'handoff-mux', 'decode', 'west', 'east']) assert.doesNotMatch(source, new RegExp(`'arch:control:program-load:${node}'[^\\n]+y:`))
  for (const node of ['retire', 'boundary']) assert.doesNotMatch(source, new RegExp(`'arch:control:program-load:${node}'[^\\n]+y:`))
  assert.match(source, /type: 'programStage'/)
  assert.match(source, /type: 'programLoad'/)
  assert.match(source, /layoutOrthogonalEdges\(boxes, programEdges/)
  assert.match(source, /Only real functional rectangles are routing obstacles/)
  assert.match(source, /large system\/layer[\s\S]+intentionally absent/)
  assert.match(source, /id\.includes\(':interface:main-'\)/)
  assert.match(source, /physicalEndpointId/)
  assert.match(source, /programRelayFabricId/)
  assert.match(app, /drillNodes=\{snapshot\.physicalArchitecture\.drilldown\.nodes\}/)
  assert.match(app, /drillInterfaces=\{snapshot\.physicalArchitecture\.drilldown\.interfaces\}/)
  assert.match(readme, /禁止使用斜线箭头/)
  assert.match(readme, /节点、接口标签、箭头头部、分组标题和说明文字不得互相覆盖/)
  assert.match(model, /Word FIFO Dequeue \+ Route Metadata/)
  assert.match(model, /Distributor Input Handshake/)
  assert.match(model, /program-relay-fabric/)
  assert.match(model, /Two RTL-confirmed seven-stage chains/)
  assert.match(model, /u_program_load_system is a direct top-level subsystem/)
  assert.match(model, /u_program_distribute_system is a direct top-level sibling/)
  assert.match(model, /SXM \/ VXM Program Boundary/)
  assert.match(model, /interface:endpoint-boundary/)
  assert.match(model, /R6 also forwards the outer MXM\/SXM record/i)
  assert.match(model, /Boundary Connected/)
  assert.match(model, /Endpoint Not Integrated/)
  assert.match(model, /Program Reset \/ Transport Flush/)
  assert.match(source, /blocked-boundary/)
  assert.match(model, /complete 165-bit record/)
  assert.match(model, /1-bit control domain contains only WRITE=0 and PRIME=1/)
  assert.match(model, /165-bit/)
})

test('primary physical topology removes obsolete Router cards and routes Program Load through the integrated Relay fabric', async () => {
  const [source, model] = await Promise.all([read('src/components/PhysicalArchitectureGraph.tsx'), read('server/physical-architecture-model.mjs')])
  assert.match(source, /if \(item\.direction === 'program-load' && \/\^physical:\(west\|east\):\//)
  assert.match(source, /return programRelayFabricId/)
  assert.match(source, /Relay Chain → FU Frontend \/ local iMEM/)
  assert.match(source, /Elastic Stage → VXM Boundary/)
  assert.doesNotMatch(source, /physical:control:(west-router|east-router)/)
  assert.doesNotMatch(model, /physical:control:(west-router|east-router)/)
  assert.doesNotMatch(model, /physical-interface:program:(west-branch|east-branch)/)
})

test('FU overview graphs keep nested RTL detail behind direct stage drilldown', async () => {
  const detail = await read('src/components/FunctionalBlockDetail.tsx')
  assert.match(detail, /\['mxm', 'sxm', 'vxm'\]\.includes\(block\.kind\)/)
  assert.match(detail, /directChildIds\.has\(item\.sourceNodeId\) && directChildIds\.has\(item\.destinationNodeId\)/)
  assert.match(detail, /interfaces: stageInterfaces/)
})

test('public snapshot loading bypasses stale CDN and browser caches', async () => {
  const app = await read('src/App.tsx')
  assert.match(app, /architecture-snapshot\.json\?v=\$\{Date\.now\(\)\}/)
  assert.match(app, /cache: 'no-store'/)
})

test('semantic interface aliases and interactive evidence popovers are shared by physical and functional graphs', async () => {
  const [physical, functional, popover, tooltip, semanticConfig, styles] = await Promise.all([
    read('src/components/PhysicalArchitectureGraph.tsx'),
    read('src/components/FunctionalConnectivityGraph.tsx'),
    read('src/components/InteractiveInterfaceLabel.tsx'),
    read('src/components/InterfaceEvidenceTooltip.tsx'),
    read('data/interface-semantics.json'),
    read('src/styles.css'),
  ])
  assert.match(physical, /interfaceSemanticPresentation/)
  assert.match(functional, /interfaceSemanticPresentation/)
  assert.match(physical, /InteractiveInterfaceLabel/)
  assert.match(functional, /InteractiveInterfaceLabel/)
  assert.match(popover, /setPinned/)
  assert.match(popover, /pointerdown/)
  assert.match(popover, /Escape/)
  assert.match(popover, /onMouseLeave=\{\(\) => \{ suppressReopen\.current = false; scheduleClose\(\) \}\}/)
  assert.match(tooltip, /rawConnections\.slice\(0, 8\)\.map/)
  assert.match(styles, /interface-evidence-tooltip/)
  const aliases = JSON.parse(semanticConfig).aliases
  assert.equal(aliases.find((item) => item.semantic_id === 'mxm-local-imem-load')?.display_name, 'MXM Local iMEM Load')
})

test('Bus Detail uses semantic display names, meanings and secondary RTL names', async () => {
  const [detail, presentation, styles] = await Promise.all([
    read('src/components/BusDetailView.tsx'),
    read('src/lib/signal-presentation.ts'),
    read('src/styles.css'),
  ])
  for (const name of ['Word Strobe / Mask', 'Scope / 13-bit Destination / iMEM Address', 'Program Word Payload', 'Handshake']) assert.match(presentation, new RegExp(name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
  assert.match(presentation, /rtlName/)
  assert.match(presentation, /meaning/)
  assert.match(detail, /bus-signal-name/)
  assert.match(detail, /selectedSignalPresentation\.meaning/)
  assert.match(detail, /PROGRAM LOAD ROUTE CONTRACT/)
  assert.match(detail, /PROGRAM LOAD RELAY CONTRACT/)
  assert.match(detail, /one registered boundary with skid capacity/i)
  assert.match(detail, /Target initiation interval: II=1/)
  assert.match(styles, /interface-popover-anchor\.is-open/)
})

test('shared route requests declare plane, line style and routing lanes', async () => {
  const [engine, physical, functional] = await Promise.all([
    read('src/lib/graph-layout-engine.ts'),
    read('src/components/PhysicalArchitectureGraph.tsx'),
    read('src/components/FunctionalConnectivityGraph.tsx'),
  ])
  assert.match(engine, /lineStyle\?: 'solid' \| 'dashed'/)
  assert.match(engine, /solidDashedEdgeOverlaps/)
  assert.match(engine, /arrowArrowOverlaps/)
  assert.match(physical, /lineStyle: item\.plane === 'status'/)
  assert.match(functional, /routingLane: edgeIndex % 6/)
})
