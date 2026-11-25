import { memo, useMemo, useState } from 'react'
import {
  Background,
  Controls,
  Handle,
  MarkerType,
  MiniMap,
  Position,
  ReactFlow,
  type Edge,
  type Node,
  type NodeProps,
} from '@xyflow/react'
import type {
  ConfigurationComposition,
  ConfigurationEvidence,
  ConfigurationOverviewModel,
  ConfigurationUnit,
} from '../types'

const numberText = (value: number | null | undefined) => value == null ? 'Needs Review' : value.toLocaleString('en-US')

function EvidenceLine({ item }: { item: ConfigurationEvidence }) {
  return <li><code>{item.symbol}</code><span>{item.expression}</span><small>{item.file}:{item.line}</small></li>
}

function RepeatGlyph({ count }: { count: number | null }) {
  const cells = Math.max(1, Math.min(count ?? 1, 18))
  return <div className="configuration-repeat-glyph" aria-label={count === null ? '数量待确认' : `${count} repeated units`}>
    <span>{Array.from({ length: cells }, (_, index) => <i key={index} />)}</span>
    <b>{count === null ? '?' : `×${numberText(count)}`}</b>
  </div>
}

interface ConfigurationFrameData extends Record<string, unknown> {
  composition: ConfigurationComposition
}

interface ConfigurationUnitData extends Record<string, unknown> {
  unit: ConfigurationUnit
  selected: boolean
  onSelect: (unitId: string) => void
}

const ConfigurationFrameNode = memo(({ data }: NodeProps<Node<ConfigurationFrameData>>) => <section className={`configuration-fu-frame fu-${data.composition.fu}`}>
  <header><span>FU COMPOSITION CONTAINER</span><strong>{data.composition.name} · 规模与组成</strong><b>×{numberText(data.composition.instanceCount)} / LPU</b></header>
  <small>所有数量默认按单个 FU 实例统计；右侧 Inspector 同时给出全芯片总量。</small>
</section>)
ConfigurationFrameNode.displayName = 'ConfigurationFrameNode'

const ConfigurationUnitNode = memo(({ data }: NodeProps<Node<ConfigurationUnitData>>) => <button
  type="button"
  className={`configuration-unit-node resource-${data.unit.category} ${data.selected ? 'selected' : ''}`}
  data-config-status={data.unit.status}
  data-config-unit-id={data.unit.id}
  onPointerDown={(event) => {
    event.stopPropagation()
    data.onSelect(data.unit.id)
  }}
  onMouseEnter={() => data.onSelect(data.unit.id)}
  onFocus={() => data.onSelect(data.unit.id)}
  onClick={() => data.onSelect(data.unit.id)}
>
  <Handle type="target" position={Position.Top} />
  <div><span>{data.unit.unitType}</span><strong>{data.unit.name}</strong></div>
  <RepeatGlyph count={data.unit.count} />
  <em>{data.unit.status === 'needs-review' ? 'NEEDS REVIEW' : 'RTL'}</em>
  <Handle type="source" position={Position.Bottom} />
</button>)
ConfigurationUnitNode.displayName = 'ConfigurationUnitNode'

const compositionNodeTypes = { frame: ConfigurationFrameNode, configurationUnit: ConfigurationUnitNode }

function buildFuCompositionFlow(composition: ConfigurationComposition, selectedUnitId: string, onSelect: (unitId: string) => void) {
  const tiers = new Map<number, ConfigurationUnit[]>()
  for (const unit of composition.units) {
    const tier = unit.tier ?? 0
    tiers.set(tier, [...(tiers.get(tier) ?? []), unit])
  }
  const tierEntries = [...tiers.entries()].sort(([left], [right]) => left - right)
  const maximumColumns = Math.max(1, ...tierEntries.map(([, units]) => units.length))
  const frameWidth = Math.max(1180, maximumColumns * 310 + 180)
  const frameHeight = Math.max(620, tierEntries.length * 170 + 150)
  const nodes: Node[] = [{
    id: `${composition.id}:frame`, type: 'frame', position: { x: 0, y: 0 },
    style: { width: frameWidth, height: frameHeight }, data: { composition },
    draggable: false, selectable: false, zIndex: -1,
  }]
  for (const [tierIndex, units] of tierEntries) {
    const rowWidth = units.length * 280 + Math.max(0, units.length - 1) * 30
    const startX = (frameWidth - rowWidth) / 2
    units.forEach((unit, index) => nodes.push({
      id: unit.id, type: 'configurationUnit',
      position: { x: startX + index * 310, y: 105 + tierIndex * 170 },
      style: { width: 280, height: 108 },
      data: { unit, selected: selectedUnitId === unit.id, onSelect },
      draggable: false, selectable: false,
    }))
  }
  const edges: Edge[] = composition.links.map((link) => ({
    id: link.id, source: link.sourceUnitId, target: link.targetUnitId,
    type: 'smoothstep', label: link.label,
    className: `configuration-composition-edge ${link.status === 'needs-review' ? 'needs-review' : ''}`,
    style: { stroke: link.status === 'needs-review' ? '#8b6bab' : '#172b57', strokeWidth: 3 },
    markerEnd: { type: MarkerType.ArrowClosed, color: link.status === 'needs-review' ? '#8b6bab' : '#172b57' },
    labelStyle: { fill: '#172b57', fontSize: 11, fontWeight: 750 },
    labelBgStyle: { fill: '#f8fbfd', stroke: '#172b57', strokeWidth: 1.5 },
    labelBgPadding: [6, 4], labelBgBorderRadius: 0,
  }))
  return { nodes, edges }
}

