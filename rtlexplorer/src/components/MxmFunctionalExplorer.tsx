import { useEffect, useMemo, useState } from 'react'
import type { ArchitectureDrillNode, PhysicalFunctionalBlock } from '../types'

interface Props {
  block: PhysicalFunctionalBlock
  current: ArchitectureDrillNode
  nodes: Map<string, ArchitectureDrillNode>
  onNavigate: (id: string) => void
  onSelectNode: (id: string) => void
}

type FlowKind = 'control' | 'activation' | 'weight' | 'partial' | 'result'
const flowLabels: Record<FlowKind, string> = { control: 'Instruction / Control', activation: 'Activation', weight: 'Weight / Dequant', partial: 'FP32 Partial Sum', result: 'Result / Backend' }

function child(nodes: Map<string, ArchitectureDrillNode>, node: ArchitectureDrillNode, type: string) {
  return node.childIds.map((id) => nodes.get(id)).find((item) => item?.nodeType === type)
}

function MetricStrip({ items }: { items: Array<[string, string | number]> }) {
  return <dl className="mxm-metrics">{items.map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}</dl>
}

function OpenCard({ node, tone, onOpen }: { node: ArchitectureDrillNode; tone: FlowKind; onOpen: () => void }) {
  const hasArchitectureView = node.childIds.length > 0 || ['mxm-csa', 'mxm-result-return', 'mxm-backend-column'].includes(node.nodeType)
  return <button className={`mxm-open-card tone-${tone}`} onClick={onOpen} data-mxm-node={node.nodeType}>
    <span>{node.nodeType.replaceAll('-', ' ').toUpperCase()}</span>
    <strong>{node.displayName}</strong>
    <i>{hasArchitectureView ? '点击进入结构' : '查看 RTL 证据'} →</i>
  </button>
}

const icuStorageSpecs: Record<string, { width: string; depth: string }> = {
  'Local iMEM': { width: '128 bit', depth: '65,536 words' },
  'Word FIFO': { width: '129 bit', depth: '4 entries' },
  'Context FIFO': { width: '288 bit', depth: '4 entries' },
}

function MxmLegend({ active, onChange }: { active: FlowKind; onChange: (kind: FlowKind) => void }) {
  return <div className="mxm-legend" aria-label="MXM data flow legend">{(Object.keys(flowLabels) as FlowKind[]).map((kind) => <button key={kind} className={`tone-${kind} ${active === kind ? 'active' : ''}`} onClick={() => onChange(kind)}><i />{flowLabels[kind]}</button>)}</div>
}

function MxmRoot({ block, current, nodes, open }: { block: PhysicalFunctionalBlock; current: ArchitectureDrillNode; nodes: Map<string, ArchitectureDrillNode>; open: (node: ArchitectureDrillNode) => void }) {
  const local = child(nodes, current, 'mxm-five-stream-icu')
  const core = child(nodes, current, 'mxm-core')
  return <div className="mxm-explorer mxm-root" data-mxm-view="architecture-root">
    <header className="mxm-hero"><div><span>CURRENT LOCAL RTL · TOP INTEGRATED</span><h2>{block.displayName} · MXM Architecture</h2><p>当前路径由五条 FU-local ICU stream 直接驱动新参数化 Core；旧 Issue Queue、Local Coordinator 和 legacy Slice 架构均不再展示。</p></div><MetricStrip items={[["ICU STREAMS", 5], ["QCTL ENDPOINTS", 5], ['ARRAY', '4 × 4 SC'], ['MULTIPLIERS', 1024]]} /></header>
    <div className="mxm-integration-path"><span>Program Load</span><b>→</b><span>5 × local iMEM Frontend</span><b>→</b><span>Scheduler + QCTL Gate</span><b>→</b><strong>5 × Native Port → lpu_mxm_core</strong></div>
    <div className="mxm-root-grid">{local && <OpenCard node={local} tone="control" onOpen={() => open(local)} />}{core && <OpenCard node={core} tone="result" onOpen={() => open(core)} />}</div>
    <aside className="mxm-rtl-verdict"><b>RTL 核实结论</b><span>当前本地 `lpu_mxm_subsystem.sv` 已明确实例化 `lpu_mxm_core u_execution`，因此这里不是 Standalone/WIP Core，也不再并列展示 legacy 实现。</span></aside>
  </div>
}

function FiveStreamIcuView({ current, nodes, open }: { current: ArchitectureDrillNode; nodes: Map<string, ArchitectureDrillNode>; open: (node: ArchitectureDrillNode) => void }) {
  const decoder = child(nodes, current, 'mxm-shared-decoder')
  const streams = current.childIds.map((id) => nodes.get(id)).filter((item): item is ArchitectureDrillNode => item?.nodeType === 'mxm-icu-stream')
  return <div className="mxm-explorer mxm-icu-view" data-mxm-view="five-stream-icu">
    <header className="mxm-section-head"><div><span>FU-LOCAL ICU · FIVE INDEPENDENT STREAMS</span><h2>Local iMEM → Decoder → Scheduler → Native Port</h2><p>五条流使用相同的 Decoder RTL 架构但拥有独立状态；Scheduler 后直接进入 QCTL gating 和 native ready/valid 端口，不存在 Instruction Queue。</p></div><MetricStrip items={[["STREAMS", 5], ['DECODER RTL', '1 shared architecture'], ['INSTANCES', 5], ['POST-SCHEDULER QUEUE', 'None']]} /></header>
    {decoder && <OpenCard node={decoder} tone="control" onOpen={() => open(decoder)} />}
    <div className="mxm-icu-streams">{streams.map((stream) => <section key={stream.id}>
      <header><strong>{stream.displayName}</strong><small>{stream.tags?.find((tag) => tag.label === 'QCTL GLOBAL IDS')?.value}</small></header>
      <div>{['Local iMEM', 'Fetch', 'Word FIFO', 'Shared Decoder Instance', 'Context FIFO', 'Stream Scheduler', 'QCTL Gate', 'Native Port'].map((stage, index) => {
        const spec = icuStorageSpecs[stage]
        return <span key={stage} className={spec ? 'has-storage-spec' : ''} tabIndex={spec ? 0 : undefined}><b>{stage}</b>{spec && <span className="mxm-storage-spec" role="tooltip"><em><small>WIDTH</small><strong>{spec.width}</strong></em><em><small>DEPTH</small><strong>{spec.depth}</strong></em></span>}{index < 7 && <i>→</i>}</span>
      })}</div>
    </section>)}</div>
  </div>
}

