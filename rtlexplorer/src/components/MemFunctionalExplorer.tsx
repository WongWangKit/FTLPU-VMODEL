import { useEffect, useMemo, useState } from 'react'
import { buildHardwareQuickSpec } from '../lib/hardware-spec'
import type { ArchitectureDrillNode, PhysicalFunctionalBlock } from '../types'

type Direction = 'east' | 'west'
type Operation = 'read' | 'write'
type HopLatency = 1 | 3

interface Props {
  block: PhysicalFunctionalBlock
  current: ArchitectureDrillNode
  nodes: Map<string, ArchitectureDrillNode>
  onNavigate: (id: string) => void
  onSelectNode: (id: string) => void
}

function nodeBySuffix(nodes: Map<string, ArchitectureDrillNode>, base: string, suffix: string) {
  return nodes.get(`${base}:${suffix}`)
}

function MemNodeButton({ node, onOpen }: { node: ArchitectureDrillNode; onOpen: () => void }) {
  const spec = buildHardwareQuickSpec(node)
  return <button className={`mem-hierarchy-card node-${node.nodeType}`} onClick={onOpen} data-mem-node-id={node.id}>
    <span>{node.nodeType.replaceAll('-', ' ').toUpperCase()}</span>
    <strong>{node.displayName}</strong>
    <small>{node.description}</small>
    <b>{spec.primaryLabel} · {spec.primaryValue}</b>
    <i>{node.childIds.length ? '点击下钻' : '查看 RTL 证据'}</i>
  </button>
}