function FuCompositionExplorer({ model }: { model: ConfigurationOverviewModel }) {
  const compositions = model.compositions.filter((item) => ['sxm', 'vxm', 'mxm'].includes(item.id))
  const [activeId, setActiveId] = useState(compositions[0]?.id ?? 'sxm')
  const active = compositions.find((item) => item.id === activeId) ?? compositions[0]
  const [selectedUnitId, setSelectedUnitId] = useState(active?.units[0]?.id ?? '')
  const selectedUnit = active?.units.find((unit) => unit.id === selectedUnitId) ?? active?.units[0]
  const flow = useMemo(() => active ? buildFuCompositionFlow(active, selectedUnit?.id ?? '', setSelectedUnitId) : { nodes: [], edges: [] }, [active, selectedUnit?.id])
  if (!active || !selectedUnit) return null
  const systemTotal = selectedUnit.count === null || active.instanceCount === null ? null : selectedUnit.count * active.instanceCount
  const activate = (composition: ConfigurationComposition) => {
    setActiveId(composition.id)
    setSelectedUnitId(composition.units[0]?.id ?? '')
  }
  return <section className="configuration-section configuration-composition-explorer">
    <div className="configuration-section-heading configuration-mode-heading"><div><span>FU STRUCTURE / SCALE</span><h2>SXM · VXM · MXM 独立组成画布</h2></div><small>滚轮缩放 · 拖拽平移 · 点击单元查看 RTL 参数</small></div>
    <div className="configuration-palette"><span><i className="resource-storage" />Storage / Buffer</span><span><i className="resource-interface" />Interface / Register</span><span><i className="resource-compute" />Compute Array</span><span><i className="resource-control" />Control</span></div>
    <nav className="configuration-fu-tabs" aria-label="Select FU composition">{compositions.map((composition) => <button key={composition.id} type="button" className={active.id === composition.id ? 'active' : ''} onClick={() => activate(composition)}>{composition.name} · ×{numberText(composition.instanceCount)} / LPU</button>)}</nav>
    <div className="configuration-explorer-shell">
      <div
        className="configuration-reactflow"
        data-configuration-mode="fu-composition"
        data-fu={active.fu}
        onPointerDownCapture={(event) => {
          const unitId = (event.target as HTMLElement).closest<HTMLElement>('[data-config-unit-id]')?.dataset.configUnitId
          if (unitId) setSelectedUnitId(unitId)
        }}
        onMouseOverCapture={(event) => {
          const unitId = (event.target as HTMLElement).closest<HTMLElement>('[data-config-unit-id]')?.dataset.configUnitId
          if (unitId) setSelectedUnitId(unitId)
        }}
        onFocusCapture={(event) => {
          const unitId = (event.target as HTMLElement).closest<HTMLElement>('[data-config-unit-id]')?.dataset.configUnitId
          if (unitId) setSelectedUnitId(unitId)
        }}
      >
        <ReactFlow
          nodes={flow.nodes}
          edges={flow.edges}
          nodeTypes={compositionNodeTypes}
          nodesDraggable={false}
          nodesConnectable={false}
          elementsSelectable={false}
          onNodeClick={(_, node) => {
            if (node.type === 'configurationUnit') setSelectedUnitId(node.id)
          }}
          onNodeMouseEnter={(_, node) => {
            if (node.type === 'configurationUnit') setSelectedUnitId(node.id)
          }}
          minZoom={0.25}
          maxZoom={2.4}
          fitView
          fitViewOptions={{ padding: .08, maxZoom: .9 }}
          proOptions={{ hideAttribution: true }}
          colorMode="light"
        >
          <Background color="#cbd4e1" gap={22} size={1} /><MiniMap pannable zoomable nodeColor="#dcebf9" maskColor="rgba(235,239,245,.7)" /><Controls showInteractive={false} />
        </ReactFlow>
      </div>
      <aside className="configuration-inspector">
        <header className="configuration-inspector-heading"><span>{active.name} RESOURCE INSPECTOR</span><h3>{selectedUnit.name}</h3><b className={`configuration-status status-${selectedUnit.status}`}>{selectedUnit.status}</b></header>
        <div className="configuration-inspector-body">
          <section><span>单个 {active.name}</span><strong>{numberText(selectedUnit.count)}</strong><p>{selectedUnit.expression}</p></section>
          <section><span>全 LPU 总量</span><strong>{numberText(systemTotal)}</strong><p>{numberText(active.instanceCount)} 个 {active.name} 实例 × 单实例数量；“每 Tile / 每 Block”单元保持其局部口径。</p></section>
          <section><span>结构角色</span><code>{selectedUnit.unitType} · {selectedUnit.category}</code>{selectedUnit.detail && <p>{selectedUnit.detail}</p>}</section>
          <section className="configuration-inspector-evidence"><span>RTL EVIDENCE</span>{selectedUnit.evidence.map((item, index) => <div key={`${item.file}:${item.line}:${index}`}><code>{item.file}:{item.line}</code><p>{item.symbol}</p><small>{item.expression}</small></div>)}</section>
        </div>
      </aside>
    </div>
  </section>
}

interface HemisphereFrameData extends Record<string, unknown> {
  name: string
  summary: string
}

interface MemFuData extends Record<string, unknown> {
  name: string
  groups: number
  slicesPerGroup: number
  banksPerSlice: number
  leavesPerBank: number
  issuePaths: number
  streamRegisterColumns: number
  packageStreamRegisterColumns: number
  memMappedStreamBoundaries: number
  streamRegisterStatus: string
  relayPrefix: 'W' | 'E'
  relayStages: ConfigurationOverviewModel['programLoad']['relay']['stages']
  clusterAdapter: string
}

interface SxmFuData extends Record<string, unknown> {
  name: string
  sources: number
  slots: number
  programBoundary: ConfigurationOverviewModel['programLoad']['endpointBoundaries'][number]
}

interface MxmFuData extends Record<string, unknown> {
  name: string
  localIndex: number
  supercells: number
  multipliers: number
  backendBanks: number
}

interface VxmFuData extends Record<string, unknown> {
  name: string
  tiles: number
  stages: number
  lanes: number
  lutFunctions: number
  lutSrams: number
  programBoundary: ConfigurationOverviewModel['programLoad']['endpointBoundaries'][number]
}

function ProgramBoundaryChain({ boundary }: { boundary: ConfigurationOverviewModel['programLoad']['endpointBoundaries'][number] }) {
  return <div className="lpu-program-boundary-chain" data-status={boundary.status}>
    <div><strong>{boundary.boundaryStatus}</strong><span>{boundary.route}</span></div>
    <b>{boundary.boundary}</b>
    <em>{boundary.ready} · {boundary.commit}</em>
    <i>MISSING · {boundary.missingAdapter}</i>
    <small>{boundary.frontendStatus} · not connected to Program Load</small>
  </div>
}

function FuHandles() {
  return <>
    <Handle className="lpu-topology-handle" id="left" type="target" position={Position.Left} />
    <Handle className="lpu-topology-handle" id="right" type="source" position={Position.Right} />
  </>
}

const HemisphereFrameNode = memo(({ data }: NodeProps<Node<HemisphereFrameData>>) => <section className="lpu-hemisphere-frame">
  <header><strong>{data.name} HEMISPHERE</strong><span>{data.summary}</span></header>
</section>)
HemisphereFrameNode.displayName = 'HemisphereFrameNode'