function MxmDecoderView({ current }: { current: ArchitectureDrillNode }) {
  const nodeWidth = 180
  const nodeHeight = 76
  const state = (name: string, x: number, y: number, tone: 'main' | 'idle' | 'fault' = 'main', note?: string) => <g className={`mxm-decoder-state ${tone}`} key={name}>
    <rect x={x} y={y} width={nodeWidth} height={nodeHeight} />
    <text x={x + nodeWidth / 2} y={y + (note ? 31 : 45)}>{name}</text>
    {note && <text className="note" x={x + nodeWidth / 2} y={y + 54}>{note}</text>}
  </g>
  return <div className="mxm-explorer mxm-decoder-view" data-mxm-view="shared-decoder">
    <header className="mxm-section-head"><div><span>SHARED ARCHITECTURE · INDEPENDENT STATE PER STREAM</span><h2>{current.displayName}</h2><p>{current.description}</p></div><MetricStrip items={[["RTL STATES", 12], ['INSTANCES / MXM', 5], ['QUEUE EMPTY', 'IDLE self-loop'], ['COMPLETION', 'done_o=1']]} /></header>
    <div className="mxm-decoder-diagram">
      <svg viewBox="0 0 1720 900" role="img" aria-label="Complete shared MXM macro decoder state transition diagram">
        <defs>
          <marker id="mxm-decoder-arrow" markerUnits="userSpaceOnUse" markerWidth="9" markerHeight="9" refX="8" refY="4.5" orient="auto"><path d="M0,0 L9,4.5 L0,9 z" /></marker>
          <marker id="mxm-decoder-fault-arrow" markerUnits="userSpaceOnUse" markerWidth="9" markerHeight="9" refX="8" refY="4.5" orient="auto"><path d="M0,0 L9,4.5 L0,9 z" /></marker>
        </defs>

        <path className="mxm-decoder-edge" d="M 240 126 V 180" markerEnd="url(#mxm-decoder-arrow)" />
        <path className="mxm-decoder-edge" d="M 240 256 V 310" markerEnd="url(#mxm-decoder-arrow)" />
        <path className="mxm-decoder-edge" d="M 240 386 V 420 H 510 V 450" markerEnd="url(#mxm-decoder-arrow)" />
        <path className="mxm-decoder-edge" d="M 600 488 H 650" markerEnd="url(#mxm-decoder-arrow)" />
        <path className="mxm-decoder-edge" d="M 830 488 H 880" markerEnd="url(#mxm-decoder-arrow)" />
        <text className="mxm-decoder-edge-label" x="855" y="472">subsequent macro</text>

        <path className="mxm-decoder-edge" d="M 740 450 V 270 H 1620 V 450" markerEnd="url(#mxm-decoder-arrow)" />
        <text className="mxm-decoder-edge-label" x="1120" y="252">first macro pending</text>

        <path className="mxm-decoder-edge" d="M 1060 474 L 1100 388" markerEnd="url(#mxm-decoder-arrow)" />
        <text className="mxm-decoder-edge-label" x="1072" y="412">escape</text>
        <path className="mxm-decoder-edge" d="M 1060 502 L 1100 588" markerEnd="url(#mxm-decoder-arrow)" />
        <text className="mxm-decoder-edge-label" x="1068" y="560">dictionary</text>
        <path className="mxm-decoder-edge" d="M 1280 388 L 1330 474" markerEnd="url(#mxm-decoder-arrow)" />
        <path className="mxm-decoder-edge" d="M 1280 588 L 1330 502" markerEnd="url(#mxm-decoder-arrow)" />
        <path className="mxm-decoder-edge" d="M 1510 488 H 1530" markerEnd="url(#mxm-decoder-arrow)" />

        <path className="mxm-decoder-edge loop" d="M 1620 526 V 650 H 970 V 526" markerEnd="url(#mxm-decoder-arrow)" />
        <text className="mxm-decoder-edge-label" x="1260" y="639">context_fire · middle of run</text>
        <path className="mxm-decoder-edge loop" d="M 1680 526 V 840 H 510 V 796" markerEnd="url(#mxm-decoder-arrow)" />
        <text className="mxm-decoder-edge-label" x="1030" y="829">context_fire · end of run</text>
        <path className="mxm-decoder-edge" d="M 510 720 V 526" markerEnd="url(#mxm-decoder-arrow)" />
        <text className="mxm-decoder-edge-label" x="525" y="636">start next run</text>

        <path className="mxm-decoder-edge loop" d="M 420 758 C 350 758 350 835 420 835" markerEnd="url(#mxm-decoder-arrow)" />
        <text className="mxm-decoder-edge-label" x="272" y="804">no macro · done_o=1</text>
        <path className="mxm-decoder-edge loop" d="M 1620 450 C 1620 385 1710 385 1710 450" markerEnd="url(#mxm-decoder-arrow)" />
        <text className="mxm-decoder-edge-label" x="1648" y="370">hold until ready</text>

        <path className="mxm-decoder-edge fault" d="M 330 88 H 520" markerEnd="url(#mxm-decoder-fault-arrow)" />
        <text className="mxm-decoder-edge-label fault" x="425" y="73">illegal control</text>
        <path className="mxm-decoder-edge fault" d="M 420 758 H 80 V 20 H 610 V 50" markerEnd="url(#mxm-decoder-fault-arrow)" />
        <text className="mxm-decoder-edge-label fault" x="290" y="38">illegal control · IDLE</text>
        <path className="mxm-decoder-edge fault" d="M 700 88 C 780 88 780 175 610 175 C 545 175 535 145 550 126" markerEnd="url(#mxm-decoder-fault-arrow)" />
        <text className="mxm-decoder-edge-label fault" x="718" y="154">FAULT is sticky</text>

        {state('IDLE_GLOBAL', 150, 50, 'idle')}
        {state('DICT_STORE', 150, 180)}
        {state('INIT_GLOBAL', 150, 310)}
        {state('RUN_HEADER', 420, 450)}
        {state('TEMPLATE', 650, 450)}
        {state('GET_DELTA', 880, 450)}
        {state('ESCAPE', 1100, 350, 'main', 'compact / wide')}
        {state('DICT_LOOKUP', 1100, 550)}
        {state('APPLY_DELTA', 1330, 450)}
        {state('OUTPUT_CONTEXT', 1530, 450)}
        {state('IDLE', 420, 720, 'idle')}
        {state('FAULT', 520, 50, 'fault', 'decode fault exit')}
      </svg>
    </div>
  </div>
}