function PropagationPanel({ region }: { region: string }) {
  const [operation, setOperation] = useState<Operation>('write')
  const [direction, setDirection] = useState<Direction>(region === 'east' ? 'west' : 'east')
  const [hopLatency, setHopLatency] = useState<HopLatency>(1)
  const [preserve, setPreserve] = useState(false)
  const [cycle, setCycle] = useState(0)
  const [playing, setPlaying] = useState(false)

  const boundary = operation === 'write'
    ? (direction === 'east' ? 'Left Boundary g' : 'Right Boundary g+1')
    : (direction === 'east' ? 'Right Boundary g+1' : 'Left Boundary g')
  const stages = useMemo(() => operation === 'write' ? [
    { title: 'Macro Scheduler', note: '64-bit MEM instruction and current schedule cycle; no independent Instruction Queue.' },
    { title: 'MEM64 → Native32', note: 'Legal READ/WRITE only; standard adapter keeps native bit30=0.' },
    { title: `Control Column · ${hopLatency} cycle`, note: hopLatency === 1 ? 'tile0 is combinational; later leaves use the short one-register hop.' : 'bit30=1 selects Delay1 + Delay2 + execution register per hop.' },
    { title: boundary, note: `${direction.toUpperCase()} Write observes the ${direction === 'east' ? 'left' : 'right'} SRF boundary.` },
    { title: '64-bit SRAM Row Write', note: 'One 8-lane × 8-bit row is written in the selected superlane leaf.' },
    { title: preserve ? 'WriteTap / Preserve' : 'SRF Consume', note: preserve ? 'Preserve writes valid data without consuming the SRF segment; missing data is a local no-op.' : 'Normal Write asserts consume only after a valid segment is accepted.' },
  ] : [
    { title: 'Macro Scheduler', note: '64-bit MEM instruction and current schedule cycle; no independent Instruction Queue.' },
    { title: 'MEM64 → Native32', note: 'READ is converted into the private 32-bit Native command.' },
    { title: `Control Column · ${hopLatency} cycle`, note: hopLatency === 1 ? 'Normal adapter output follows the short path (bit30=0).' : 'Interactive long-hop view models native bit30=1.' },
    { title: 'Registered SRAM Read', note: 'The selected 64-bit row produces one registered response pulse after one cycle.' },
    { title: boundary, note: `${direction.toUpperCase()} Read injects at the ${direction === 'east' ? 'right' : 'left'} MEM group boundary.` },
    { title: 'SRF Injection', note: 'Boundary 0..13 maps directly to SRF column 0..13; two local producer slots remain independent.' },
  ], [boundary, direction, hopLatency, operation, preserve])

  const stageDurations = useMemo(() => stages.map((_, index) => index === 2 ? hopLatency : 1), [hopLatency, stages])
  const stageStarts = useMemo(() => stageDurations.map((_, index) => stageDurations.slice(0, index).reduce((sum, duration) => sum + duration, 0)), [stageDurations])
  const maxCycle = stageDurations.reduce((sum, duration) => sum + duration, 0) - 1
  const step = stageStarts.reduce((current, start, index) => cycle >= start ? index : current, 0)
  const stageCycle = cycle - stageStarts[step] + 1
  const activeDuration = stageDurations[step]
  const controlHopActive = step === 2

  useEffect(() => {
    setCycle(0)
    setPlaying(false)
  }, [operation, direction, hopLatency, preserve])
  useEffect(() => {
    if (!playing) return undefined
    const timer = window.setInterval(() => setCycle((current) => {
      if (current >= maxCycle) { setPlaying(false); return current }
      return current + 1
    }), 750)
    return () => window.clearInterval(timer)
  }, [maxCycle, playing])

  return <section className="mem-propagation-panel" data-mem-operation={operation} data-mem-direction={direction}>
    <header>
      <div><span>INTERACTIVE RTL PROPAGATION</span><strong>READ / WRITE 状态传播</strong></div>
      <small>点击步骤或播放，观察方向、边界、控制延迟和 SRAM 事件</small>
    </header>
    <div className="mem-propagation-controls">
      <div role="group" aria-label="MEM operation"><button className={operation === 'read' ? 'active' : ''} onClick={() => setOperation('read')}>READ</button><button className={operation === 'write' ? 'active' : ''} onClick={() => setOperation('write')}>WRITE</button></div>
      <div role="group" aria-label="MEM direction"><button className={direction === 'east' ? 'active' : ''} onClick={() => setDirection('east')}>EAST</button><button className={direction === 'west' ? 'active' : ''} onClick={() => setDirection('west')}>WEST</button></div>
      <div role="group" aria-label="Control hop latency"><button className={hopLatency === 1 ? 'active' : ''} onClick={() => setHopLatency(1)}>1-CYCLE</button><button className={hopLatency === 3 ? 'active' : ''} onClick={() => setHopLatency(3)}>3-CYCLE</button></div>
      <div className={`mem-clock-counter ${controlHopActive ? 'hop-active' : ''}`} aria-live="polite"><span>CLOCK</span><b>C{cycle}</b><small>{controlHopActive ? `CONTROL HOP ${stageCycle}/${activeDuration}` : `STAGE ${step + 1}/${stages.length}`}</small><i>{Array.from({ length: hopLatency }, (_, index) => <em className={controlHopActive && index < stageCycle ? 'active' : ''} key={index} />)}</i></div>
      {operation === 'write' && <label><input type="checkbox" name="mem-writetap-preserve" checked={preserve} onChange={(event) => setPreserve(event.target.checked)} /> WriteTap / Preserve</label>}
    </div>
    <div className="mem-propagation-track">
      {stages.map((stage, index) => <div className="mem-propagation-stage-wrap" key={`${operation}-${stage.title}`}>
        <button className={`mem-propagation-stage ${index === step ? 'active' : ''} ${index < step ? 'complete' : ''}`} onClick={() => { setPlaying(false); setCycle(stageStarts[index]) }}>
          <span>{String(index + 1).padStart(2, '0')}</span><strong>{stage.title}</strong><small>{stage.note}</small>{index === step && <i className="mem-stage-clock">C{cycle} · {stageCycle}/{activeDuration}</i>}
        </button>
        {index < stages.length - 1 && <b className={index < step ? 'complete' : ''}>→</b>}
      </div>)}
    </div>
    <footer>
      <button onClick={() => { setPlaying(false); setCycle((current) => Math.max(0, current - 1)) }} disabled={cycle === 0}>上一时钟</button>
      <button className="play" onClick={() => { if (cycle >= maxCycle) setCycle(0); setPlaying((current) => !current) }}>{playing ? '暂停' : '播放传播'}</button>
      <button onClick={() => { setPlaying(false); setCycle((current) => Math.min(maxCycle, current + 1)) }} disabled={cycle === maxCycle}>下一时钟</button>
      <span>C{cycle}/{maxCycle} · {operation.toUpperCase()} · {direction.toUpperCase()} · {hopLatency}-cycle · {boundary}</span>
    </footer>
  </section>
}