const MemFuNode = memo(({ data }: NodeProps<Node<MemFuData>>) => {
  const groups = Array.from({ length: data.groups }, (_, group) => group)
  const slices = Array.from({ length: data.slicesPerGroup }, (_, slice) => slice)
  const banks = Array.from({ length: data.banksPerSlice }, (_, bank) => bank)
  const leaves = Array.from({ length: data.leavesPerBank }, (_, leaf) => leaf)
  return <article className="lpu-fu-node lpu-mem-fu" data-fu-kind="mem">
    <FuHandles />
    <header><strong>{data.name}</strong><b>RTL CONFIRMED</b></header>
    <div className="lpu-mem-relay-regions" data-relay-count={data.relayStages.length}>
      {data.relayStages.map((stage) => {
        const localGroups = groups.filter((group) => group >= stage.groupStart && group <= stage.groupEnd).reverse()
        const visualColumn = data.groups - stage.groupEnd
        return <section className="lpu-mem-relay-region" key={stage.index} style={{ gridColumn: `${visualColumn} / span ${stage.groupEnd - stage.groupStart + 1}` }}>
          <div className="lpu-mem-relay-groups" style={{ gridTemplateColumns: `repeat(${localGroups.length}, minmax(0, 1fr))` }}>
            {localGroups.map((group) => <section className="lpu-mem-mini-group" key={group}>
              <header>G{group}</header>
              <div className="lpu-mem-mini-slices">{slices.map((slice) => <div className="lpu-mem-mini-slice" key={slice} title={`Group ${group} · Slice ${group * data.slicesPerGroup + slice}`}>
                <small>S{slice}</small>
                <div>{banks.map((bank) => {
                  const localBank = group * data.slicesPerGroup * data.banksPerSlice + slice * data.banksPerSlice + bank
                  return <span className="lpu-mem-bank-fq-path" key={bank} title={`${data.relayPrefix}${stage.index} local ownership · Bank/FQ ${localBank}`}>
                    <b>B{bank}</b>
                    <span className="lpu-mem-mini-bank">{leaves.map((leaf) => <i key={leaf} title={`Bank ${localBank} · SRAM Leaf ${leaf}`} />)}</span>
                    <i>↑</i><em>FQ{localBank}</em>
                  </span>
                })}</div>
              </div>)}</div>
            </section>)}
          </div>
          <div className="lpu-mem-relay-fanout" style={{ gridTemplateColumns: `repeat(${stage.bankCount}, minmax(0, 1fr))` }} aria-label={`${data.relayPrefix}${stage.index} Relay to ${stage.bankCount} local FQ frontends`}>
            {Array.from({ length: stage.bankCount }, (_, localIndex) => <i key={localIndex} title={`${data.relayPrefix}${stage.index} → FQ${stage.bankStart + localIndex}`} />)}
          </div>
          <div className="lpu-mem-relay-register" data-terminal={stage.index === data.relayStages.length - 1 ? 'true' : 'false'} title="Independent Relay Local Program Port with two-entry registered transport">
            <strong>{data.relayPrefix}{stage.index}</strong><span>ELASTIC RELAY REGISTER · LOCAL PROGRAM PORT</span><b>2-entry</b>
          </div>
        </section>
      })}
    </div>
  </article>
})
MemFuNode.displayName = 'MemFuNode'

const SxmFuNode = memo(({ data }: NodeProps<Node<SxmFuData>>) => {
  return <article className="lpu-fu-node lpu-sxm-fu" data-fu-kind="sxm">
    <FuHandles />
    <header><div><span>SXM · NATIVE PROGRAM PATH</span><strong>{data.name}</strong></div><b>FORMAL FU CLUSTER · INTEGRATED</b></header>
    <div className="lpu-not-integrated-strip">R6 OUTER LOCAL → TARGET 5 CTRL / TARGET 6 EXEC · 2 × 64-EVENT CALENDARS</div>
    <div className="lpu-sxm-triangle-flow">
      <section className="lpu-sxm-triangle-core"><header>Native ROW Core</header><small>CAP → P → RUN · {data.sources} sources · {data.slots} slots</small><div>{Array.from({ length: data.sources }, (_, source) => <span key={source}><b>S{source}</b>{Array.from({ length: source + 1 }, (_, slot) => <i key={slot} title={`S${source} slot ${slot}`} />)}</span>)}</div></section>
      <em>→</em>
      <section><header>Shared Storage</header><small>10 × 8×8×32-bit slots / Hemisphere</small></section>
      <em>→</em>
      <section><header>Stream Boundary</header><small>MEM ↔ SXM ↔ MXM</small></section>
    </div>
    <div className="lpu-sxm-test-boundary"><strong>Separate batch WriteTap</strong><span>lpu_sxm_subsystem · independent path</span><small>not the native Program endpoint</small></div>
    <footer>Unconsumed pass-through streams gain one registered cycle at the SXM boundary. Older cross-FU static schedules need separate regression.</footer>
  </article>
})
SxmFuNode.displayName = 'SxmFuNode'

const MxmFuNode = memo(({ data }: NodeProps<Node<MxmFuData>>) => <article className="lpu-fu-node lpu-mxm-fu" data-fu-kind="mxm">
  <FuHandles />
  <header><div><span>MXM</span><strong>{data.name}</strong></div><b>RTL CONFIRMED</b></header>
  <div className="lpu-integrated-strip">PROGRAM LOAD · R6 OUTER LOCAL → MXM ENDPOINT · INTEGRATED</div>
  <div className="lpu-mxm-frontends">{['LOAD', 'COMPUTE', 'DEQUANT', 'PARAM LOAD', 'BACKEND'].map((name) => <span key={name}><strong>{name} FRONTEND</strong><i>↓</i><b>QCTL → NATIVE PORT</b></span>)}</div>
  <div className="lpu-control-arrow">↓ DIRECT READY / VALID · NO POST-SCHEDULER INSTRUCTION QUEUE</div>
  <div className="lpu-mxm-execution"><span><b>4-ROW CONTROL WAVES</b><small>LOAD · COMPUTE · DEQUANT · PARAM</small></span><span className="lpu-mxm-compute-confirmed"><b>4×4 SUPERCELL ARRAY</b><small>{data.supercells} SC · 8 GROUP / SC</small><em>{data.multipliers} BF16 multipliers / MXM</em></span><span><b>COLUMN BACKEND</b><small>{data.backendBanks} LOGICAL 1RW BANKS</small></span></div>
  <footer>MXM local index {data.localIndex} · five independent ICU streams · shared Decoder architecture, independent state</footer>
</article>)
MxmFuNode.displayName = 'MxmFuNode'