function CoreOverview({ current, nodes, open }: { current: ArchitectureDrillNode; nodes: Map<string, ArchitectureDrillNode>; open: (node: ArchitectureDrillNode) => void }) {
  const frontend = child(nodes, current, 'mxm-frontend')
  const result = child(nodes, current, 'mxm-result-return')
  const backend = child(nodes, current, 'mxm-backend')
  const stages = [frontend, result, backend].filter((item): item is ArchitectureDrillNode => Boolean(item))
  return <div className="mxm-explorer mxm-core-view" data-mxm-view="core">
    <header className="mxm-section-head"><div><span>L3 · INTEGRATED MXM CORE</span><h2>Frontend → Result Return → Backend</h2><p>计算阵列、静态等延迟回传和独立调度的 FP32 累加存储构成当前 Core。</p></div><MetricStrip items={[["FRONTEND OUT", '4 × 8 FP32'], ['RETURN', '4 cycles'], ['BACKEND', '4 columns'], ['STORAGE', '128 KiB']]} /></header>
    <div className="mxm-core-chain">{stages.map((node, index) => <div className="mxm-core-stage" key={node.id}><OpenCard node={node} tone={index === 0 ? 'activation' : index === 1 ? 'result' : 'result'} onOpen={() => open(node)} />{index < stages.length - 1 && <b className="mxm-chain-arrow">→</b>}</div>)}</div>
    <div className="mxm-core-contract"><span><b>Frontend</b> 1024 BF16 multipliers + vertical partial accumulation</span><span><b>Return</b> Down + Left static registers, equal 4-cycle path</span><span><b>Backend</b> 32 FP32 adders + 8 logical 512×256 banks</span></div>
  </div>
}

const rowsTopDown = [3, 2, 1, 0]
const cols = [0, 1, 2, 3]

function SupercellArray({ current, nodes, activeFlow, selectSC }: { current: ArchitectureDrillNode; nodes: Map<string, ArchitectureDrillNode>; activeFlow: FlowKind; selectSC: (row: number, col: number, node: ArchitectureDrillNode) => void }) {
  const sc = current.nodeType === 'mxm-supercell-array' ? child(nodes, current, 'mxm-supercell') : [...nodes.values()].find((item) => item.nodeType === 'mxm-supercell' && item.blockId === current.blockId)
  if (!sc) return null
  return <section className={`mxm-array-board highlight-${activeFlow}`} data-mxm-view="supercell-array">
    <div className="mxm-array-control"><span>CONTROL WAVE</span><b>T+9</b><b>T+6</b><b>T+3</b><b>T</b><small>Row0 is physically bottom · fixed 3-cycle interval</small></div>
    <div className="mxm-array-grid">
      {rowsTopDown.map((row) => <div className="mxm-array-row" key={row}>
        <span className="mxm-row-ingress"><b>A{row}</b><small>8×BF16</small></span>
        {cols.map((col) => <button key={`${row}-${col}`} onClick={() => selectSC(row, col, sc)} data-sc={`r${row}c${col}`}><i className="weight-link" /><span>SC[{row},{col}]</span><strong>8 Groups × 8 Mul</strong><small>WB0 / WB1</small><em className="partial-up">↑ PS</em></button>)}
        <span className="mxm-row-forward">A/W →</span>
      </div>)}
    </div>
    <div className="mxm-column-results">{cols.map((col) => <span key={col}><b>Column {col}</b><small>8 × FP32 top result</small></span>)}</div>
  </section>
}

function FrontendOverview({ current, nodes, open, activeFlow, setActiveFlow, selectSC }: { current: ArchitectureDrillNode; nodes: Map<string, ArchitectureDrillNode>; open: (node: ArchitectureDrillNode) => void; activeFlow: FlowKind; setActiveFlow: (kind: FlowKind) => void; selectSC: (row: number, col: number, node: ArchitectureDrillNode) => void }) {
  const frontend = current.nodeType === 'mxm-frontend' ? current : nodes.get(current.parentId ?? '')
  if (!frontend) return null
  const control = child(nodes, frontend, 'mxm-control-wave')
  const ingress = child(nodes, frontend, 'mxm-ingress')
  const array = child(nodes, frontend, 'mxm-supercell-array')
  return <div className="mxm-explorer mxm-frontend-view" data-mxm-view="frontend">
    <header className="mxm-section-head"><div><span>L4 · MXM FRONTEND</span><h2>Control / Ingress / 4×4 Supercell Array</h2><p>四种传播关系严格分色：控制错拍、Activation 横向、Weight 横向、FP32 Partial Sum 自下而上。</p></div><MetricStrip items={[["SC", 16], ['GROUP / SC', 8], ['MATRIX', 'K32 × N32'], ['TOP OUTPUT', '32 × FP32']]} /></header>
    <MxmLegend active={activeFlow} onChange={setActiveFlow} />
    <div className="mxm-frontend-tools">{control && <OpenCard node={control} tone="control" onOpen={() => open(control)} />}{ingress && <OpenCard node={ingress} tone="weight" onOpen={() => open(ingress)} />}</div>
    {array && <SupercellArray current={array} nodes={nodes} activeFlow={activeFlow} selectSC={selectSC} />}
  </div>
}

