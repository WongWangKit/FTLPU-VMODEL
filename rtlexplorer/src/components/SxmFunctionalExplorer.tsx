import { useMemo, useState } from 'react'
import AnimationControls, { useAnimationClock } from './AnimationControls'
import type { ArchitectureDrillNode, PhysicalFunctionalBlock } from '../types'

interface Props {
  block: PhysicalFunctionalBlock
  current: ArchitectureDrillNode
  onSelectNode: (id: string) => void
}

type SxmView = 'native' | 'matrix' | 'vector' | 'triangle'
const indices = Array.from({ length: 8 }, (_, index) => index)
const identityLaneMap = [...indices]
const mixedLaneMap = [3, 0, 7, 2, 5, 1, 6, 4]
const tileMaps = { Identity: [0, 1, 2, 3], Rotate: [1, 2, 3, 0] }

function valueLabel(row: number, col: number) { return `X${row}${col}` }

function Controls({ clock, label }: { clock: ReturnType<typeof useAnimationClock>; label: string }) {
  return <AnimationControls step={clock.step} maxStep={clock.maxStep} playing={clock.playing} speed={clock.speed} cycleLabel={label} onPlayingChange={clock.setPlaying} onSpeedChange={clock.setSpeed} onStepChange={clock.move} onReset={clock.reset} />
}

function NativeProgramView() {
  const clock = useAnimationClock(40)
  const cycle = clock.step
  const events = [
    { at: 0, table: 'CTRL', label: '配置开始' },
    { at: 5, table: 'CTRL', label: '配置完成' },
    { at: 24, table: 'EXEC', label: 'CAP' },
    { at: 25, table: 'EXEC', label: 'P' },
    { at: 28, table: 'EXEC', label: 'RUN' },
    { at: 29, table: 'STREAM', label: '首个输出' },
  ]
  const phase = cycle < 24 ? 'CTRL 配置 / 等待 EXEC' : cycle === 24 ? 'CAP · 读取当前 SRF' : cycle === 25 ? 'P · 单级流水' : cycle < 28 ? '等待 RUN 目标周期' : cycle === 28 ? 'RUN · 启动输出' : cycle >= 29 ? '输出阶段' : '等待'
  return <section className="sxm-lab-view sxm-native-view" data-sxm-view="native-program">
    <header className="sxm-view-heading"><div><span>FORMAL PROGRAM PATH · EAST / WEST EACH</span><h3>R6 → CTRL / EXEC Calendar → ROW Core</h3></div><dl><div><dt>SUBSYSTEMS</dt><dd>2</dd></div><div><dt>CALENDARS</dt><dd>4 × 64</dd></div><div><dt>SLOTS</dt><dd>10 / hemisphere</dd></div></dl></header>
    <Controls clock={clock} label={`C${cycle} · ${phase}`} />
    <div className="sxm-native-flow">
      <article><strong>R6 Outer Local</strong><span>13-bit destination · index 0</span><small>Target 5 CTRL / Target 6 EXEC</small></article>
      <article className={cycle <= 5 ? 'active' : ''}><strong>CTRL Calendar</strong><span>64 events · payload + timing word</span><small>absolute cycle issue</small></article>
      <article className={cycle >= 24 && cycle <= 28 ? 'active' : ''}><strong>EXEC Calendar</strong><span>64 events · CAP / P / RUN</span><small>CTRL and EXEC may coincide</small></article>
      <article className={cycle >= 24 ? 'active' : ''}><strong>ROW Core</strong><span>4 sources · 1+2+3+4 slots</span><small>each slot 8×8×32-bit</small></article>
      <article className={cycle >= 29 ? 'active' : ''}><strong>Stream Boundary</strong><span>MEM ↔ SXM ↔ MXM</span><small>unconsumed pass-through: +1 registered cycle</small></article>
    </div>
    <div className="sxm-native-timeline" aria-label="Vector regression example timeline">{events.map((event) => <div key={`${event.table}-${event.at}`} className={cycle === event.at ? 'active' : cycle > event.at ? 'complete' : ''}><b>C{event.at}</b><strong>{event.label}</strong><span>{event.table}</span></div>)}</div>
    <aside className="sxm-cycle-note"><b>这条时间线是 VCS 向量场景的实例：</b>CTRL C0–C5、CAP C24、P C25、RUN C28、首输出 C29。矩阵场景 CAP C24–C31、RUN C35、每 6 拍输出至 C78。正式路径已接入；SXM QCTL 尚未接入，CMODEL main 未实现 native ROW Program，旧跨 FU 静态 Schedule 需单独回归。</aside>
  </section>
}