const VxmFuNode = memo(({ data }: NodeProps<Node<VxmFuData>>) => {
  const executionCells = data.stages * data.lanes
  const lutCellsPerTile = Math.max(1, Math.floor(data.lutSrams / Math.max(1, data.tiles)))
  return <article className="lpu-fu-node lpu-vxm-fu" data-fu-kind="vxm">
    <Handle className="lpu-topology-handle" id="left-west" type="target" position={Position.Left} style={{ top: '32%' }} />
    <Handle className="lpu-topology-handle" id="left-east" type="target" position={Position.Left} style={{ top: '68%' }} />
    <header><div><span>VXM</span><strong>{data.name}</strong></div><b>RTL CONFIRMED</b></header>
    <div className="lpu-not-integrated-strip">PROGRAM LOAD · CENTRAL DIRECT BOUNDARY CONNECTED · ENDPOINT NOT INTEGRATED</div>
    <ProgramBoundaryChain boundary={data.programBoundary} />
    <div className="lpu-vxm-control">VECTOR CONTROL · 8 LOCAL CONFIG QUEUES → 16 MIRRORED STAGES</div>
    <div className="lpu-control-arrow">↓ CONFIGURATION / EXECUTE</div>
    <div className="lpu-vxm-tiles">{Array.from({ length: data.tiles }, (_, tile) => <section key={tile}>
      <header>TILE / SUPERLANE {tile}</header>
      <div className="lpu-vxm-matrix"><b>EXECUTION · {data.stages} STAGE × {data.lanes} LANE</b><span style={{ gridTemplateColumns: `repeat(${data.stages}, 1fr)` }}>{Array.from({ length: executionCells }, (_, cell) => <i key={cell} />)}</span></div>
      <div className="lpu-vxm-lut"><b>LUT · {data.lutFunctions} FUNCTION × {data.lanes} LANE</b><span style={{ gridTemplateColumns: `repeat(${data.lanes}, 1fr)` }}>{Array.from({ length: lutCellsPerTile }, (_, cell) => <i key={cell} />)}</span></div>
    </section>)}</div>
    <div className="lpu-vxm-resource-detail"><span><b>EXP</b>26 bit × 64</span><span><b>RECIP</b>32 bit × 64</span><span><b>RSQRT</b>32 bit × 64</span><span><b>LOG</b>50 bit × 64</span></div>
    <footer>{data.tiles} Tiles · {data.tiles * data.lanes} Lanes · {data.tiles * executionCells} ALU positions · {data.lutSrams} logical single-read LUT SRAMs</footer>
  </article>
})
VxmFuNode.displayName = 'VxmFuNode'

const lpuTopologyNodeTypes = {
  lpuHemisphereFrame: HemisphereFrameNode,
  lpuMemFu: MemFuNode,
  lpuSxmFu: SxmFuNode,
  lpuMxmFu: MxmFuNode,
  lpuVxmFu: VxmFuNode,
}

function unitCount(model: ConfigurationOverviewModel, compositionId: string, unitId: string, fallback: number) {
  return model.compositions.find((item) => item.id === compositionId)?.units.find((item) => item.id === unitId)?.count ?? fallback
}

function buildLpuTopologyModel(model: ConfigurationOverviewModel) {
  const memData = {
    groups: model.memArray.groupsPerMem ?? 13,
    slicesPerGroup: model.memArray.columnsPerGroup ?? 4,
    banksPerSlice: model.memArray.banksPerColumn ?? 2,
    leavesPerBank: model.memArray.leafSramsPerBank ?? 4,
    issuePaths: model.memArray.banksPerMem ?? 104,
    streamRegisterColumns: model.memArray.streamRegisterColumns ?? 16,
    packageStreamRegisterColumns: model.memArray.streamRegisterPackageColumns ?? 15,
    memMappedStreamBoundaries: model.memArray.streamRegisterMemBoundaries ?? 14,
    streamRegisterStatus: model.memArray.streamRegisterStatus ?? 'needs-review',
  }
  const sxmData = {
    sources: unitCount(model, 'sxm', 'sxm-triangle-sources', 4),
    slots: unitCount(model, 'sxm', 'sxm-triangle-slots', 10),
    programBoundary: model.programLoad.endpointBoundaries.find((item) => item.id === 'sxm')!,
  }
  const vxmData = {
    tiles: unitCount(model, 'vxm', 'vxm-tiles', 4),
    stages: unitCount(model, 'vxm', 'vxm-alus', 16),
    lanes: unitCount(model, 'vxm', 'vxm-lanes', 8),
    lutFunctions: 4,
    lutSrams: unitCount(model, 'vxm', 'vxm-lut', 128),
    programBoundary: model.programLoad.endpointBoundaries.find((item) => item.id === 'vxm')!,
  }
  const mxmData = {
    supercells: unitCount(model, 'mxm', 'mxm-supercells', 16),
    multipliers: unitCount(model, 'mxm', 'mxm-multipliers', 1024),
    backendBanks: unitCount(model, 'mxm', 'mxm-backend-banks', 8),
  }
  const nodes: Node[] = [
    { id: 'hemisphere-west', type: 'lpuHemisphereFrame', position: { x: 0, y: 0 }, style: { width: 8500, height: 1100 }, data: { name: 'WEST · UPPER ROW', summary: '2 parallel MXM ↔ native SXM ↔ MEM · formal Program/ROW integrated' }, draggable: false, selectable: false, zIndex: -2 },
    { id: 'hemisphere-east', type: 'lpuHemisphereFrame', position: { x: 0, y: 1200 }, style: { width: 8500, height: 1100 }, data: { name: 'EAST · LOWER ROW', summary: '2 parallel MXM ↔ native SXM ↔ MEM · formal Program/ROW integrated' }, draggable: false, selectable: false, zIndex: -2 },
    { id: 'mxm-west-0', type: 'lpuMxmFu', position: { x: 100, y: 180 }, style: { width: 1260, height: 370 }, data: { name: 'MXM WEST 0', localIndex: 0, ...mxmData }, draggable: false, selectable: false },
    { id: 'mxm-west-1', type: 'lpuMxmFu', position: { x: 100, y: 660 }, style: { width: 1260, height: 370 }, data: { name: 'MXM WEST 1', localIndex: 1, ...mxmData }, draggable: false, selectable: false },
    { id: 'mem-west', type: 'lpuMemFu', position: { x: 1550, y: 200 }, style: { width: 5000, height: 600 }, data: { name: 'MEM WEST', relayPrefix: 'W', relayStages: model.programLoad.relay.stages, clusterAdapter: model.programLoad.relay.clusterAdapter, ...memData }, draggable: false, selectable: false },
    { id: 'sxm-west', type: 'lpuSxmFu', position: { x: 6720, y: 240 }, style: { width: 1600, height: 520 }, data: { name: 'SXM WEST · NATIVE ROW SUBSYSTEM', ...sxmData }, draggable: false, selectable: false },
    { id: 'mxm-east-0', type: 'lpuMxmFu', position: { x: 100, y: 1380 }, style: { width: 1260, height: 370 }, data: { name: 'MXM EAST 0', localIndex: 0, ...mxmData }, draggable: false, selectable: false },
    { id: 'mxm-east-1', type: 'lpuMxmFu', position: { x: 100, y: 1860 }, style: { width: 1260, height: 370 }, data: { name: 'MXM EAST 1', localIndex: 1, ...mxmData }, draggable: false, selectable: false },
    { id: 'mem-east', type: 'lpuMemFu', position: { x: 1550, y: 1400 }, style: { width: 5000, height: 600 }, data: { name: 'MEM EAST', relayPrefix: 'E', relayStages: model.programLoad.relay.stages, clusterAdapter: model.programLoad.relay.clusterAdapter, ...memData }, draggable: false, selectable: false },
    { id: 'sxm-east', type: 'lpuSxmFu', position: { x: 6720, y: 1440 }, style: { width: 1600, height: 520 }, data: { name: 'SXM EAST · NATIVE ROW SUBSYSTEM', ...sxmData }, draggable: false, selectable: false },
    { id: 'vxm-central', type: 'lpuVxmFu', position: { x: 8700, y: 1140 }, style: { width: 3100, height: 580 }, data: { name: 'VXM CENTRAL · ON-CHIP BISECTION', ...vxmData }, draggable: false, selectable: false },
  ]
  const streamEdge = (id: string, source: string, target: string, label: string): Edge => ({
    id, source, target, sourceHandle: 'right', targetHandle: 'left', type: 'smoothstep', label,
    className: 'lpu-topology-stream-edge',
    style: { stroke: '#459f9c', strokeWidth: 8 },
    markerStart: { type: MarkerType.ArrowClosed, color: '#459f9c', width: 18, height: 18 },
    markerEnd: { type: MarkerType.ArrowClosed, color: '#459f9c', width: 18, height: 18 },
    labelStyle: { fill: '#17355c', fontSize: 22, fontWeight: 800 },
    labelBgStyle: { fill: '#f8fbfd', stroke: '#17355c', strokeWidth: 2 },
    labelBgPadding: [10, 6], labelBgBorderRadius: 0,
  })
  const edges = [
    streamEdge('stream-west-mxm0-mem', 'mxm-west-0', 'mem-west', 'TRANSPARENT FU-CLUSTER BOUNDARY · NOT TRIANGLE EXECUTION'),
    streamEdge('stream-west-mxm1-mem', 'mxm-west-1', 'mem-west', 'TRANSPARENT FU-CLUSTER BOUNDARY · NOT TRIANGLE EXECUTION'),
    { ...streamEdge('stream-west-mem-vxm', 'mem-west', 'vxm-central', 'SRF · MEM West ↔ VXM'), targetHandle: 'left-west' },
    { ...streamEdge('stream-east-mem-vxm', 'mem-east', 'vxm-central', 'SRF · MEM East ↔ VXM'), targetHandle: 'left-east' },
    streamEdge('stream-east-mxm0-mem', 'mxm-east-0', 'mem-east', 'TRANSPARENT FU-CLUSTER BOUNDARY · NOT TRIANGLE EXECUTION'),
    streamEdge('stream-east-mxm1-mem', 'mxm-east-1', 'mem-east', 'TRANSPARENT FU-CLUSTER BOUNDARY · NOT TRIANGLE EXECUTION'),
  ]
  return { nodes, edges, fuCount: 9 }
}