function SrfFabric({ current, nodes, onOpen }: { current: ArchitectureDrillNode; nodes: Map<string, ArchitectureDrillNode>; onOpen: (node: ArchitectureDrillNode) => void }) {
  const fabric = current.childIds.map((id) => nodes.get(id)).find((node) => node?.nodeType === 'srf-fabric')
  const columns = fabric?.childIds.map((id) => nodes.get(id)).filter((node): node is ArchitectureDrillNode => Boolean(node && node.nodeType === 'srf-column')) ?? []
  return <section className="mem-srf-fabric" data-mem-view="srf-fabric">
    <header><div><span>PARALLEL DATA PLANE</span><strong>MEM ↔ SRF Hemisphere Fabric</strong></div><small>16 columns · 4 superlanes · 32 streams / direction · 64-bit segments</small></header>
    <div className="mem-srf-boundaries"><span>WEST EDGE</span>{Array.from({ length: 14 }, (_, boundary) => <b key={boundary}>B{boundary}</b>)}<span>EAST EDGE</span></div>
    <div className="mem-srf-columns">
      {columns.map((column, index) => <button key={column.id} className={index < 14 ? 'mapped' : 'unmapped'} onClick={() => onOpen(column)}><span>C{index}</span><strong>{index < 14 ? `MEM B${index}` : index === 14 ? 'Named MXM boundary' : 'Active extra column'}</strong><small>4 × 32 × 64</small></button>)}
    </div>
    <div className="mem-srf-direction-row"><b>EAST</b><span>Write consumes left · Read injects right</span><i>→</i></div>
    <div className="mem-srf-direction-row west"><i>←</i><span>Write consumes right · Read injects left</span><b>WEST</b></div>
    <footer><span>MEM boundaries 0..13 map one-to-one to SRF columns 0..13.</span><span>Columns 14..15 are not hidden or misrepresented as MEM groups.</span></footer>
  </section>
}

function MemRoot({ block, current, nodes, onOpen }: { block: PhysicalFunctionalBlock; current: ArchitectureDrillNode; nodes: Map<string, ArchitectureDrillNode>; onOpen: (node: ArchitectureDrillNode) => void }) {
  const base = current.id
  const frontend = nodeBySuffix(nodes, base, 'local-issue-path')
  const adapter = nodeBySuffix(nodes, base, 'native-adapter')
  const execution = nodeBySuffix(nodes, base, 'execution')
  const streams = nodeBySuffix(nodes, base, 'streams')
  return <div className="mem-functional-explorer mem-root-view" data-mem-view="overview">
    <div className="mem-overview-hero">
      <div><span>L2 · FUNCTIONAL BLOCK / MEM</span><h2>{block.regionId.toUpperCase()} MEM · Native Execution + SRF</h2><p>Bank-local instruction generation、Native 存储阵列与 SRF 流数据面并行展示；所有数量和方向均来自当前权威 RTL。</p></div>
      <dl><div><dt>HEMISPHERES</dt><dd>2</dd></div><div><dt>FRONTENDS</dt><dd>104 / Hemi</dd></div><div><dt>BANKS</dt><dd>104 / Hemi</dd></div><div><dt>LEAVES</dt><dd>416 / Hemi</dd></div></dl>
    </div>
    <div className="mem-plane-grid">
      <section className="mem-plane control"><header><span>INSTRUCTION / CONTROL PLANE</span><strong>Bank-local Macro Frontend</strong><small>104 / Hemisphere · 208 system-wide</small></header>{frontend && <MemNodeButton node={frontend} onOpen={() => onOpen(frontend)} />}{adapter && <MemNodeButton node={adapter} onOpen={() => onOpen(adapter)} />}<footer>Scheduler mem_issue_* → MEM64 / Native32 adapter · no independent lpu_mem_instruction_queue</footer></section>
      <section className="mem-plane execution"><header><span>NATIVE MEM EXECUTION ARRAY</span><strong>13 Groups · 52 Slices · 104 Banks</strong><small>4 behavioral SRAM leaves / Bank</small></header>{execution && <MemNodeButton node={execution} onOpen={() => onOpen(execution)} />}<div className="mem-count-formula"><b>13</b><i>×</i><b>4</b><i>×</i><b>2</b><i>×</i><b>4</b><span>= 416 × 8192 × 64-bit leaves / Hemisphere</span></div><footer>mem_logical_bank_column = one control column + four independent SRAM leaves</footer></section>
      <section className="mem-plane stream"><header><span>STREAM / SRF DATA PLANE</span><strong>Parallel Hemisphere Fabric</strong><small>14 MEM boundaries mapped into 16 SRF columns</small></header>{streams && <MemNodeButton node={streams} onOpen={() => onOpen(streams)} />}<div className="mem-stream-matrix"><span>2 DIR</span><span>16 COL</span><span>4 SL</span><span>32 STREAM</span><span>64 BIT</span></div><footer>lpu_mem_srf_integration connects MEM and ftlpu_sr_hemisphere_fabric; neither contains the other.</footer></section>
    </div>
    <PropagationPanel region={block.regionId} />
  </div>
}

