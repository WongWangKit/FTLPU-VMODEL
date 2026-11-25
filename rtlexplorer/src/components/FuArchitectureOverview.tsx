import { useMemo, useState } from 'react'
import { ReactFlow, Background, MarkerType, Position, type Edge, type Node, type ReactFlowInstance, type Viewport } from '@xyflow/react'
import type { ArchitectureDrillNode, PhysicalFunctionalBlock } from '../types'

type FuKind = 'mem' | 'sxm' | 'vxm'
type Tone = 'control' | 'data' | 'storage' | 'compute' | 'boundary' | 'caution'

interface Card {
  id: string
  title: string
  subtitle: string
  detail: string
  source: string
  tone: Tone
  x: number
  y: number
  width?: number
  height?: number
  drillId?: string
  chips?: string[]
}
interface Link {
  from: string
  to: string
  label: string
  detail: string
  source: string
  tone: Tone
  dashed?: boolean
}
interface Props {
  kind: FuKind
  block: PhysicalFunctionalBlock
  nodes: Map<string, ArchitectureDrillNode>
  onNavigate: (id: string) => void
  onSelectNode: (id: string) => void
  onReady: (instance: ReactFlowInstance) => void
  onViewportChange: (viewport: Viewport) => void
}

function numberOf(node: ArchitectureDrillNode | undefined, name: string, fallback: number) {
  const value = node?.parameterRefs.find((item) => item.name === name)?.value
  return typeof value === 'number' ? value : fallback
}