function ConfigurationCanvas({ model }: { model: ConfigurationOverviewModel }) {
  const topology = useMemo(() => buildLpuTopologyModel(model), [model])
  return <section className="configuration-section configuration-visualization">
    <div className="configuration-section-heading configuration-panorama-heading"><div><span>LPU RESOURCE / CONTROL TOPOLOGY</span><h2>完整 LPU 组织 · 上排 West / 下排 East · 9 FU Instances</h2></div><div className="configuration-panorama-help"><strong>滚轮缩放 · 拖拽平移</strong><small>使用左下角 FIT 恢复全局视角</small></div></div>
    <div className="configuration-topology-facts"><strong>{topology.fuCount} ARCHITECTURAL FU POSITIONS</strong><span>UPPER · WEST</span><span>LOWER · EAST</span><span>2 MEM</span><span>2 SXM NATIVE · INTEGRATED</span><span>4 MXM</span><span>1 CENTRAL VXM</span><span>14 PROGRAM RELAYS</span><span>MXM pairs are parallel, not serial</span></div>
    <div className="configuration-palette"><span><i className="resource-storage" />Buffer / Storage</span><span><i className="resource-interface" />Interface / Stream</span><span><i className="resource-compute" />Compute</span><span><i className="resource-control" />Control / Decode</span><span><b>↔</b>Bidirectional data stream</span></div>
    <div className="configuration-panorama-flow configuration-lpu-topology-flow configuration-reactflow" data-configuration-mode="lpu" data-hemisphere-layout="stacked-rows" data-lpu-fu-count={topology.fuCount}>
      <ReactFlow nodes={topology.nodes} edges={topology.edges} nodeTypes={lpuTopologyNodeTypes} nodesDraggable={false} nodesConnectable={false} elementsSelectable={false} minZoom={0.08} maxZoom={2.8} fitView fitViewOptions={{ padding: 0.025, maxZoom: 0.46 }} proOptions={{ hideAttribution: true }} colorMode="light">
        <Background color="#cbd4e1" gap={24} size={1} />
        <MiniMap pannable zoomable position="bottom-right" nodeColor={(node) => node.type === 'lpuMemFu' ? '#fff0c9' : node.type === 'lpuSxmFu' ? '#e3f2e2' : node.type === 'lpuMxmFu' ? '#f7e2d2' : node.type === 'lpuVxmFu' ? '#dcebf9' : '#eef2f8'} maskColor="rgba(235,239,245,.72)" />
        <Controls showInteractive={false} />
      </ReactFlow>
    </div>
    <p className="configuration-panorama-note">上排 West、下排 East，每个半区均实例化 native SXM，接收 R6 的 CTRL/EXEC Program 事件并执行 ROW CAP/P/RUN。旧 batch WriteTap 是独立路径；SXM QCTL 未接入。SXM Stream Boundary 的未消费直通数据新增一拍寄存延迟。</p>
  </section>
}