function InstructionWave({ current }: { current: ArchitectureDrillNode }) {
  const [kind, setKind] = useState('Compute')
  const [cycle, setCycle] = useState(0)
  const [playing, setPlaying] = useState(false)
  useEffect(() => { if (!playing) return; const timer = window.setInterval(() => setCycle((value) => value >= 9 ? 0 : value + 1), 780); return () => window.clearInterval(timer) }, [playing])
  const arrivals = [0, 3, 6, 9]
  const activeRow = arrivals.findIndex((arrival) => arrival === cycle)
  const pipelineStages = Array.from({ length: 10 }, (_, index) => 9 - index)
  return <div className="mxm-explorer mxm-wave-view" data-mxm-view="instruction-wave">
    <header className="mxm-section-head"><div><span>BOTTOM-UP REGISTER WAVE · II=1</span><h2>{current.displayName}</h2><p>launch_i 在 T+0 写入最底部 stage 0；指令每拍沿左侧寄存器列上移，stage 0/3/6/9 分别驱动真实 Row0/1/2/3，中间两拍停留在 stage 1/2、4/5、7/8。</p></div><MetricStrip items={[["QUEUE", '16 entries'], ['REGISTER WAVE', '10 stages · 0–9'], ['ROW TAPS', '0 / 3 / 6 / 9'], ['DIRECTION', 'Row0 ↑ Row3']]} /></header>
    <div className="mxm-wave-controls"><div>{['Compute', 'Load', 'Param Load', 'Dequant'].map((item) => <button className={kind === item ? 'active' : ''} onClick={() => { setKind(item); setCycle(0) }} key={item}>{item}</button>)}</div><button onClick={() => setCycle(Math.max(0, cycle - 1))}>− Cycle</button><strong>T+{cycle}</strong><button onClick={() => setCycle(Math.min(9, cycle + 1))}>+ Cycle</button><button className="play" onClick={() => setPlaying((value) => !value)}>{playing ? '暂停' : '自动播放'}</button></div>
    <div className="mxm-wave-clock-strip" aria-label="Instruction wave cycle selector">{Array.from({ length: 10 }, (_, stage) => <button type="button" onClick={() => setCycle(stage)} className={`${stage === cycle ? 'current' : ''} ${arrivals.includes(stage) ? 'row-tap' : ''}`} key={stage}><small>STAGE</small><b>{stage}</b><span>T+{stage}</span></button>)}</div>
    <section className="mxm-wave-array" aria-label="Bottom-up instruction propagation through ten registers and the real 4 by 4 Supercell array">
      <div className="mxm-wave-column-headings"><span>10-STAGE REGISTER PIPELINE</span><span>REAL 4×4 SUPERCELL ARRAY</span></div>
      <div className="mxm-wave-lattice">
        <div className="mxm-wave-register-spine" aria-label="Instruction register stages 9 through 0">
          {pipelineStages.map((stage) => {
            const tapRow = arrivals.indexOf(stage)
            const state = stage === cycle ? 'active' : cycle > stage ? 'passed' : 'pending'
            return <div className={`mxm-wave-stage-register ${state} ${tapRow >= 0 ? 'row-tap' : 'intermediate'}`} data-wave-stage={stage} key={stage}>
              <b>↑</b><section><small>STAGE</small><strong>{stage}</strong><span>{tapRow >= 0 ? `ROW ${tapRow} TAP` : 'INTERMEDIATE REG'}</span></section>{tapRow >= 0 && <em>→ ROW {tapRow}</em>}
            </div>
          })}
        </div>
        <div className="mxm-wave-sc-lattice">
          {rowsTopDown.map((row) => {
            const arrival = arrivals[row]
            const state = activeRow === row ? 'active' : cycle > arrival ? 'passed' : 'pending'
            return <div className={`mxm-wave-array-row ${state}`} data-wave-row={row} style={{ gridRow: 10 - arrival }} key={row}>
              <header><span>ROW {row}</span><b>STAGE {arrival}</b><small>T+{arrival}</small></header>
              <div>{cols.map((col) => <span className="mxm-wave-sc" key={col}><b>SC[{row},{col}]</b><small>{activeRow === row ? `${kind} 更新` : cycle > arrival ? '指令已上移' : '等待指令'}</small></span>)}</div>
            </div>
          })}
        </div>
      </div>
      <div className={`mxm-wave-launch ${cycle === 0 ? 'active' : 'passed'}`}>
        <b>↑</b><section><span>FIRST INSTRUCTION LAUNCH</span><strong>{kind} Queue → launch_i</strong><small>T+0：stage 0 捕获，并在最底部 Row0 的四个 SC 同拍生效</small></section>
      </div>
    </section>
    <aside className="mxm-wave-rtl-note"><b>RTL 对应</b><span>valid_q 每拍移入下一寄存器；row_valid_o[r] = valid_q[r × INTERVAL]。ROWS=4、INTERVAL=3，因此真实 Row tap 为 stage 0 / 3 / 6 / 9，其余 stage 1/2、4/5、7/8 仍显示指令正在寄存器中流动。</span></aside>
  </div>
}