function MatrixTransposeView() {
  const clock = useAnimationClock(18)
  const [lanePreset, setLanePreset] = useState<'Identity' | 'Mixed'>('Identity')
  const [tilePreset, setTilePreset] = useState<keyof typeof tileMaps>('Identity')
  const [traceRow, setTraceRow] = useState(2)
  const [traceCol, setTraceCol] = useState(5)
  const laneMap = lanePreset === 'Identity' ? identityLaneMap : mixedLaneMap
  const tileMap = tileMaps[tilePreset]
  const capturedRows = Math.min(8, clock.step)
  const outputColumns = Math.max(0, Math.min(8, clock.step - 10))
  const traceLane = laneMap.indexOf(traceRow)
  const phase = clock.step === 0 ? '等待首行' : clock.step <= 8 ? `ROW ${clock.step - 1} capture` : clock.step === 9 ? 'slot complete' : clock.step === 10 ? '等待 BLOCK8 输出相位' : `BLOCK8 q=${clock.step - 11}`
  const changePreset = (kind: 'lane' | 'tile', value: string) => {
    clock.reset()
    if (kind === 'lane') setLanePreset(value as 'Identity' | 'Mixed')
    else setTilePreset(value as keyof typeof tileMaps)
  }

  return <section className="sxm-lab-view" data-sxm-view="matrix-transpose">
    <header className="sxm-view-heading"><div><span>MATRIX_TP · MODE 0</span><h3>8×8 ROW → BLOCK8 转置数据通路</h3></div><dl><div><dt>CAPTURE</dt><dd>8 rows</dd></div><div><dt>OUTPUT</dt><dd>8 × 256 bit</dd></div><div><dt>DEST TILE</dt><dd>{tileMap[0]}</dd></div></dl></header>
    <Controls clock={{ ...clock, maxStep: 18 }} label={phase} />
    <div className="sxm-config-row">
      <label>LaneMap <select name="sxm-matrix-lane-map" value={lanePreset} onChange={(event) => changePreset('lane', event.target.value)}><option>Identity</option><option>Mixed</option></select></label>
      <label>TileMap <select name="sxm-matrix-tile-map" value={tilePreset} onChange={(event) => changePreset('tile', event.target.value)}><option>Identity</option><option>Rotate</option></select></label>
      <label>追踪输入 X[<select name="sxm-matrix-trace-row" value={traceRow} onChange={(event) => { clock.reset(); setTraceRow(Number(event.target.value)) }}>{indices.map((index) => <option key={index}>{index}</option>)}</select>,<select name="sxm-matrix-trace-column" aria-label="追踪输入列" value={traceCol} onChange={(event) => { clock.reset(); setTraceCol(Number(event.target.value)) }}>{indices.map((index) => <option key={index}>{index}</option>)}</select>]</label>
    </div>
    <div className="sxm-matrix-stage">
      <div className="sxm-matrix-panel"><header><b>ROW INPUT</b><small>逐行进入 data_q[slot][row][lane]</small></header><div className="sxm-matrix-grid">{indices.flatMap((row) => indices.map((col) => <span key={`${row}-${col}`} className={`${row < capturedRows ? 'filled' : ''} ${row === capturedRows - 1 ? 'capturing' : ''} ${row === traceRow && col === traceCol ? 'traced' : ''}`}>{row < capturedRows ? valueLabel(row, col) : '·'}</span>))}</div></div>
      <div className="sxm-mapping-bridge"><b>{valueLabel(traceRow, traceCol)}</b><i>→</i><strong>Y[{traceCol},{traceLane}]</strong><small>g = LaneMap[dest][l]</small><small>Y[q,l] = X[g,q]</small></div>
      <div className="sxm-matrix-panel output"><header><b>BLOCK8 OUTPUT</b><small>q 为输出 word；l 为目标 lane</small></header><div className="sxm-matrix-grid">{indices.flatMap((q) => indices.map((lane) => {
        const visible = q < outputColumns
        const sourceRow = laneMap[lane]
        return <span key={`${q}-${lane}`} className={`${visible ? 'filled' : ''} ${q === outputColumns - 1 ? 'outputting' : ''} ${q === traceCol && lane === traceLane ? 'traced' : ''}`}>{visible ? valueLabel(sourceRow, q) : '·'}</span>
      }))}</div></div>
    </div>
    <div className="sxm-map-summary"><span><b>LaneMap</b>{laneMap.map((source, lane) => <i key={lane}>l{lane}←r{source}</i>)}</span><span><b>TileMap</b>{tileMap.map((dest, source) => <i key={source}>a{source}→T{dest}</i>)}</span></div>
    <aside className="sxm-cycle-note"><b>当前追踪：</b>{valueLabel(traceRow, traceCol)} 经 LaneMap 到 BLOCK8 的 Y[{traceCol},{traceLane}]。LaneMap 改变块内 lane，TileMap 独立决定 a→目标 Tile；两者没有合并成同一个映射。</aside>
  </section>
}