function ProgramLoadRelayOverview({ model }: { model: ConfigurationOverviewModel }) {
  const relay = model.programLoad.relay
  const chain = (prefix: 'W' | 'E') => <div className="program-relay-chain-row" data-hemisphere={prefix === 'W' ? 'west' : 'east'}>
    <strong>{prefix === 'W' ? 'WEST' : 'EAST'}</strong>
    <div>{relay.stages.map((stage, index) => <span key={`${prefix}${stage.index}`}>
      <b>{prefix}{stage.index}</b><small>G{stage.groupStart}{stage.groupEnd === stage.groupStart ? '' : `–G${stage.groupEnd}`}</small><em>{stage.bankCount} BANK</em>{index < relay.stages.length - 1 && <i>→</i>}
    </span>)}</div>
  </div>
  return <section className="program-relay-overview" aria-label="Program Load Relay target topology">
    <header><div><span>PROGRAM LOAD RELAY · INTEGRATED RTL TOPOLOGY</span><strong>2 Hemispheres · {relay.relayCountPerHemisphere} Relays and Local Program Ports each · {relay.totalRelayStages} total</strong></div><div><b>{relay.implementationStatus}</b><b>{relay.integrationStatus}</b></div></header>
    <p>{relay.groupsPerHemisphere} Group / Hemisphere · {relay.groupsPerRelay} Group / Relay · {relay.slicesPerGroup} Slice / Group · {relay.banksPerSlice} Bank / Slice。Relay 0–5 each cover 16 Banks; Relay 6 covers the final 8 Banks.</p>
    <div className="program-relay-chains">{chain('W')}{chain('E')}</div>
    <div className="program-relay-adapter"><strong>14 INDEPENDENT MEM LOCAL PROGRAM PORTS</strong><span>{relay.clusterAdapter}</span></div>
    <div className="program-relay-bypass"><strong>CENTER VXM · DIRECT BOUNDARY</strong><span>{relay.vxmBypass}</span><strong>R6 OUTER LOCAL · SXM BOUNDARY</strong><span>{relay.peripheralForward}</span></div>
    <div className="program-endpoint-lifecycle" aria-label="SXM and VXM Program Load boundary lifecycle">
      {model.programLoad.endpointBoundaries.map((boundary) => <article key={boundary.id} data-status={boundary.status}>
        <header><strong>{boundary.name}</strong><b>{boundary.boundaryStatus}</b></header>
        <p>{boundary.route}</p>
        <div><span>{boundary.boundary}</span><em>{boundary.ready}</em><em>{boundary.commit}</em></div>
        {boundary.status !== 'rtl-confirmed' && <i>MISSING · {boundary.missingAdapter}</i>}
        <footer>{boundary.frontendStatus}</footer>
      </article>)}
    </div>
    <div className="program-reset-lifecycle" data-status={model.programLoad.resetLifecycle.status}>
      <strong>PROGRAM RESET</strong><code>{model.programLoad.resetLifecycle.transportReset}</code><span>→</span>{model.programLoad.resetLifecycle.effects.map((effect) => <b key={effect}>{effect}</b>)}
    </div>
    <div className="program-relay-timing"><article><span>REGISTER BOUNDARY</span><strong>{relay.bufferDepth}-entry capacity</strong><p>{relay.timing.storageMeaning}</p></article><article><span>READY PATH</span><strong>No combinational downstream Ready chain</strong><p>{relay.timing.readyBoundary}</p></article><article><span>THROUGHPUT</span><strong>Target II=1</strong><p>{relay.timing.throughput}</p></article></div>
    <footer><strong>RTL-INTEGRATED RELAY FABRIC</strong><span>{relay.verification.fixedDefect}</span><b>14-PORT DISTRIBUTION HANDSHAKE VERIFIED · 7-WAY PHYSICAL iMEM WRITE VERIFIED / HEMISPHERE</b></footer>
  </section>
}

function ProgramLoadContract({ model }: { model: ConfigurationOverviewModel }) {
  const contract = model.programLoad
  return <section className="configuration-section program-load-contract">
    <div className="configuration-section-heading"><div><span>PROGRAM LOAD INTERFACE CONTRACT</span><h2>Control, Scope, 13-bit Destination and ordered commit</h2></div><div className="contract-status">RTL CONFIRMED · WIP CLOSURE</div></div>
    <p className="configuration-callout">Program Load Control、Scope 和 Destination 都不是 FU 指令编码。Scope 决定单端点或 BOTH 扇出；13-bit Destination 始终只命名一个具体物理目标。当前主路径不存在 Host → MEM SRAM 直连旁路。</p>
    <div className="program-routing-contract">
      <article className="program-scope-card"><span>PROGRAM SCOPE</span><strong>{contract.routing.scope.widthBits}-bit</strong><div>{contract.routing.scope.values.map((value) => <b key={value.name}>{value.encoding}<small>{value.name}</small></b>)}</div><p>{contract.routing.scope.relationship}</p></article>
      <article className="program-destination-card"><span>PROGRAM DESTINATION</span><strong>{contract.routing.destination.widthBits}-bit</strong><div>{contract.routing.destination.fields.map((field) => <b key={field.name} style={{ flexGrow: field.widthBits }}><small>[{field.bits}]</small>{field.name}<em>{field.widthBits}b</em></b>)}</div><p>{contract.routing.destination.relationship}</p></article>
      <article className="program-kind-card"><span>DESTINATION FU KIND [11:8]</span><div>{contract.routing.kinds.map((kind) => <b key={kind.name} data-status={kind.status}><small>{kind.encoding}</small>{kind.name}</b>)}</div></article>
    </div>
    <div className="program-routing-mappings">{contract.routing.mappings.map((mapping) => <article key={mapping.name} data-status={mapping.status}><strong>{mapping.name}</strong><b>{mapping.localIndex}</b><span>{mapping.statement}</span></article>)}</div>
    <p className="configuration-callout program-scope-review"><strong>BOUNDARY NEEDS REVIEW：</strong>{contract.routing.controlSystemBoundary.statement}</p>
    <ProgramLoadRelayOverview model={model} />
    <section className="program-interface-validation" aria-label="Program Load validation evidence"><header><div><span>VALIDATION EVIDENCE</span><strong>1-bit Control · 165-bit Record · complete 13-bit Destination</strong></div><b>RTL VALIDATED</b></header><p>{contract.validation.scope}</p><div>{contract.validation.results.map((result) => <span key={result}>{result}</span>)}</div><footer>{contract.validation.limitation}</footer></section>
    <div className="program-contract-flow" aria-label="Program Load contract flow"><article className="contract-card control-domain"><span>CONTROL DOMAIN</span><strong>{contract.controlDomain.widthBits}-bit</strong><div>{contract.controlDomain.values.map((value) => <b key={value}>{value}</b>)}</div><small>{contract.controlDomain.relationship}</small></article><i className="contract-arrow" aria-hidden="true">→</i><article className="contract-card word-transport"><span>PROGRAM WORD</span><strong>{contract.wordTransport.dataBits}-bit</strong><div className="strobe-segments">{Array.from({ length: contract.wordTransport.strobeBits }, (_, index) => <b key={index}>STRB[{index}]<small>{contract.wordTransport.bitsPerStrobe}b</small></b>)}</div><small>{contract.wordTransport.addressBits}-bit iMEM address · {contract.wordTransport.scopeBits}-bit Scope · {contract.wordTransport.destinationBits}-bit Destination · no Sequence ID</small></article><i className="contract-arrow" aria-hidden="true">→</i><div className="contract-destinations">{contract.destinations.map((destination) => <article className={`contract-card destination-${destination.id}`} key={destination.id}><span>{destination.name}</span><strong>{destination.acceptedStrobe}</strong><small>{destination.validPayloadBits} valid payload bits</small><p>{destination.behavior}</p></article>)}</div><i className="contract-return-arrow" aria-hidden="true">←</i><article className="contract-card ordered-commit"><span>ORDERED COMMIT</span><strong>{contract.commit.signals.join(' / ')}</strong><small>{contract.commit.ordering}</small><b>NO SEQUENCE ID</b></article></div>
    <div className="program-contract-reviews">{contract.reviewItems.map((item) => <div key={item.name}><b>VERIFY_REQUIRED</b><strong>{item.name}</strong><span>{item.statement}</span></div>)}</div>
  </section>
}