function IngressView({ current, nodes, open }: { current: ArchitectureDrillNode; nodes: Map<string, ArchitectureDrillNode>; open: (node: ArchitectureDrillNode) => void }) {
  const dequant = child(nodes, current, 'mxm-dequant-pipeline')
  return <div className="mxm-explorer"><header className="mxm-section-head"><div><span>ACTIVATION / WEIGHT INGRESS</span><h2>{current.displayName}</h2><p>{current.description}</p></div><MetricStrip items={[["ACTIVATION", '4 × 8 BF16'], ['WEIGHT STREAMS', 32], ['PARAM BUFFERS', 2], ['DESTINATION', 'SC Weight Register']]} /></header><div className="mxm-ingress-lanes"><section className="tone-activation"><b>Activation</b><span>4 independent rows</span><span>8 BF16 elements / row / cycle</span><span>valid + buffer ID + tag move together</span></section><section className="tone-weight"><b>Weight / Parameters</b><span>32 fixed byte streams</span><span>Q + scale lo/hi + zero point</span><span>D3 writes BF16 directly into selected buffer</span></section></div>{dequant && <OpenCard node={dequant} tone="weight" onOpen={() => open(dequant)} />}</div>
}

function PipelineView({ current, nodes, open }: { current: ArchitectureDrillNode; nodes: Map<string, ArchitectureDrillNode>; open: (node: ArchitectureDrillNode) => void }) {
  const isDot = current.nodeType === 'mxm-dot-pipeline'
  const isDequant = current.nodeType === 'mxm-dequant-pipeline'
  const labels = isDot ? ['M1', 'M2', 'R1', 'R2', 'R3', 'R4', 'R5', 'R6', 'R7'] : isDequant ? ['D1', 'D2', 'D3'] : ['A1', 'A2', 'A3']
  const notes = isDot ? ['8×8 significand multiply', 'Product normalize', 'Common exponent', 'Align + sign', 'CSA levels 1–2', 'CSA levels 3–4', 'Carry propagate', 'Sign / LZC / normalize', 'FP32 RNE + pack'] : isDequant ? ['INT8−zero / Scale decode', 'Multiply / shift detect', 'Shift / RNE / BF16 write'] : ['Exponent align / specials', 'Significand add/sub', 'Normalize / RNE / FP32']
  const csa = isDot ? child(nodes, current, 'mxm-csa') : undefined
  const track = <div className={`mxm-pipeline-track ${isDequant ? 'tone-weight' : isDot ? 'tone-activation' : 'tone-partial'}`}>
    {labels.map((label, index) => <div key={label} className={isDot && (label === 'R3' || label === 'R4') ? 'contains-csa' : undefined}>
      <span>{label}</span><strong>{notes[index]}</strong>{index < labels.length - 1 && <b>→</b>}
    </div>)}
  </div>
  return <div className="mxm-explorer mxm-pipeline-view" data-mxm-view={current.nodeType}>
    <header className="mxm-section-head"><div><span>{isDot ? 'BF16 DOT · II=1' : isDequant ? 'LOAD-ONLY WEIGHT PATH' : 'FRONTEND PARTIAL SUM · II=1'}</span><h2>{current.displayName}</h2><p>{current.description}</p></div><MetricStrip items={[["STAGES", labels.length], ['BOUNDARY', isDot ? 'One FP32 conversion at R7' : isDequant ? 'D3 is destination write' : 'Dot + below PS'], ['II', 1]]} /></header>
    {isDot ? <section className="mxm-dot-contained-architecture">
      <header><span>BF16 DOT PRODUCT · PARENT PIPELINE</span><strong>M1 → M2 → R1 → R2 → R3/R4 CSA → R5 → R6 → R7</strong></header>
      {track}
      {csa && <button className="mxm-csa-contained-card" onClick={() => open(csa)}>
        <span>R3 / R4 INTERNAL SUBSTRUCTURE</span>
        <strong>CSA Compression · 8→6→4→3→2</strong>
        <div><b>R3 · CSA L1–L2</b><b>R4 · CSA L3–L4</b><b>R5 · Carry Propagate</b></div>
        <i>点击展开 CSA 压缩树 →</i>
      </button>}
    </section> : track}
    {isDequant && <aside className="mxm-pipeline-note">D1/D2/D3 与计算时的 M1/M2/R1–R7 是两条独立流水线，页面不把它们串联。</aside>}
  </div>
}