const vectorPresets: Record<string, number[]> = {
  Identity: [0, 1, 2, 3, 4, 5, 6, 7],
  Reverse: [7, 6, 5, 4, 3, 2, 1, 0],
  Rotate: [1, 2, 3, 4, 5, 6, 7, 0],
  Mixed: [3, 0, 7, 2, 5, 1, 6, 4],
  Repeated: [0, 0, 2, 5, 5, 7, 1, 3],
}

function VectorPermuteView() {
  const clock = useAnimationClock(8)
  const [mapping, setMapping] = useState(vectorPresets.Identity)
  const [preset, setPreset] = useState('Identity')
  const applyPreset = (name: string) => { setPreset(name); setMapping([...vectorPresets[name]]); clock.reset() }
  const setLane = (lane: number, source: number) => { setPreset('Manual'); setMapping((value) => value.map((item, index) => index === lane ? source : item)); clock.reset() }
  const activeLane = clock.step - 1
  return <section className="sxm-lab-view" data-sxm-view="vector-permute">
    <header className="sxm-view-heading"><div><span>VECTOR_PERMUTE · MODE 1 · CORE CAPABILITY</span><h3>8-Lane ROW → ROW 可编程重排</h3></div><dl><div><dt>INPUT</dt><dd>8 lanes</dd></div><div><dt>OUTPUT</dt><dd>8 lanes</dd></div><div><dt>PRESET</dt><dd>{preset}</dd></div></dl></header>
    <Controls clock={{ ...clock, maxStep: 8 }} label={clock.step === 0 ? '等待映射' : `输出 lane ${activeLane}`} />
    <div className="sxm-preset-row">{Object.keys(vectorPresets).map((name) => <button key={name} className={preset === name ? 'active' : ''} onClick={() => applyPreset(name)}>{name}</button>)}</div>
    <div className="sxm-vector-map">
      <svg viewBox="0 0 880 300" role="img" aria-label="8 lane programmable vector permutation">
        <defs><marker id="sxm-vector-arrow" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8 z" /></marker></defs>
        {indices.map((lane) => {
          const x = 65 + lane * 108
          return <g key={`input-${lane}`}><rect x={x - 34} y={18} width="68" height="48" className="sxm-vector-node input" /><text x={x} y={48}>x{lane}</text></g>
        })}
        {indices.map((lane) => {
          const source = mapping[lane]
          const sourceX = 65 + source * 108
          const destinationX = 65 + lane * 108
          const completed = lane < clock.step
          const active = lane === activeLane
          return <path key={`edge-${lane}`} d={`M ${sourceX} 66 C ${sourceX} 132, ${destinationX} 166, ${destinationX} 232`} className={`${completed ? 'complete' : ''} ${active ? 'active' : ''}`} markerEnd="url(#sxm-vector-arrow)" />
        })}
        {indices.map((lane) => {
          const x = 65 + lane * 108
          const shown = lane < clock.step
          return <g key={`output-${lane}`}><rect x={x - 34} y={232} width="68" height="48" className={`sxm-vector-node output ${shown ? 'filled' : ''}`} /><text x={x} y={262}>{shown ? `x${mapping[lane]}` : `y${lane}`}</text></g>
        })}
      </svg>
      <div className="sxm-vector-selectors">{indices.map((lane) => <label key={lane}>y{lane} ← x<select name={`sxm-vector-lane-${lane}`} value={mapping[lane]} onChange={(event) => setLane(lane, Number(event.target.value))}>{indices.map((source) => <option key={source}>{source}</option>)}</select></label>)}</div>
    </div>
    <aside className="sxm-boundary-warning"><b>视图范围</b><span>本页用可调 LaneMap 演示 core 级 8-lane ROW 重排；正式 Program 路径通过 target 5/6 的 CTRL/EXEC 事件表发射 native ROW 操作。旧 batch WriteTap wrapper 的固定模式不决定正式 native 路径。</span></aside>
  </section>
}