function MemIsaAndQctl({ model }: { model: ConfigurationOverviewModel }) {
  if (!model.memIsa || !model.qctl) return <section className="configuration-section configuration-control-contracts">
    <div className="configuration-section-heading"><div><span>MEM ISA &amp; QCTL MAP</span><h2>Configuration snapshot refresh required</h2></div><b className="configuration-status status-needs-review">STALE SNAPSHOT</b></div>
    <p className="configuration-callout">The running service loaded an older Configuration model. Restart the local server or rescan RTL to load MEM64 / Native32 and QCTL lane data. Other Configuration sections remain available.</p>
  </section>
  return <section className="configuration-section configuration-control-contracts">
    <div className="configuration-section-heading"><div><span>MEM ISA &amp; QCTL DISTRIBUTED STORE</span><h2>Load Manager → East / West 2×7 Relay Stores → {numberText(model.qctl.laneCount)} FU-local Endpoints</h2></div><b className="configuration-status status-rtl-confirmed">RTL CONFIRMED</b></div>
    <div className="mem-isa-contract">
      <article><span>MEM MACHINE CODE</span><strong>{numberText(model.memIsa.machineCodeBits)}-bit</strong><p>The Macro Scheduler directly presents the complete MEM64 instruction and its 32-bit issue cycle to the matching MEM64 / Native32 adapter lane. There is no independent MEM Instruction Queue.</p></article>
      <i>→</i>
      <article><span>MEM64 → NATIVE32 ADAPTER</span><strong>{numberText(model.memIsa.nativeCommandBits)}-bit</strong><p>Native32 is a private execution-control word produced only after legality and implementation checks. It is not a second public ISA.</p></article>
    </div>
    <div className="mem-isa-notes">{model.memIsa.notes.map((item) => <article key={item.name} data-status={item.status}><strong>{item.name}</strong><span>{item.statement}</span></article>)}</div>
    <div className="qctl-scale-overview" aria-label="QCTL distributed store scale">
      <article><span>RELAY CHAINS</span><strong>2 × 7</strong><p>East and West each traverse R0–R6.</p></article>
      <article><span>REGIONAL STORES</span><strong>14</strong><p>{numberText(model.qctl.relayTopology.regionDepth)} Records per Relay by default.</p></article>
      <article><span>GLOBAL LOGICAL CAPACITY</span><strong>{numberText(model.qctl.relayTopology.globalCapacity)}</strong><p>External Partition/Base/Count/Generation contract is preserved.</p></article>
      <article><span>FORMAL ENDPOINTS</span><strong>{numberText(model.qctl.laneCount)}</strong><p>208 MEM + 20 MXM; five MXM streams per unit, while VXM/SXM remain outside this map.</p></article>
    </div>
    <section className="qctl-relay-topology" aria-label="QCTL East and West relay topology">
      <header><div><span>LOAD-TIME DISTRIBUTION / RUN-TIME LOCAL READ</span><strong>Central Pool and per-Queue Record Cache are removed</strong></div><b>14 STORES</b></header>
      <div className="qctl-phase-split">{model.qctl.relayTopology.phases.map((phase) => <article key={phase.id} data-phase={phase.id}><span>{phase.name}</span><strong>{phase.path}</strong><p>{phase.statement}</p></article>)}</div>
      <div className="qctl-relay-chains">{model.qctl.relayTopology.chains.map((chain) => <section key={chain.id} data-chain={chain.id}>
        <header><strong>{chain.name}</strong><span>{chain.scope}</span></header>
        <div>{chain.stages.map((stage, index) => <article key={stage.id} data-relay={stage.id}>
          {index > 0 && <i aria-hidden="true">→</i>}
          <b>{stage.name}</b><strong>{stage.queues}</strong><span>{stage.locals}</span>
        </article>)}</div>
      </section>)}</div>
      <div className="qctl-store-contract">{model.qctl.relayTopology.storeContract.map((item) => <article key={item.id} data-store-part={item.id}><strong>{item.name}</strong><p>{item.statement}</p></article>)}</div>
      <footer>Each regional Store uses a {numberText(model.qctl.relayTopology.transitDepth)}-entry Transit FIFO and limits one Queue to {numberText(model.qctl.relayTopology.queueEntryLimit)} QCTL Records by default.</footer>
    </section>
    <div className="qctl-system-pipeline" aria-label="QCTL architecture pipeline">{model.qctl.pipeline.map((stage, index) => <div className="qctl-pipeline-stage" key={stage.id} data-stage={stage.id}>
      {index > 0 && <i aria-hidden="true">→</i>}
      <article><span>{stage.name}</span><strong>{numberText(stage.count)}</strong><p>{stage.statement}</p></article>
    </div>)}</div>
    <section className="qctl-controller-fsm"><header><span>PER-QUEUE CONTROLLER</span><strong>Five-state blocking semantics</strong></header><div>{model.qctl.states.map((state) => <article key={state.id} data-state={state.id}><b>{state.name}</b><p>{state.statement}</p></article>)}</div></section>
    <div className="qctl-runtime-semantics">
      <article className="qctl-barrier-card"><span>ARRIVAL / RELEASE BARRIER</span><strong>Participant Mask · no historical token</strong><p>{model.qctl.barrier.participantMask}</p><p>{model.qctl.barrier.arrival}</p><p>{model.qctl.barrier.notify}</p><p>{model.qctl.barrier.release}</p><p>{model.qctl.barrier.roundIsolation}</p></article>
      <article><span>32-BIT TAG EVENT BUFFER</span><strong>{numberText(model.qctl.eventBuffer.depth)} buffered TAG slots</strong><p>{model.qctl.eventBuffer.statement}</p></article>
      <article><span>MEM_PACKET RETIREMENT</span><strong>{model.qctl.memPacket.ordinalBits}-bit stable ordinal</strong><p>{model.qctl.memPacket.retirement}</p><p>{model.qctl.memPacket.sramCommitRelationship}</p></article>
    </div>
    <div className="qctl-lane-map" data-qctl-lanes={model.qctl.laneCount ?? 'review'}>{model.qctl.groups.map((group) => <article key={group.id} className={`qctl-group-${group.id}`} style={{ flexGrow: group.count }}><span>{group.first}..{group.last}</span><strong>{group.name}</strong><small>{group.count} lanes</small></article>)}</div>
    <div className="qctl-endpoint-boundary"><article><span>FORMAL QCTL ENDPOINTS</span>{model.qctl.endpointBoundary.connected.map((item) => <strong key={item}>{item}</strong>)}</article><i>≠</i><article data-boundary="not-connected"><span>NOT CONNECTED</span>{model.qctl.endpointBoundary.notConnected.map((item) => <strong key={item}>{item}</strong>)}</article></div>
    <p className="configuration-callout"><strong>{numberText(model.qctl.laneCount)} FORMAL ENDPOINTS：</strong>{model.qctl.endpointBoundary.statement}</p>
    <section className="qctl-validation"><header><span>VALIDATION</span><strong>{model.qctl.validation.status}</strong></header><p>{model.qctl.validation.scope}</p><div>{model.qctl.validation.results.map((result) => <b key={result}>{result}</b>)}</div><footer>{model.qctl.validation.limitation}</footer></section>
  </section>
}