function CsaView({ current }: { current: ArchitectureDrillNode }) {
  const labels = [
    ['P0', 'S', 'C', 'P3', 'S', 'C', 'P6', 'S'],
    ['P0', 'S', 'C', 'P3', 'S', 'C'],
    ['P0', 'S', 'C', 'P3'],
    ['P0', 'S', 'C'],
    ['P0', 'P1'],
  ]
  const levelNames = ['R2 OUT · 8 words', 'R3 · L1 · 6 words', 'R3 · L2 · 4 words', 'R4 · L3 · 3 words', 'R4 OUT · 2 words']
  const boxWidth = 82
  const boxHeight = 42
  const gap = 28
  const levelY = (level: number) => 48 + level * 132
  const levelX = (level: number, word: number) => (1040 - (labels[level].length * boxWidth + (labels[level].length - 1) * gap)) / 2 + word * (boxWidth + gap)
  const centerX = (level: number, word: number) => levelX(level, word) + boxWidth / 2
  const transitions: Array<Array<[number, number]>> = [
    [[0, 0], [1, 0], [2, 0], [0, 1], [1, 1], [2, 1], [3, 2], [4, 2], [5, 2], [3, 3], [4, 3], [5, 3], [6, 4], [7, 5]],
    [[0, 0], [1, 0], [2, 0], [0, 1], [1, 1], [2, 1], [3, 2], [4, 2], [5, 2], [3, 3], [4, 3], [5, 3]],
    [[0, 0], [1, 0], [2, 0], [0, 1], [1, 1], [2, 1], [3, 2]],
    [[0, 0], [1, 0], [2, 0], [0, 1], [1, 1], [2, 1]],
  ]
  return <div className="mxm-explorer mxm-csa-view" data-mxm-view="csa"><header className="mxm-section-head"><div><span>3:2 CARRY-SAVE REDUCTION</span><h2>{current.displayName}</h2><p>{current.description}</p></div><MetricStrip items={[["INPUT TERMS", 8], ['COMPRESSOR LEVELS', 4], ['INTERNAL', '64-bit signed'], ['FINAL', 'R5 CPA']]} /></header><div className="mxm-csa-tree-vertical"><svg viewBox="0 0 1040 780" role="img" aria-label="Vertical 3 to 2 carry-save compression tree"><defs><marker id="mxm-csa-arrow" markerUnits="userSpaceOnUse" markerWidth="7" markerHeight="7" refX="6.5" refY="3.5" orient="auto"><path d="M0,0 L7,3.5 L0,7 z" /></marker></defs>{transitions.flatMap((pairs, level) => pairs.map(([source, destination], index) => <path key={`${level}-${source}-${destination}-${index}`} className="mxm-csa-edge" d={`M ${centerX(level, source)} ${levelY(level) + boxHeight} L ${centerX(level + 1, destination)} ${levelY(level + 1)}`} markerEnd="url(#mxm-csa-arrow)" />))}{labels.map((levelLabels, level) => <g key={level}><text className="mxm-csa-level-label" x="20" y={levelY(level) + 27}>{levelNames[level]}</text>{levelLabels.map((label, word) => <g key={`${level}-${word}`}><rect className="mxm-csa-word" x={levelX(level, word)} y={levelY(level)} width={boxWidth} height={boxHeight} /><text className="mxm-csa-word-label" x={centerX(level, word)} y={levelY(level) + 27}>{label}</text></g>)}</g>)}<path className="mxm-csa-edge" d={`M ${centerX(4, 0)} ${levelY(4) + boxHeight} L 470 700`} markerEnd="url(#mxm-csa-arrow)" /><path className="mxm-csa-edge" d={`M ${centerX(4, 1)} ${levelY(4) + boxHeight} L 570 700`} markerEnd="url(#mxm-csa-arrow)" /><rect className="mxm-csa-cpa-box" x="350" y="700" width="340" height="58" /><text className="mxm-csa-cpa-label" x="520" y="724">R5 · Carry Propagate Adder</text><text className="mxm-csa-cpa-subtitle" x="520" y="746">2 carry-save words → 1 signed result</text></svg></div></div>
}

function SupercellView({ current, nodes, selectedSC, setSelectedGroup, open }: { current: ArchitectureDrillNode; nodes: Map<string, ArchitectureDrillNode>; selectedSC: [number, number]; setSelectedGroup: (index: number) => void; open: (node: ArchitectureDrillNode) => void }) {
  const groups = current.childIds.map((id) => nodes.get(id)).filter((item): item is ArchitectureDrillNode => item?.nodeType === 'mxm-group')
  const weight = child(nodes, current, 'mxm-weight-store')
  return <div className="mxm-explorer mxm-supercell-view" data-mxm-view="supercell"><header className="mxm-section-head"><div><span>SELECTED SC[{selectedSC[0]},{selectedSC[1]}]</span><h2>Single Supercell · 8 Parallel Groups</h2><p>同一 8-element BF16 Activation Vector 广播给全部 Group；权重双缓冲和每组 Dot/Partial Add 完全并行。</p></div><MetricStrip items={[["GROUPS", 8], ['WEIGHTS / GROUP', 8], ['MULTIPLIERS', 64], ['PARTIAL OUTPUTS', '8 × FP32']]} /></header>{weight && <button className="mxm-weight-store" onClick={() => open(weight)}><b>Weight Buffer 0 / 1</b>{[0, 1].map((buffer) => <span key={buffer}><strong>B{buffer}</strong>{Array.from({ length: 8 }, (_, group) => <i key={group}>G{group}</i>)}</span>)}<small>New group → G0 → G1 … → G7 → next SC Weight Forward</small></button>}<div className="mxm-activation-bus"><b>Activation Broadcast · 8 × BF16</b><span>valid · selected weight buffer · tag</span></div><div className="mxm-group-grid">{groups.map((group, index) => <button key={group.id} onClick={() => { setSelectedGroup(index); open(group) }}><span>GROUP {index}</span><b>8× BF16 MUL</b><strong>Dot M1–R7</strong><i>＋ below FP32 PS</i><small>one FP32 partial output</small></button>)}</div></div>
}

function GroupView({ current, nodes, selectedSC, selectedGroup, open }: { current: ArchitectureDrillNode; nodes: Map<string, ArchitectureDrillNode>; selectedSC: [number, number]; selectedGroup: number; open: (node: ArchitectureDrillNode) => void }) {
  const dot = child(nodes, current, 'mxm-dot-pipeline')
  const add = child(nodes, current, 'mxm-partial-add')
  return <div className="mxm-explorer mxm-group-view" data-mxm-view="group"><header className="mxm-section-head"><div><span>SC[{selectedSC[0]},{selectedSC[1]}] · GROUP {selectedGroup}</span><h2>8-way BF16 Dot + Frontend FP32 Partial Add</h2><p>八个 BF16 product 在共同指数域中压缩，R7 形成一个 FP32 Dot；随后与下方 SC 的同 Group 部分和相加。</p></div><MetricStrip items={[["BF16 PRODUCTS", 8], ['DOT STAGES', 9], ['PARTIAL ADD', 3], ['OUTPUT', '1 × FP32']]} /></header><div className="mxm-group-multipliers">{Array.from({ length: 8 }, (_, index) => <span key={index}><b>A{index}</b><i>×</i><b>W{index}</b><small>BF16</small></span>)}</div><div className="mxm-group-chain">{dot && <OpenCard node={dot} tone="activation" onOpen={() => open(dot)} />}<b>＋</b><span className="mxm-below-ps">Below SC<br />FP32 Partial Sum</span><b>→</b>{add && <OpenCard node={add} tone="partial" onOpen={() => open(add)} />}</div></div>
}