function TriangleBufferView() {
  const loopStart = 33
  const loopEnd = 64
  const clock = useAnimationClock(loopEnd, 0, loopStart)
  const [ready, setReady] = useState(true)
  const sources = [0, 1, 2, 3]
  const slots = sources.flatMap((source) => Array.from({ length: source + 1 }, (_, local) => ({ source, local })))
  const blockCount = Math.ceil((loopEnd + 8) / 8)
  const blocks = sources.flatMap((source) => Array.from({ length: blockCount }, (_, a) => ({
    source,
    a,
    local: a % (source + 1),
    start: 8 * a + source,
    end: 8 * a + source + 7,
    due: 8 * (a + source) + 8,
  })))
  const slotState = (source: number, local: number) => {
    const slotBlocks = blocks.filter((block) => block.source === source && block.local === local)
    const candidates = slotBlocks.filter((block) => block.start <= clock.step)
    const block = candidates[candidates.length - 1]
    const dueBlock = slotBlocks.find((candidate) => candidate.due === clock.step)
    const nextBlock = slotBlocks.find((candidate) => candidate.start > clock.step)
    if (!block) return { block: undefined, dueBlock, nextBlock, captured: 0, status: 'empty' }
    const captured = Math.min(8, Math.max(0, clock.step - block.start + 1))
    const sourceFault = !ready && blocks.some((candidate) => candidate.source === source && candidate.due <= clock.step)
    const output = ready && dueBlock !== undefined
    const retired = ready && clock.step > block.due
    const complete = captured === 8 && clock.step < block.due
    const occupied = captured > 0 && !retired
    const status = sourceFault && block.due <= clock.step ? 'fault' : output ? 'output' : retired ? 'retired' : complete ? 'complete' : occupied ? 'occupied' : 'empty'
    return { block, dueBlock, nextBlock, captured, status }
  }
  const sourceState = (source: number) => {
    const depth = source + 1
    const slotStates = Array.from({ length: depth }, (_, local) => slotState(source, local))
    const completedCaptures = blocks.filter((block) => block.source === source && block.end <= clock.step).length
    const completedTakes = ready ? blocks.filter((block) => block.source === source && block.due < clock.step).length : 0
    const fault = !ready && blocks.some((block) => block.source === source && block.due <= clock.step)
    const output = slotStates.some((state) => state.status === 'output')
    const occupiedBits = slotStates.map((state) => state.status !== 'empty' && state.status !== 'retired' ? '1' : '0').join('')
    const completeBits = slotStates.map((state) => ['complete', 'output', 'fault'].includes(state.status) ? '1' : '0').join('')
    return { depth, slotStates, fault, output, wr: completedCaptures % depth, rd: completedTakes % depth, occupiedBits, completeBits }
  }
  const activeCaps = blocks.filter((block) => clock.step >= block.start && clock.step <= block.end)
  const activeDue = blocks.filter((block) => clock.step === block.due)
  const eventLabel = activeDue.length
    ? `${activeDue.map((block) => `S${block.source}:a${block.a}`).join(' · ')} ${ready ? 'BLOCK8 take' : 'due 但 ready=0 → fault'}`
    : activeCaps.length
      ? `${activeCaps.map((block) => `S${block.source}:a${block.a}:r${clock.step - block.start}`).join(' · ')} capture`
      : '等待已完成 slot 的固定输出相位'
  return <section className="sxm-lab-view" data-sxm-view="triangle-buffer">
    <header className="sxm-view-heading"><div><span>TRIANGLE BUFFER · T=4</span><h3>1 + 2 + 3 + 4 = 10 Slot 生命周期</h3></div><dl><div><dt>DEPTHS</dt><dd>1 / 2 / 3 / 4</dd></div><div><dt>Δs</dt><dd>0 / 7 / 14 / 21</dd></div><div><dt>SLOTS</dt><dd>10</dd></div></dl></header>
    <Controls clock={{ ...clock, maxStep: loopEnd }} label={eventLabel} />
    <div className="sxm-triangle-toolbar"><label><input type="checkbox" name="sxm-block-ready" checked={ready} onChange={(event) => { setReady(event.target.checked); clock.reset() }} /> block_ready_i = {ready ? '1' : '0'}</label><span><b>Design view</b> C{clock.step}：首个 CAP 为 C0</span><span><b>Wrapper view</b> C{clock.step + 1}：job accept 为 C0，首个 CAP 为 C1</span><span><b>循环</b> C0–C32 填充；C33–C64 稳态复用（RTL 实际由 count_i 结束）</span></div>
    <div className="sxm-slot-color-legend" aria-label="slot 生命周期颜色"><span className="capture"><i />CAPTURE · 装填</span><span className="wait"><i />WAIT · 完成后等待</span><span className="execute"><i />FIRE / TAKE · 输出执行</span><span className="retire"><i />RETIRED / FREE · 已释放</span></div>
    <table className="sxm-slot-cycle-table">
      <caption>单个 slot 生命周期（block_ready=1；周期数按上升沿之间的跨度计算）</caption>
      <thead><tr><th>Source</th><th>occupied_q 跨度</th><th>ROW7 → FIRE</th><th>FIRE / TAKE</th><th>同一 slot 再次 CAP</th></tr></thead>
      <tbody>{sources.map((source) => <tr key={`timing-${source}`}><th>S{source}</th><td>{8 + 7 * source} cycles</td><td>{1 + 7 * source} cycles</td><td>1 cycle</td><td>{source === 0 ? '同拍复用' : `${source} cycles 后`}</td></tr>)}</tbody>
      <tfoot><tr><td colSpan={5}>8 个 CAP 周期固定不变；纯等待为 7×s；take 当拍即清除 occupied/complete，没有额外 retire 周期。</td></tr></tfoot>
    </table>
    <div className="sxm-triangle-layout">
      <div className="sxm-slot-triangle">{sources.map((source) => <div className={`sxm-slot-row source-${source}`} key={source}><header><b>S{source}</b><small>D={source + 1} · Δ={7 * source}</small></header>{slots.filter((slot) => slot.source === source).map((slot) => {
        const state = slotState(source, slot.local)
        const reusedOnOutput = state.status === 'output' && state.dueBlock && state.dueBlock.a !== state.block?.a
        const visualRows = reusedOnOutput ? 8 : state.captured
        const cyclesToDue = state.block ? Math.max(0, state.block.due - clock.step) : 0
        const cyclesToNext = state.nextBlock ? state.nextBlock.start - clock.step : 0
        const statusLabel = !state.block
          ? state.nextBlock ? `FREE · next a${state.nextBlock.a} C${state.nextBlock.start}` : 'FREE'
          : reusedOnOutput
            ? `a${state.dueBlock?.a} FIRE/TAKE · a${state.block.a} CAP ${state.captured}/8`
            : state.status === 'occupied'
              ? `a${state.block.a} · CAP ${state.captured}/8 · due C${state.block.due}`
              : state.status === 'complete'
                ? `a${state.block.a} · WAIT ${cyclesToDue} cyc · fire C${state.block.due}`
                : state.status === 'output'
                  ? `a${state.block.a} · FIRE/TAKE · 1 cyc`
                  : state.status === 'retired'
                    ? state.nextBlock ? `RETIRED/FREE · next a${state.nextBlock.a} in ${cyclesToNext} cyc` : 'RETIRED/FREE'
                    : state.status === 'fault' ? `FAULT · due C${state.block.due}` : 'FREE'
        return <div className={`sxm-triangle-slot ${state.status}`} key={`${source}-${slot.local}`}><span>slot {slot.local}</span><div className="sxm-mini-matrix">{indices.flatMap((row) => indices.map((col) => <i className={state.block && row < visualRows ? 'filled' : ''} key={`${row}-${col}`} />))}</div><small>{statusLabel}</small></div>
      })}</div>)}</div>
      <div className="sxm-source-registers">
        <div className="sxm-slot-status-map" aria-label={`C${clock.step} 当前 slot 状态`}>
          <header><b>C{clock.step} · CURRENT SLOT STATE</b><small>位置与左侧 Triangle Buffer 一一对应</small></header>
          <div>{sources.map((source) => <div className="sxm-slot-status-row" key={`status-row-${source}`}><strong>S{source}</strong>{slots.filter((slot) => slot.source === source).map((slot) => {
            const state = slotState(source, slot.local)
            const shortState = state.status === 'occupied' ? 'CAP' : state.status === 'complete' ? 'WAIT' : state.status === 'output' ? 'TAKE' : state.status === 'retired' ? 'FREE' : state.status === 'fault' ? 'FAULT' : 'FREE'
            const colorState = state.status === 'empty' ? 'retired' : state.status
            return <span className={`sxm-slot-status-cell ${colorState}`} key={`status-${source}-${slot.local}`} title={`S${source} slot${slot.local}: ${shortState}`}><i>slot {slot.local}</i><b>{shortState}</b></span>
          })}</div>)}</div>
        </div>
        {sources.map((source) => {
        const state = sourceState(source)
        const outputBlocks = activeDue.filter((block) => block.source === source)
        return <section className={state.fault ? 'fault' : state.output ? 'output' : ''} key={source}><header><b>Source S{source}</b><span>Δ={7 * source}</span></header><div><span>wr_q <b>{state.wr}</b></span><span>rd_q <b>{state.rd}</b></span><span>occupied <b>{state.occupiedBits}</b></span><span>complete <b>{state.completeBits}</b></span></div><footer>{outputBlocks.length ? `C${clock.step} · a${outputBlocks[0].a} output` : `${state.depth}-slot ring · steady reuse`} · bit order slot0→slot{state.depth - 1}</footer></section>
      })}</div>
    </div>
    <div className="sxm-timing-formulas"><span><b>CAP(m,a,s,r)</b> = mP + 8a + r + s</span><span><b>P_BLOCK(m,a,s)</b> = mP + 8(a+s) + 8</span><span><b>D_s</b> = s + 1</span></div>
    <aside className={ready ? 'sxm-cycle-note' : 'sxm-boundary-warning'}><b>{ready ? 'ready 行为：' : 'fault 行为：'}</b>{ready ? '到期且 ready=1 时 take，rd_q 前进并释放 slot；ROW0 还允许在同拍 take 时复用同一 slot。' : 'RTL 不是无限等待模型：fire 到期但 take 失败会置 bad_q/source_fault，故动画以红色 sticky fault 表示。'}</aside>
  </section>
}