function MemHierarchy({ current, nodes, onOpen, onSelectNode }: { current: ArchitectureDrillNode; nodes: Map<string, ArchitectureDrillNode>; onOpen: (node: ArchitectureDrillNode) => void; onSelectNode: (id: string) => void }) {
  const children = current.childIds.map((id) => nodes.get(id)).filter((node): node is ArchitectureDrillNode => Boolean(node))
  const isExecution = current.nodeType === 'execution-array'
  const isGroup = current.nodeType === 'memory-group'
  const isSlice = current.nodeType === 'memory-slice'
  const isBank = current.nodeType === 'memory-bank'
  const isLeaf = current.nodeType === 'sram-leaf'
  const bankControl = isBank ? children.find((child) => child.nodeType === 'instruction-control') : undefined
  const bankLeaves = isBank ? children.filter((child) => child.nodeType === 'sram-leaf') : []
  const showBankColumn = Boolean(bankControl && bankLeaves.length === 4)
  return <div className={`mem-functional-explorer mem-hierarchy-view view-${current.nodeType}`} data-mem-view={current.nodeType}>
    <header className="mem-hierarchy-header"><div><span>{current.nodeType.replaceAll('-', ' ').toUpperCase()}</span><h2>{current.displayName}</h2><p>{current.description}</p></div><dl>{current.parameterRefs.map((parameter) => <div key={parameter.name}><dt>{parameter.name}</dt><dd>{parameter.value ?? parameter.expression}</dd></div>)}</dl></header>
    {isExecution && <div className="mem-array-summary"><span>13 GROUPS</span><b>→</b><span>52 SLICES</span><b>→</b><span>104 BANKS</span><b>→</b><span>416 LEAVES</span></div>}
    {isGroup && <div className="mem-boundary-note"><b>Left Boundary g</b><span>4 Slices share the same cycle-start boundary state</span><b>Right Boundary g+1</b></div>}
    {isSlice && <div className="mem-boundary-note"><b>Bank 0</b><span>Independent command/data paths; no bank-global arbitration</span><b>Bank 1</b></div>}
    {isBank && bankControl && showBankColumn && <section className="mem-bank-vertical-layout" aria-label="Bank South to North control column and four Superlane SRAM leaves">
      <header><b>NORTH ↑ · trace only</b><span>4 independent 8192 × 64-bit leaves · logical South → North order</span></header>
      <div className="mem-bank-column-body">
        <div className="mem-bank-control-rail"><strong>CONTROL COLUMN ↑</strong><MemNodeButton node={bankControl} onOpen={() => onOpen(bankControl)} /><span>SOUTH Native32 ↑</span></div>
        <div className="mem-bank-leaf-stack">{[...bankLeaves].reverse().map((leaf) => <div className="mem-bank-leaf-row" key={leaf.id}><span aria-hidden="true">→</span><MemNodeButton node={leaf} onOpen={() => onOpen(leaf)} /></div>)}</div>
      </div>
      <footer>Tile 0 接收 South 指令；Tile 1–3 沿 Control Column 依次接收，各 hop 为 1 或 3 周期。图示为 RTL 逻辑顺序。</footer>
    </section>}
    {isLeaf && <div className="mem-leaf-facts"><span><b>ROW</b> 8 lanes × 8 bit = 64 bit</span><span><b>READ</b> one registered response cycle</span><span><b>WRITE</b> single-port row write</span><span><b>RESET</b> control only; SRAM contents retained</span></div>}
    {!showBankColumn && (children.length ? <div className={`mem-hierarchy-grid ${isExecution ? 'groups' : ''} ${isBank ? 'bank' : ''}`}>{children.map((child) => <MemNodeButton key={child.id} node={child} onOpen={() => onOpen(child)} />)}</div> : <div className="mem-leaf-evidence"><strong>当前节点为 RTL 叶级证据</strong><p>{current.rtlModuleRefs.join(' · ')}</p><button onClick={() => onSelectNode(current.id)}>在 Inspector 中查看源文件和参数</button></div>)}
    {(isBank || isLeaf) && <PropagationPanel region={current.blockId.includes(':east:') ? 'east' : 'west'} />}
  </div>
}

export default function MemFunctionalExplorer({ block, current, nodes, onNavigate, onSelectNode }: Props) {
  const open = (node: ArchitectureDrillNode) => node.childIds.length ? onNavigate(node.id) : onSelectNode(node.id)
  if (!current.parentId) return <MemRoot block={block} current={current} nodes={nodes} onOpen={open} />
  if (current.nodeType === 'stream-interface') return <div className="mem-functional-explorer"><SrfFabric current={current} nodes={nodes} onOpen={open} /><PropagationPanel region={block.regionId} /></div>
  return <MemHierarchy current={current} nodes={nodes} onOpen={open} onSelectNode={onSelectNode} />
}