function MemArray({ model }: { model: ConfigurationOverviewModel }) {
  const detail = model.memArray
  const groups = Array.from({ length: detail.groupsPerMem ?? 0 }, (_, group) => group)
  const slices = Array.from({ length: detail.columnsPerGroup ?? 0 }, (_, slice) => slice)
  const banks = Array.from({ length: detail.banksPerColumn ?? 0 }, (_, bank) => bank)
  const leaves = Array.from({ length: detail.leafSramsPerBank ?? 0 }, (_, leaf) => leaf)
  return <section className="mem-array-detail configuration-section">
    <div className="configuration-section-heading"><div><span>MEM NATIVE ARRAY DETAIL</span><h2>Group → Slice → Bank → Superlane SRAM Leaf</h2></div><div className="availability-badge enabled">NATIVE DEFAULT</div></div>
    <p className="configuration-callout">黄色小格表示当前 Native 默认分支中的一个 <strong>8192 × 64 behavioral SRAM leaf</strong>。它是 bank/superlane 叶子数组，不等同于已经选型的物理 SRAM macro。</p>
    <div className="mem-array-metrics"><div><span>Group / MEM</span><strong>{numberText(detail.groupsPerMem)}</strong></div><div><span>Slice / MEM</span><strong>{numberText(detail.columnsPerMem)}</strong></div><div><span>Bank / Slice</span><strong>{numberText(detail.banksPerColumn)}</strong></div><div><span>Bank / MEM</span><strong>{numberText(detail.banksPerMem)}</strong></div><div><span>Leaf / Bank</span><strong>{numberText(detail.leafSramsPerBank)}</strong></div><div><span>Leaf / MEM</span><strong>{numberText(detail.leafSramsPerMem)}</strong></div><div><span>Leaf / System</span><strong>{numberText(detail.leafSramsSystem)}</strong></div><div><span>MEM ISA / Native</span><strong>{numberText(detail.machineCodeBits)} / {numberText(detail.nativeCommandBits)}</strong></div></div>
    <div className="mem-topology-axis" aria-label="MEM functional north south orientation"><span>NORTH · SRAM / BANK / SLICE</span><b>↑ SOUTH → NORTH BANK COMMAND</b><span>SOUTH · LOCAL INSTRUCTION FRONTEND + TIMED QUEUE</span></div>
    <div className="mem-sram-array" data-mem-group-count={groups.length} data-mem-local-issue-count={(detail.banksPerMem ?? 0)}>
      {groups.map((group) => <div className="mem-sram-group" key={group}>
        <header>GROUP {group}</header>
        <div className="mem-sram-columns">{slices.map((slice) => <div className="mem-sram-column" key={slice} title={`Slice ${group * (detail.columnsPerGroup ?? 0) + slice}`}>{banks.map((bank) => <div className="mem-sram-bank" key={bank}>{leaves.map((leaf) => <i key={leaf} className="mem-sram-slice" title={`G${group} S${slice} B${bank} Superlane${leaf}: ${numberText(detail.leafDepthRows)} × ${numberText(detail.leafWidthBits)} behavioral array`} />)}</div>)}</div>)}</div>
        <div className="mem-bank-flow"><span>↑</span><small>MEM64</small></div>
        <div className="mem-bank-issue-pairs">{slices.flatMap((slice) => banks.map((bank) => <div className="mem-bank-issue-pair" key={`${slice}-${bank}`} title={`Group ${group}, Slice ${slice}, Bank ${bank}: local frontend with direct Scheduler issue`} data-local-issue-pair="true"><b>F</b><i>→</i><b>D</b></div>))}</div>
      </div>)}
    </div>
    <div className="mem-slice-proof"><div><span>Native leaf implementation</span><strong>{numberText(detail.leafWidthBits)}-bit × {numberText(detail.leafDepthRows)} rows</strong><p>{detail.leafImplementation}</p></div><code>52 slices × 2 banks × 4 superlanes = {numberText(detail.leafSramsPerMem)} leaves / MEM</code></div>
    <details className="configuration-evidence mem-evidence"><summary>查看 Native 数量与参数证据</summary><ul>{detail.evidence.map((item, index) => <EvidenceLine key={`${item.file}-${item.line}-${index}`} item={item} />)}</ul></details>
  </section>
}

export default function ConfigurationOverview({ model }: { model: ConfigurationOverviewModel }) {
  return <div className="configuration-overview" data-view="configuration">
    <section className="configuration-hero"><div><span>CONFIGURATION &amp; FU COMPOSITION</span><h1>LPU Hardware Scale Overview</h1><p>{model.policy.statement}</p></div><div className="configuration-warning">WIP RTL SNAPSHOT<br /><small>{model.policy.warning}</small><small>Configuration scan: {new Date(model.source.snapshotGeneratedAt).toLocaleString('zh-CN', { hour12: false })}</small></div></section>
    <section className="configuration-section system-configuration"><div className="configuration-section-heading"><div><span>SYSTEM CONFIGURATION SUMMARY</span><h2>Current default RTL configuration</h2></div><small>Total / per Hemisphere</small></div><div className="configuration-summary-grid">{model.summary.map((item) => <article key={item.id} title={item.evidence.map((evidence) => `${evidence.symbol}: ${evidence.expression}\n${evidence.file}:${evidence.line}`).join('\n')}><span>{item.label}</span><strong>{numberText(item.total)}</strong><small>{item.perHemisphere === null ? (item.id === 'program-load-relay' ? 'Integrated' : item.availability) : `${numberText(item.perHemisphere)} / Hemisphere · ${item.id === 'program-load-relay' ? 'Integrated' : item.availability}`}</small></article>)}</div></section>
    <ConfigurationCanvas model={model} />
    <FuCompositionExplorer model={model} />
    <ProgramLoadContract model={model} />
    <MemIsaAndQctl model={model} />
    <MemArray model={model} />
  </div>
}