function ResultReturnView({ current }: { current: ArchitectureDrillNode }) {
  const originX = 275
  const originY = 108
  const cellWidth = 75
  const cellHeight = 74
  const stepX = 210
  const stepY = 122
  const x = (col: number) => originX + col * stepX
  const y = (row: number) => originY + (3 - row) * stepY
  const cx = (col: number) => x(col) + cellWidth / 2
  const cy = (row: number) => y(row) + cellHeight / 2
  return <div className="mxm-explorer mxm-return-view" data-mxm-view="result-return"><header className="mxm-section-head"><div><span>STATIC DIAGONAL FABRIC</span><h2>{current.displayName}</h2><p>{current.description}</p></div><MetricStrip items={[["INPUTS", '4 × 8 FP32'], ['LATENCY', '4 cycles'], ['DOWN', '3−c stages'], ['LEFT', 'c+1 stages']]} /></header><div className="mxm-return-matrix"><svg viewBox="0 0 1200 660" role="img" aria-label="Four by four static diagonal result return array"><defs><marker id="mxm-return-down-arrow" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8 z" /></marker><marker id="mxm-return-left-arrow" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8 z" /></marker></defs>{cols.map((col) => <g key={`input-${col}`}><rect className="mxm-return-input" x={cx(col) - 54} y="18" width="108" height="48" /><text className="mxm-return-input-label" x={cx(col)} y="48">TOP C{col}</text><path className={col === 3 ? 'mxm-return-direct-edge' : 'mxm-return-down-edge'} d={`M ${cx(col)} 66 L ${cx(col)} ${y(3) - 8}`} markerEnd={col === 3 ? undefined : 'url(#mxm-return-down-arrow)'} /></g>)}{cols.flatMap((col) => Array.from({ length: 3 - col }, (_, index) => { const row = 3 - index; return <path key={`down-${col}-${row}`} className="mxm-return-down-edge" d={`M ${cx(col)} ${y(row) + cellHeight + 8} L ${cx(col)} ${y(row - 1) - 8}`} markerEnd="url(#mxm-return-down-arrow)" /> }))}{cols.flatMap((sourceCol) => Array.from({ length: sourceCol }, (_, index) => { const fromCol = sourceCol - index; return <path key={`left-${sourceCol}-${fromCol}`} className="mxm-return-left-edge" d={`M ${x(fromCol) - 8} ${cy(sourceCol)} L ${x(fromCol - 1) + cellWidth + 8} ${cy(sourceCol)}`} markerEnd="url(#mxm-return-left-arrow)" /> }))}{cols.map((sourceCol) => <g key={`output-${sourceCol}`}><path className="mxm-return-left-edge" d={`M ${x(0) - 8} ${cy(sourceCol)} L 155 ${cy(sourceCol)}`} markerEnd="url(#mxm-return-left-arrow)" /><rect className="mxm-return-output" x="26" y={cy(sourceCol) - 24} width="112" height="48" /><text className="mxm-return-output-label" x="82" y={cy(sourceCol) + 6}>SL{sourceCol} OUT</text></g>)}{rowsTopDown.flatMap((row) => cols.map((col) => { const unused = row < col; const diagonal = row === col; return <g key={`cell-${row}-${col}`}><rect className={unused ? 'mxm-return-cell unused' : diagonal ? 'mxm-return-cell turn' : 'mxm-return-cell active'} x={x(col)} y={y(row)} width={cellWidth} height={cellHeight} /><text className="mxm-return-cell-label" x={cx(col)} y={y(row) + 25}>SC[{row},{col}]</text>{unused ? <text className="mxm-return-unused-label" x={cx(col)} y={y(row) + 51}>NO REGISTER</text> : <g>{row > col && <text className="mxm-return-down-label" x={x(col) + 42} y={y(row) + 53}>DOWN</text>}<text className="mxm-return-left-label" x={x(col) + (row > col ? 108 : 75)} y={y(row) + 53}>{diagonal ? 'TURN / LEFT' : 'LEFT'}</text></g>}</g> }))}<g className="mxm-return-legend"><line className="mxm-return-down-edge" x1="305" y1="620" x2="365" y2="620" /><text x="378" y="626">Down register</text><line className="mxm-return-left-edge" x1="535" y1="620" x2="595" y2="620" /><text x="608" y="626">Left register</text><line className="mxm-return-unused-edge" x1="755" y1="620" x2="815" y2="620" /><text x="828" y="626">Below diagonal · no register</text></g></svg></div><aside>实线蓝色表示 Down 寄存器，实线绿色表示 Left 寄存器；对角线以下不实例化寄存器的 SC 使用灰色虚线。每条有效路径仍满足 `(3−c) Down + (c+1) Left = 4`。</aside></div>
}

function BackendView({ current, nodes, open }: { current: ArchitectureDrillNode; nodes: Map<string, ArchitectureDrillNode>; open: (node: ArchitectureDrillNode) => void }) {
  const columns = current.childIds.map((id) => nodes.get(id)).filter((item): item is ArchitectureDrillNode => item?.nodeType === 'mxm-backend-column')
  return <div className="mxm-explorer mxm-backend-view" data-mxm-view="backend"><header className="mxm-section-head"><div><span>INDEPENDENT COLUMN ACCUMULATORS</span><h2>{current.displayName}</h2><p>{current.description}</p></div><MetricStrip items={[["COLUMNS", 4], ['FP32 ADDERS', 32], ['LOGICAL BANKS', 8], ['TOTAL', '128 KiB']]} /></header><div className="mxm-backend-columns">{columns.map((column, index) => <button key={column.id} onClick={() => open(column)}><span>RETURN SL{index}</span><b>8 × FP32 A1–A3</b><div><i>Bank 0<br />512×256</i><i>Bank 1<br />512×256</i></div><strong>FP32 / BF16 Output</strong></button>)}</div><aside>Logical 1RW storage contract only；页面不会把它伪装成已经完成 SRAM Macro 映射。</aside></div>
}