export default function SxmFunctionalExplorer({ block, current, onSelectNode }: Props) {
  const [view, setView] = useState<SxmView>('native')
  const subtitle = useMemo(() => block.displayName || current.displayName, [block.displayName, current.displayName])
  return <div className="sxm-explorer" data-sxm-root={current.id}>
    <header className="sxm-hero"><div><span>LOCAL RTL · CURRENT WORKSPACE</span><h2>{subtitle} · Native ROW Subsystem</h2><p>正式 FU Cluster 在 East / West 各实例化一个 native SXM。R6 Program Target 5/6 分别装载 CTRL/EXEC 事件表，按绝对周期发射 ROW CAP/P/RUN。旧 typed batch WriteTap 和 raw416 兼容路径独立于此。</p></div><div className="sxm-status-stack"><b>PROGRAM / ROW INTEGRATED</b><span>VCS · 5 scenarios</span><i>2787 checks · PASS</i></div></header>
    <nav className="sxm-tabs" aria-label="SXM 数据通路视图"><button className={view === 'native' ? 'active' : ''} onClick={() => setView('native')}>NATIVE PROGRAM / ROW</button><button className={view === 'matrix' ? 'active' : ''} onClick={() => setView('matrix')}>MATRIX CORE DEMO</button><button className={view === 'vector' ? 'active' : ''} onClick={() => setView('vector')}>VECTOR CORE DEMO</button><button className={view === 'triangle' ? 'active' : ''} onClick={() => setView('triangle')}>BATCH BUFFER DEMO</button></nav>
    {view === 'native' ? <NativeProgramView /> : view === 'matrix' ? <MatrixTransposeView /> : view === 'vector' ? <VectorPermuteView /> : <TriangleBufferView />}
    <section className="sxm-evidence-panel"><header><span>RTL EVIDENCE</span><h3>正式 Program 路径与独立兼容路径</h3></header><div><article><b>lpu_sxm_native_subsystem.sv</b><span>CTRL / EXEC 两张 64-event Calendar + ROW Core + Stream Boundary</span><span>FU Cluster 每半区一个正式实例</span></article><article><b>lpu_sxm_subsystem.sv</b><span>独立 typed batch WriteTap 路径</span><span>不是正式 Program Endpoint</span></article><article><b>raw416 compatibility</b><span>保留于 sxm_triangle_full_core</span><span>正式 native Program 路径将其输入置零</span></article><article><b>验证边界</b><span>VCS 五场景 2787 checks PASS</span><span>CMODEL main 尚无 native ROW Program；SXM QCTL 尚未接入</span></article></div><button onClick={() => onSelectNode(current.id)}>查看当前 SXM 节点 Inspector</button></section>
  </div>
}