function diagram(kind: FuKind, block: PhysicalFunctionalBlock, nodes: Map<string, ArchitectureDrillNode>): { cards: Card[]; links: Link[]; title: string; metrics: string[]; note: string } {
  if (kind === 'mem') {
    const base = `arch:${block.regionId}:mem`
    const execution = nodes.get(`${base}:execution`)
    const streams = nodes.get(`${base}:streams`)
    const groups = numberOf(execution, 'GROUPS', 13)
    const slices = numberOf(execution, 'SLICES', 52)
    const banks = numberOf(execution, 'BANKS', 104)
    const leaves = numberOf(execution, 'LEAVES', 416)
    const boundaries = numberOf(streams, 'MEM_BOUNDARIES', groups + 1)
    const groupChips = Array.from({ length: groups }, (_, index) => `G${index}`)
    const cards: Card[] = [
      { id: 'issue', title: 'Bank-local iMEM + Macro Scheduler', subtitle: `${banks} independent issue paths / hemisphere`, detail: 'Local iMEM → Fetch → Word FIFO → Decode → Context FIFO → Scheduler. Each scheduler issues a 64-bit MEM word directly.', source: 'rtl/mem/lpu_mem_subsystem.sv · gen_bank_frontend; rtl/mem/lpu_mem_macro_frontend.sv', tone: 'control', x: 40, y: 50, width: 430, drillId: `${base}:local-issue-path` },
      { id: 'adapter', title: 'MEM64 → Native32', subtitle: `${banks} command adapters / hemisphere`, detail: 'Only legal implemented MEM commands enter Native execution. The normal adapted command uses the short one-cycle control hop.', source: 'rtl/integration/lpu_mem_srf_command_integration.sv · gen_adapter', tone: 'control', x: 570, y: 50, width: 360, drillId: `${base}:native-adapter` },
      { id: 'east', title: 'EAST · Native MEM', subtitle: `${groups} Groups × ${Math.floor(slices / groups)} Slices × 2 Banks × 4 Leaves`, detail: `One hemisphere: ${slices} Slices, ${banks} Banks and ${leaves} independent 64-bit behavioral leaves. Each group contains four Slices; each Slice has two Bank control columns; each Bank has four leaves.`, source: 'rtl/mem_native/mem_hemisphere.sv · gen_group; rtl/mem_native/mem_slice.sv', tone: 'storage', x: 40, y: 300, width: 690, height: 290, drillId: block.regionId === 'east' ? `${base}:execution` : undefined, chips: groupChips },
      { id: 'west', title: 'WEST · Native MEM', subtitle: `${groups} Groups × ${Math.floor(slices / groups)} Slices × 2 Banks × 4 Leaves`, detail: `One hemisphere: ${slices} Slices, ${banks} Banks and ${leaves} independent 64-bit behavioral leaves. Group is a generated organization, not an independent relay module.`, source: 'rtl/mem_native/mem_hemisphere.sv · gen_group; rtl/mem_native/mem_group.sv', tone: 'storage', x: 770, y: 300, width: 690, height: 290, drillId: block.regionId === 'west' ? `${base}:execution` : undefined, chips: groupChips },
      { id: 'boundary', title: `MEM Boundary 0…${boundaries - 1}`, subtitle: 'East / West data directions · registered progression', detail: 'Boundary positions are internal state and routing, not separate Relay module instances. A Group consumes selected input; unconsumed Stream data advances; multiple producers targeting one cell raise conflict.', source: 'rtl/mem_native/mem_hemisphere.sv · boundary state and producer collision; rtl/integration/lpu_mem_srf_integration.sv', tone: 'data', x: 420, y: 670, width: 660, drillId: `${base}:streams`, chips: Array.from({ length: boundaries }, (_, index) => `B${index}`) },
      { id: 'legacy', title: 'Optional legacy Slice path', subtitle: 'USE_NATIVE_MEM=0 only', detail: 'The older lpu_mem_hemisphere/lpu_mem_column four Tile Slice organization is conditional. It is not the default top path. USE_SRAM_MACRO and FTLPU_USE_SRAM64X2048_MACRO further select optional storage implementation.', source: 'rtl/mem/lpu_mem_subsystem.sv · gen_legacy_execution; rtl/mem/lpu_mem_tile_slice.sv', tone: 'caution', x: 1110, y: 670, width: 350 },
    ]
    const links: Link[] = [
      { from: 'issue', to: 'adapter', label: 'MEM64', detail: 'Bank-local Scheduler drives the corresponding MEM64/Native32 command adapter.', source: 'rtl/mem/lpu_mem_subsystem.sv; rtl/integration/lpu_mem_srf_command_integration.sv', tone: 'control' },
      { from: 'adapter', to: 'east', label: 'Native32 issue', detail: 'The East hemisphere receives one private 32-bit Native command per Bank.', source: 'rtl/mem/lpu_mem_subsystem.sv · gen_native_execution', tone: 'control' },
      { from: 'adapter', to: 'west', label: 'Native32 issue', detail: 'The West hemisphere receives one private 32-bit Native command per Bank.', source: 'rtl/mem/lpu_mem_subsystem.sv · gen_native_execution', tone: 'control' },
      { from: 'east', to: 'boundary', label: 'Read / Write', detail: 'East Read produces to the right boundary; East Write observes the left boundary.', source: 'rtl/mem_native/mem_group.sv', tone: 'data' },
      { from: 'west', to: 'boundary', label: 'Read / Write', detail: 'West Read produces to the left boundary; West Write observes the right boundary.', source: 'rtl/mem_native/mem_group.sv', tone: 'data' },
    ]
    return { cards, links, title: 'MEM · Architecture Overview', metrics: [`2 hemispheres`, `${groups} groups / hemisphere`, `${banks} banks / hemisphere`, `${leaves} leaves / hemisphere`, `${boundaries} boundaries`], note: '当前默认 USE_NATIVE_MEM=1；旧的 47-bit Column / Tile Slice 与物理 SRAM Macro 路径均为可选分支。当前顶层没有独立 Host SRAM 直通接口。' }
  }
  if (kind === 'sxm') {
    const base = `arch:${block.regionId}:sxm`
    const cards: Card[] = [
      { id: 'program', title: 'R6 Outer Local Program', subtitle: 'Target 5 CTRL · Target 6 EXEC', detail: 'One native Program endpoint per Hemisphere accepts target 5/6 at local index zero and returns Ready/Error.', source: 'rtl/core/lpu_fu_subsystem_cluster.sv · u_sxm_subsystem', tone: 'control', x: 70, y: 50, width: 350, drillId: `${base}:program-ingress` },
      { id: 'ctrl', title: 'CTRL Calendar', subtitle: '64 events · payload + timing word', detail: 'Absolute-cycle CTRL events configure the native ROW core.', source: 'rtl/sxm/lpu_sxm_native_subsystem.sv · u_ctrl_calendar', tone: 'storage', x: 510, y: 50, width: 330, drillId: `${base}:ctrl-calendar` },
      { id: 'exec', title: 'EXEC Calendar', subtitle: '64 events · CAP / P / RUN', detail: 'Independent EXEC events may coincide with CTRL events.', source: 'rtl/sxm/lpu_sxm_native_subsystem.sv · u_exec_calendar', tone: 'storage', x: 510, y: 290, width: 330, drillId: `${base}:exec-calendar` },
      { id: 'row', title: 'Native ROW Core', subtitle: 'T=4 · 1+2+3+4 slots', detail: 'Each Hemisphere has ten left-aligned 8×8×32-bit slots. CAP reads SRF, P passes one pipeline stage and RUN produces output.', source: 'rtl/sxm/lpu_sxm_native_subsystem.sv · u_execution', tone: 'compute', x: 930, y: 160, width: 400, drillId: `${base}:triangle-core`, chips: ['CAP', 'P', 'RUN'] },
      { id: 'stream', title: 'Stream Boundary', subtitle: 'MEM ↔ SXM ↔ MXM', detail: 'Native ROW output injects at the registered stream boundary. Unconsumed pass-through streams gain one registered cycle.', source: 'rtl/sxm/lpu_sxm_native_subsystem.sv · u_stream_boundary', tone: 'data', x: 930, y: 470, width: 400, drillId: `${base}:stream-boundary` },
      { id: 'batch', title: 'Separate batch WriteTap', subtitle: 'Not the formal Program endpoint', detail: 'The older typed batch lpu_sxm_subsystem and its MEM Adapter/WriteTap completion remain a separate path. Raw416 is independent core compatibility.', source: 'rtl/sxm/lpu_sxm_subsystem.sv; rtl/sxm/sxm_triangle_full_core.sv', tone: 'boundary', x: 70, y: 560, width: 770, drillId: `${base}:batch-writetap` },
    ]
    const links: Link[] = [
      { from: 'program', to: 'ctrl', label: 'target 5', detail: 'R6 forwards CTRL words into the first native calendar.', source: 'rtl/sxm/lpu_sxm_native_subsystem.sv', tone: 'control' },
      { from: 'program', to: 'exec', label: 'target 6', detail: 'R6 forwards EXEC words into the independent second calendar.', source: 'rtl/sxm/lpu_sxm_native_subsystem.sv', tone: 'control' },
      { from: 'ctrl', to: 'row', label: 'CTRL issue', detail: 'Calendar issues on the programmed absolute cycle.', source: 'rtl/sxm/lpu_sxm_native_subsystem.sv', tone: 'control' },
      { from: 'exec', to: 'row', label: 'CAP / P / RUN', detail: 'Native ROW operations issue on programmed absolute cycles.', source: 'rtl/sxm/lpu_sxm_native_subsystem.sv', tone: 'control' },
      { from: 'row', to: 'stream', label: 'ROW output', detail: 'RUN output is injected into the stream boundary.', source: 'rtl/sxm/lpu_sxm_native_subsystem.sv', tone: 'data' },
    ]
    return { cards, links, title: 'SXM · Native Program / ROW Architecture', metrics: ['2 formal subsystems', '4 × 64-event calendars', '10 slots / Hemisphere', 'VCS: 5 scenarios · 2787 checks'], note: 'SXM QCTL endpoint is not integrated. CMODEL main still lacks native ROW Program. The registered SXM pass-through adds one cycle; older cross-FU static schedules need separate regression.' }
  }
  const base = 'arch:central:vxm'
  const tileNode = nodes.get(`${base}:tiles`)
  const tileCount = numberOf(tileNode, 'TILES', 4)
  const stages = numberOf(tileNode, 'STAGES', 16)
  const lanes = numberOf(tileNode, 'LANES', 8)
  const cards: Card[] = [
    { id: 'issue', title: 'ICU / resident issue', subtitle: '8 local widths 6/5/7/6/7/5/7/6 + 15-bit global', detail: 'Eight heterogeneous local words and one global config word feed VXM Control. In the formal FU cluster, issue valid is currently tied low; this diagram shows the internal slice contract.', source: 'rtl/core/lpu_pkg.sv · vxm_local_instruction_width; rtl/core/lpu_fu_subsystem_cluster.sv · u_vxm_subsystem', tone: 'control', x: 40, y: 30, width: 380, drillId: `${base}:issue`, chips: Array.from({ length: 8 }, (_, i) => `Q${i}`) },
    { id: 'control', title: 'VXM Control', subtitle: '8 local waves + 1 global wave · 4 rows', detail: 'Each issue wave uses a four-row control pipeline. Global config is retained per Tile; a fixed execute wave follows. A Tile that misses the required cycle faults.', source: 'rtl/vxm/lpu_vxm_control.sv · gen_local_wave / u_global_wave; rtl/vxm/lpu_vxm_slice.sv', tone: 'control', x: 500, y: 30, width: 420, drillId: `${base}:control` },
    { id: 'west', title: 'MEM West boundary', subtitle: '2 hemispheres × 4 Tiles × 32 Streams', detail: 'west_from_mem drives Tile input selection and the Stream Bridge bypass path.', source: 'rtl/vxm/lpu_vxm_slice.sv · west_from_mem_*', tone: 'boundary', x: 40, y: 280, width: 220, drillId: `${base}:ingress` },
    { id: 'external', title: 'External East input', subtitle: 'Independent bridge input', detail: 'External East words enter their local hemisphere bridge output cells unchanged. They are not the Tile ALU operand input.', source: 'rtl/vxm/lpu_vxm_stream_bridge.sv · external_east_*', tone: 'boundary', x: 40, y: 510, width: 220, drillId: `${base}:stream-bridge` },
    { id: 'bridge', title: 'Stream Bridge', subtitle: 'Pass-through + produced result + conflict', detail: 'Unconsumed West words cross to the opposite hemisphere East edge. Produced VXM words target output cells; duplicate producers set conflict_o. No FIFO or arbitration is instantiated.', source: 'rtl/vxm/lpu_vxm_stream_bridge.sv · u_stream_bridge', tone: 'data', x: 1300, y: 385, width: 200, drillId: `${base}:stream-bridge` },
    { id: 'east', title: 'MEM East boundary', subtitle: 'east_to_mem_*', detail: 'Bridge output returns to MEM East edge by hemisphere/tile/stream cell.', source: 'rtl/vxm/lpu_vxm_slice.sv · east_to_mem_*', tone: 'boundary', x: 1540, y: 385, width: 180, drillId: `${base}:egress` },
  ]
  const links: Link[] = [
    { from: 'issue', to: 'control', label: '9 issue channels', detail: 'Eight local and one global config channel enter the control instance; formal cluster valid signals are presently tied off.', source: 'rtl/vxm/lpu_vxm_slice.sv · u_control; rtl/core/lpu_fu_subsystem_cluster.sv', tone: 'control' },
    { from: 'external', to: 'bridge', label: 'external East', detail: 'Separate bridge input, not a Tile operand path.', source: 'rtl/vxm/lpu_vxm_stream_bridge.sv', tone: 'boundary' },
    { from: 'west', to: 'bridge', label: 'unconsumed pass', detail: 'West data that is not consumed crosses to the opposite hemisphere output cell.', source: 'rtl/vxm/lpu_vxm_stream_bridge.sv', tone: 'data' },
    { from: 'bridge', to: 'east', label: 'routed output', detail: 'External, pass-through and produced words share output cells with conflict detection.', source: 'rtl/vxm/lpu_vxm_stream_bridge.sv', tone: 'data' },
  ]
  for (let tile = 0; tile < tileCount; tile += 1) {
    const x = 300 + tile * 245
    cards.push({ id: `tile-${tile}`, title: `Tile ${tile} · Superlane`, subtitle: `${stages} stages × ${lanes} lanes`, detail: `One generated lpu_vxm_tile_execution instance with ${stages * lanes} physical ALU positions. The eight lanes are parallel; each lane traverses stage 0→${stages - 1}.`, source: `rtl/vxm/lpu_vxm_slice.sv · gen_tile[${tile}].u_tile`, tone: 'compute', x, y: 320, width: 220, height: 185, drillId: `${base}:tiles:tile:${tile}`, chips: Array.from({ length: lanes }, (_, lane) => `L${lane}`) })
    cards.push({ id: `lut-${tile}`, title: `Tile ${tile} · private LUT`, subtitle: '4 functions × 8 lanes × 64 entries', detail: 'Each Tile owns 32 independent logical LUT SRAMs. Reads are synchronous with Stage tags. Slice config/write ports exist, while the formal subsystem ties valid low.', source: `rtl/vxm/lpu_vxm_slice.sv · gen_lut_tile[${tile}].u_tile_lut; rtl/vxm/lpu_vxm_tile_lut.sv`, tone: 'storage', x, y: 650, width: 220, height: 165, drillId: `${base}:lut` })
    links.push({ from: 'control', to: `tile-${tile}`, label: `row ${tile}`, detail: `Local/global wave reaches Tile ${tile}; the Tile retains config and follows the fixed execute timing.`, source: 'rtl/vxm/lpu_vxm_control.sv; rtl/vxm/lpu_vxm_slice.sv', tone: 'control' })
    links.push({ from: 'west', to: `tile-${tile}`, label: 'selected stream', detail: `Tile ${tile} selects its input hemisphere from west_from_mem using global flow direction.`, source: 'rtl/vxm/lpu_vxm_slice.sv · stream_valid_i / stream_data_i', tone: 'data' })
    links.push({ from: `tile-${tile}`, to: `lut-${tile}`, label: 'address + stage', detail: 'Special ALU requests its private Function/Lane table with a physical Stage tag.', source: 'rtl/vxm/lpu_vxm_slice.sv · tile_lut_request_*', tone: 'storage' })
    links.push({ from: `lut-${tile}`, to: `tile-${tile}`, label: 'tagged response', detail: 'Synchronous LUT response returns to the requesting Tile and physical Stage.', source: 'rtl/vxm/lpu_vxm_slice.sv · tile_lut_response_*', tone: 'storage' })
    links.push({ from: `tile-${tile}`, to: 'bridge', label: 'produced result', detail: `Tile ${tile} output is mapped to bridge produced cells; a contested cell raises conflict.`, source: 'rtl/vxm/lpu_vxm_slice.sv · produced_valid / produced_data', tone: 'data' })
  }
  return { cards, links, title: 'VXM · Architecture Overview', metrics: ['1 central Slice', '8 local + 1 global wave', `${tileCount} Tile execution`, `${tileCount * stages * lanes} ALU positions`, `${tileCount * 4 * lanes} logical LUT SRAMs`], note: '正式集群的 Local/Global issue 当前 tied off；Slice 内控制、执行、LUT 与 Stream Bridge 结构均已实例化。' }
}