function BackendColumnView({ current, onSelectNode }: { current: ArchitectureDrillNode; onSelectNode: (id: string) => void }) {
  const column = Number(current.id.split(':').at(-1) ?? 0)
  return <div className="mxm-explorer mxm-backend-column-view" data-mxm-view="backend-column"><header className="mxm-section-head"><div><span>BACKEND COLUMN {column} · INDEPENDENT SCHEDULER</span><h2>{current.displayName}</h2><p>{current.description}</p></div><MetricStrip items={[["RETURN INPUT", `SL${column}`], ['FP32 ADDERS', 8], ['ADD STAGES', 'A1–A3'], ['STORAGE', '2 × 512×256']]} /></header><div className="mxm-backend-column-flow"><section className="mxm-column-return"><span>RESULT RETURN</span><b>SL{column} · 8 × FP32</b><small>valid + tag + vector</small></section><b className="mxm-column-arrow">→</b><section className="mxm-column-adders"><span>8 PARALLEL LANES</span><div>{Array.from({ length: 8 }, (_, lane) => <i key={lane}>Lane {lane}<b>A1 → A2 → A3</b></i>)}</div></section><b className="mxm-column-arrow">→</b><section className="mxm-column-banks"><span>ADDRESS BIT 0 SELECT</span><div><i>Bank 0<b>512 × 256 bit</b><small>logical 1RW</small></i><i>Bank 1<b>512 × 256 bit</b><small>logical 1RW</small></i></div></section><b className="mxm-column-arrow">→</b><section className="mxm-column-output"><span>SHARED OUTPUT PIPE</span><b>FP32 / BF16</b><small>read · accumulate · writeback · output</small></section></div><aside>该列独立完成 256-bit 批量累加；两个逻辑 Bank 由地址 bit 0 交替选择，页面不把逻辑存储声明为已完成的 SRAM Macro。</aside><button className="mxm-inspector" onClick={() => onSelectNode(current.id)}>查看本列 RTL 位置与参数证据</button></div>
}

function GenericNode({ current, onSelectNode }: { current: ArchitectureDrillNode; onSelectNode: (id: string) => void }) {
  return <div className="mxm-explorer"><header className="mxm-section-head"><div><span>{current.nodeType.replaceAll('-', ' ').toUpperCase()}</span><h2>{current.displayName}</h2><p>{current.description}</p></div></header><MetricStrip items={current.parameterRefs.map((item) => [item.name, String(item.value ?? item.expression)])} /><button className="mxm-inspector" onClick={() => onSelectNode(current.id)}>查看 RTL 位置与参数证据</button></div>
}

export default function MxmFunctionalExplorer({ block, current, nodes, onNavigate, onSelectNode }: Props) {
  const [activeFlow, setActiveFlow] = useState<FlowKind>('partial')
  const [selectedSC, setSelectedSC] = useState<[number, number]>([0, 0])
  const [selectedGroup, setSelectedGroup] = useState(0)
  const open = (node: ArchitectureDrillNode) => node.childIds.length || ['mxm-csa', 'mxm-result-return', 'mxm-backend-column'].includes(node.nodeType) ? onNavigate(node.id) : onSelectNode(node.id)
  const arrayNode = useMemo(() => [...nodes.values()].find((item) => item.blockId === current.blockId && item.nodeType === 'mxm-supercell-array'), [current.blockId, nodes])
  const selectSC = (row: number, col: number, node: ArchitectureDrillNode) => { setSelectedSC([row, col]); onNavigate(node.id) }

  if (!current.parentId) return <MxmRoot block={block} current={current} nodes={nodes} open={open} />
  if (current.nodeType === 'mxm-five-stream-icu') return <FiveStreamIcuView current={current} nodes={nodes} open={open} />
  if (current.nodeType === 'mxm-shared-decoder') return <MxmDecoderView current={current} />
  if (current.nodeType === 'mxm-core') return <CoreOverview current={current} nodes={nodes} open={open} />
  if (current.nodeType === 'mxm-frontend') return <FrontendOverview current={current} nodes={nodes} open={open} activeFlow={activeFlow} setActiveFlow={setActiveFlow} selectSC={selectSC} />
  if (current.nodeType === 'mxm-supercell-array') return <div className="mxm-explorer"><MxmLegend active={activeFlow} onChange={setActiveFlow} /><SupercellArray current={current} nodes={nodes} activeFlow={activeFlow} selectSC={selectSC} /></div>
  if (current.nodeType === 'mxm-control-wave') return <InstructionWave current={current} />
  if (current.nodeType === 'mxm-ingress') return <IngressView current={current} nodes={nodes} open={open} />
  if (['mxm-dequant-pipeline', 'mxm-dot-pipeline', 'mxm-partial-add'].includes(current.nodeType)) return <PipelineView current={current} nodes={nodes} open={open} />
  if (current.nodeType === 'mxm-csa') return <CsaView current={current} />
  if (current.nodeType === 'mxm-supercell') return <SupercellView current={current} nodes={nodes} selectedSC={selectedSC} setSelectedGroup={setSelectedGroup} open={open} />
  if (current.nodeType === 'mxm-group') return <GroupView current={current} nodes={nodes} selectedSC={selectedSC} selectedGroup={selectedGroup} open={open} />
  if (current.nodeType === 'mxm-result-return') return <ResultReturnView current={current} />
  if (current.nodeType === 'mxm-backend') return <BackendView current={current} nodes={nodes} open={open} />
  if (current.nodeType === 'mxm-backend-column') return <BackendColumnView current={current} onSelectNode={onSelectNode} />
  if (arrayNode && current.nodeType === 'mxm-weight-store') return <SupercellView current={nodes.get(current.parentId ?? '') ?? current} nodes={nodes} selectedSC={selectedSC} setSelectedGroup={setSelectedGroup} open={open} />
  return <GenericNode current={current} onSelectNode={onSelectNode} />
}