const colors: Record<Tone, string> = { control: '#8659bf', data: '#3678bf', storage: '#3f9375', compute: '#c48b20', boundary: '#6c88a6', caution: '#be5a56' }

export default function FuArchitectureOverview({ kind, block, nodes, onNavigate, onSelectNode, onReady, onViewportChange }: Props) {
  const content = useMemo(() => diagram(kind, block, nodes), [kind, block, nodes])
  const [selection, setSelection] = useState<{ title: string; detail: string; source: string; drillId?: string; subtitle?: string; from?: string; to?: string } | null>(null)
  const detailNode = selection?.drillId ? nodes.get(selection.drillId) : undefined
  const connected = selection && !selection.from ? content.links.filter((link) => link.from === content.cards.find((card) => card.title === selection.title)?.id || link.to === content.cards.find((card) => card.title === selection.title)?.id) : []
  const cards = useMemo<Node[]>(() => content.cards.map((card) => ({ id: card.id, type: 'default', position: { x: card.x, y: card.y }, sourcePosition: Position.Right, targetPosition: Position.Left, data: { label: <div className={`fu-overview-card tone-${card.tone}`} style={{ width: card.width ?? 300, minHeight: card.height ?? 120 }}><span>{card.subtitle}</span><strong>{card.title}</strong>{card.chips && <div className="fu-overview-chips">{card.chips.map((chip) => kind === 'mem' && card.drillId && /^G\d+$/.test(chip) ? <button type="button" key={chip} title={`进入 ${chip}`} onClick={(event) => { event.stopPropagation(); const groupId = `${card.drillId}:group:${Number(chip.slice(1))}`; if (nodes.has(groupId)) onNavigate(groupId) }}>{chip}</button> : <i key={chip}>{chip}</i>)}</div>}<small>{card.drillId ? '点击查看 · 可下钻' : '点击查看结构'}</small></div> }, style: { border: 'none', padding: 0, background: 'transparent', boxShadow: 'none', width: card.width ?? 300 } })), [content, kind, nodes, onNavigate])
  const edges = useMemo<Edge[]>(() => content.links.map((link, index) => ({ id: `link-${index}`, source: link.from, target: link.to, type: 'smoothstep', label: link.label, markerEnd: { type: MarkerType.ArrowClosed, color: colors[link.tone] }, animated: false, style: { stroke: colors[link.tone], strokeWidth: 3, strokeDasharray: link.dashed ? '8 6' : undefined }, labelStyle: { fill: '#102b59', fontSize: 17, fontWeight: 700 }, labelBgStyle: { fill: '#fff', fillOpacity: .94 }, labelBgPadding: [8, 5] })), [content])
  return <section className={`fu-architecture-overview fu-${kind}`} data-fu-overview={kind}>
    <header className="fu-overview-heading"><div><span>L2 · FUNCTIONAL ARCHITECTURE</span><h2>{content.title}</h2><p>{content.note}</p></div><div className="fu-overview-metrics">{content.metrics.map((metric) => <b key={metric}>{metric}</b>)}</div></header>
    <div className="fu-overview-body">
      <div className="fu-overview-flow" role="application" aria-label={`${kind.toUpperCase()} architecture diagram`}>
        <ReactFlow nodes={cards} edges={edges} fitView fitViewOptions={{ padding: .12, maxZoom: 1 }} minZoom={.3} maxZoom={2} nodesDraggable={false} nodesConnectable={false} elementsSelectable panOnDrag zoomOnScroll onInit={onReady} onMoveEnd={(_, viewport) => onViewportChange(viewport)} onNodeClick={(_, node) => { const item = content.cards.find((card) => card.id === node.id); if (item) setSelection(item) }} onEdgeClick={(_, edge) => { const item = content.links[Number(edge.id.slice(5))]; if (item) setSelection({ title: item.label, detail: item.detail, source: item.source, from: content.cards.find((card) => card.id === item.from)?.title ?? item.from, to: content.cards.find((card) => card.id === item.to)?.title ?? item.to }) }}><Background gap={24} size={1} color="#d6e2ef" /></ReactFlow>
      </div>
      <aside className="fu-overview-inspector"><span>INSPECTOR</span>{selection ? <><h3>{selection.title}</h3><p>{selection.detail}</p>{selection.from && <div><b>连接方向</b><code>{selection.from} → {selection.to}</code></div>}{selection.subtitle && <div><b>参数 / 规模</b><code>{selection.subtitle}</code></div>}{detailNode?.rtlModuleRefs.length ? <div><b>RTL 模块</b><code>{detailNode.rtlModuleRefs.join(' · ')}</code></div> : null}{detailNode?.rtlInstanceRefs.length ? <div><b>实例路径</b><code>{detailNode.rtlInstanceRefs.map((ref) => ref.rtlPath ?? ref.instanceSelector).join(' · ')}</code></div> : null}{detailNode?.parameterRefs.length ? <div><b>当前参数</b><code>{detailNode.parameterRefs.slice(0, 6).map((ref) => `${ref.name}=${ref.value ?? ref.expression}`).join(' · ')}</code></div> : null}{connected.length > 0 && <div><b>输入 / 输出接口</b><code>{connected.map((link) => `${content.cards.find((card) => card.id === link.from)?.title ?? link.from} → ${content.cards.find((card) => card.id === link.to)?.title ?? link.to}: ${link.label}`).join('； ')}</code></div>}<div><b>RTL 来源</b><code>{selection.source}</code></div>{selection.drillId && nodes.has(selection.drillId) && <button onClick={() => { onSelectNode(selection.drillId!); onNavigate(selection.drillId!) }}>进入详细视图 →</button>}</> : <><h3>选择模块或连接</h3><p>点击方框查看职责和 RTL 来源；点击箭头查看接口语义。拖动画布平移，使用顶部按钮缩放。</p></>}</aside>
    </div>
  </section>
}
