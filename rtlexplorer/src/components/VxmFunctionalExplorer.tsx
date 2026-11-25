import { useEffect, useMemo, useState } from 'react'
import AnimationControls, { useAnimationClock } from './AnimationControls'
import type { ArchitectureDrillNode, PhysicalFunctionalBlock } from '../types'

interface Props {
  block: PhysicalFunctionalBlock
  current: ArchitectureDrillNode
  nodes: Map<string, ArchitectureDrillNode>
  onNavigate: (id: string) => void
  onSelectNode: (id: string) => void
}

type VxmView = 'overview' | 'control' | 'tile' | 'lane' | 'stream' | 'alu' | 'lut' | 'bridge'
type Direction = 'ltr' | 'rtl'
type DataFormat = 'FP16' | 'BF16' | 'FP32'

const viewLabels: Array<[VxmView, string]> = [
  ['overview', 'SLICE OVERVIEW'],
  ['control', 'CONTROL WAVE'],
  ['tile', '16×8 TILE'],
  ['lane', 'LANE / CHAIN'],
  ['stream', 'STREAM FORMAT'],
  ['alu', 'ALU'],
  ['lut', 'LUT SRAM'],
  ['bridge', 'STREAM BRIDGE'],
]
const queueWidths = [6, 5, 7, 6, 7, 5, 7, 6]
const lanes = Array.from({ length: 8 }, (_, index) => index)
const stages = Array.from({ length: 16 }, (_, index) => index)
const tiles = Array.from({ length: 4 }, (_, index) => index)
const streams = Array.from({ length: 32 }, (_, index) => index)
const lutFunctions = [
  { id: 0, name: 'Exp', width: 26, row: '13-bit k + 13-bit b', stages: 'Stage 1 / 5 / 9 / 13' },
  { id: 1, name: 'Reciprocal', width: 32, row: '16-bit k + 16-bit b', stages: 'Stage 3 / 7 / 11 / 15' },
  { id: 2, name: 'Rsqrt', width: 32, row: '16-bit k + 16-bit b', stages: 'Stage 3 / 7 / 11 / 15' },
  { id: 3, name: 'Log', width: 50, row: '28-bit Base + 22-bit Inverse', stages: 'Stage 3 / 7 / 11 / 15' },
]

function viewForNode(node: ArchitectureDrillNode): VxmView {
  if (/(control|instruction)/.test(node.nodeType) || /:issue/.test(node.id)) return 'control'
  if (/stream-routing/.test(node.nodeType)) return 'bridge'
  if (/stream-interface/.test(node.nodeType)) return 'stream'
  if (/(lookup|lut-function)/.test(node.nodeType)) return 'lut'
  if (/execution-stage/.test(node.nodeType)) return 'lane'
  if (/(tile-array|vector-tile)/.test(node.nodeType)) return 'tile'
  return 'overview'
}

function findNode(nodes: Map<string, ArchitectureDrillNode>, blockId: string, suffix: string) {
  return [...nodes.values()].find((node) => node.blockId === blockId && node.id.endsWith(suffix))
}

function VxmMetrics({ items }: { items: Array<[string, string | number]> }) {
  return <dl className="vxm-metrics">{items.map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}</dl>
}

function Controls({ clock, label }: { clock: ReturnType<typeof useAnimationClock>; label: string }) {
  return <AnimationControls step={clock.step} maxStep={clock.maxStep} playing={clock.playing} speed={clock.speed} cycleLabel={label} onPlayingChange={clock.setPlaying} onSpeedChange={clock.setSpeed} onStepChange={clock.move} onReset={clock.reset} />
}

function StreamCells({ active, direction }: { active: number; direction: Direction }) {
  return <div className={`vxm-stream-cells direction-${direction}`}>{streams.map((stream) => <i key={stream} className={stream === active ? 'active' : ''} title={`Stream ${stream} · 64 bit = 8 lanes × 8 bit`}><b>{stream}</b><span>{lanes.map((lane) => <em key={lane} />)}</span></i>)}</div>
}

function OverviewView({ open }: { open: (suffix: string) => void }) {
  const [direction, setDirection] = useState<Direction>('ltr')
  const clock = useAnimationClock(7, 0, 0)
  const activeStream = clock.step % 32
  const input = direction === 'ltr' ? 'WEST' : 'EAST'
  const output = direction === 'ltr' ? 'EAST' : 'WEST'
  return <section className="vxm-overview" data-vxm-view="slice-overview">
    <header className="vxm-view-heading"><div><span>L1 · ONE INTEGRATED VXM SLICE</span><h3>Two Hemisphere Boundaries · Four Superlanes</h3><p>全局 flow_direction 同时控制四个 Tile；一个 VXM Slice 位于 West / East Stream 边界之间，不是四个独立 VXM。</p></div><VxmMetrics items={[["HEMISPHERES", 2], ['TILES', 4], ['LANES', 32], ['ALU POSITIONS', 512]]} /></header>
    <div className="vxm-direction-toolbar"><button className={direction === 'ltr' ? 'active' : ''} onClick={() => { setDirection('ltr'); clock.reset() }}>WEST → EAST</button><button className={direction === 'rtl' ? 'active' : ''} onClick={() => { setDirection('rtl'); clock.reset() }}>EAST → WEST</button><strong>GLOBAL CONFIG · flow_direction={direction === 'ltr' ? 0 : 1}</strong></div>
    <Controls clock={clock} label={`${input} → ${output} · Stream ${activeStream}`} />
    <div className={`vxm-slice-map direction-${direction}`}>
      <section className={`vxm-boundary west ${input === 'WEST' ? 'active input' : 'output'}`}><header><b>WEST HEMISPHERE</b><span>{input === 'WEST' ? 'SELECTED INPUT' : 'RESULT / PASS OUTPUT'}</span></header><StreamCells active={activeStream} direction={direction} /></section>
      <div className="vxm-flow-arrow"><b>{direction === 'ltr' ? '→' : '←'}</b><span>32 × 64-bit Streams</span></div>
      <article className="vxm-slice-core">
        <header><span>u_fu_subsystems.u_vxm_subsystem.u_execution</span><h4>lpu_vxm_slice</h4><small>1 Global direction · 8 Local waves · 1 Global wave</small></header>
        <p className="vxm-layout-note">逻辑排布：控制波按 Tile 0 → 3 逐拍传递；每个 Tile 内的 L0–L7 并行，各自沿 Stage 0 → 15 运行。</p>
        <div className="vxm-superlanes">{tiles.map((tile) => <button key={tile} onClick={() => open(`:tiles:tile:${tile}`)}><span>TILE {tile} · CONTROL ROW {tile}</span><strong>SUPERLANE {tile}</strong><div>{lanes.map((lane) => <i key={lane} title={`Tile ${tile} · Lane ${lane} · 16 stages`}>L{lane}</i>)}</div><small>8 parallel lanes · 16 stages / lane · 128 positions</small></button>)}</div>
        <footer><button onClick={() => open(':control')}>CONTROL WAVES</button><button onClick={() => open(':data-path')}>VECTOR DATA PATH</button><button onClick={() => open(':lut')}>PRIVATE LUT ARRAYS</button></footer>
      </article>
      <div className="vxm-flow-arrow"><b>{direction === 'ltr' ? '→' : '←'}</b><span>Consumed / Produced / Pass-through</span></div>
      <section className={`vxm-boundary east ${input === 'EAST' ? 'active input' : 'output'}`}><header><b>EAST HEMISPHERE</b><span>{input === 'EAST' ? 'SELECTED INPUT' : 'RESULT / PASS OUTPUT'}</span></header><StreamCells active={activeStream} direction={direction} /></section>
    </div>
    <aside className="vxm-fact-strip"><span><b>4 × 16 × 8 = 512</b> physical ALU execution positions</span><span><b>32 Streams / direction</b> each 64 bit = 8 lane bytes</span><span><b>Global direction only</b> Tile direction cannot diverge</span></aside>
  </section>
}

function ControlView() {
  const clock = useAnimationClock(5)
  const tile = Math.min(clock.step, 3)
  const phase = clock.step <= 3 ? `T+${clock.step} · Tile ${tile} captures configuration` : clock.step === 4 ? 'Resident configuration · all Tiles loaded' : 'Execute wave · fixed scheduled pulse'
  return <section className="vxm-control-view" data-vxm-view="instruction-wave">
    <header className="vxm-view-heading"><div><span>L2 · CONTROL & INSTRUCTION WAVE</span><h3>8 Local Instructions + 1 Global Configuration</h3><p>九条四行控制流水线每周期前进一个 Tile。配置在 Tile 内驻留；这不是可以任意停顿和重试的弹性 FIFO。</p></div><VxmMetrics items={[["LOCAL", 'Q112–119'], ['GLOBAL', 'Q120 · 15 bit'], ['ROWS / WAVE', 4], ['RESERVED', 'Q121–127 inactive']]} /></header>
    <Controls clock={clock} label={phase} />
    <div className="vxm-wave-board">
      <div className="vxm-wave-sources">{queueWidths.map((width, queue) => <span key={queue}><b>Q{queue}</b><small>ICU {112 + queue}</small><strong>{width} bit</strong></span>)}<span className="global"><b>GLOBAL</b><small>ICU 120</small><strong>15 bit</strong></span></div>
      <div className="vxm-wave-path"><b className="wave-bus">REGISTERED FOUR-ROW WAVE →</b>{tiles.map((item) => <section key={item} className={`${clock.step === item ? 'active' : ''} ${clock.step > item ? 'resident' : ''}`}><span>T+{item}</span><strong>TILE {item}</strong><small>{clock.step < item ? 'waiting' : clock.step === item ? 'capture local + global' : 'resident configuration'}</small></section>)}<i className={clock.step === 5 ? 'active' : ''}>EXECUTE</i></div>
    </div>
    <div className="vxm-control-lower"><section><header>Local Queue → Mirrored Physical Stages</header>{queueWidths.map((width, queue) => <span key={queue}><b>Q{queue} · {width}b</b><i>Stage {queue}</i><i>Stage {queue + 8}</i></span>)}</section><section className="vxm-controller-boundary"><header><b>lpu_vxm_instruction_controller</b><em>RTL IMPLEMENTED / INTEGRATION PENDING</em></header><div>{['IDLE', 'LOAD', 'RUN', 'WAIT_DONE'].map((state, index) => <span className={index === Math.min(3, clock.step) ? 'active' : ''} key={state}>{state}{index < 3 && <i>→</i>}</span>)}</div><p>Repeat / Interval Controller 单独实现，但 `lpu_vxm_slice` 当前没有实例化它，不能把这条状态机画入活动主控制路径。</p></section></div>
    <aside className="vxm-warning"><b>Fixed schedule contract</b><span>配置或 Execute 未在指定周期被接受会触发 Fault；当前 Slice 没有 Local Superlane Instruction FIFO，也没有无限等待式动态反压。</span></aside>
  </section>
}

function TileArrayView({ selectedTile, onTile, onStage }: { selectedTile: number; onTile: (tile: number) => void; onStage: (tile: number, stage: number) => void }) {
  return <section className="vxm-tile-view" data-vxm-view="tile-array">
    <header className="vxm-view-heading"><div><span>L2 · SUPERLANE / TILE</span><h3>Tile {selectedTile} · 16 Physical Stages × 8 Lanes</h3><p>横轴为物理 Stage，纵轴为并行 Lane；每个格子都是一个 `lpu_vxm_execution_stage` 执行位置。</p></div><VxmMetrics items={[["TILES", 4], ['LANES / TILE', 8], ['STAGES / LANE', 16], ['POSITIONS / TILE', 128]]} /></header>
    <div className="vxm-tile-picker">{tiles.map((tile) => <button key={tile} className={selectedTile === tile ? 'active' : ''} onClick={() => onTile(tile)}>TILE {tile}</button>)}</div>
    <div className="vxm-array-scroll"><div className="vxm-array-axis"><span>LANE ↓ / STAGE →</span>{stages.map((stage) => <b key={stage}>S{stage}</b>)}</div>{lanes.map((lane) => <div className="vxm-array-row" key={lane}><strong>LANE {lane}</strong>{stages.map((stage) => { const queue = stage % 8; const special = [1, 5, 9, 13].includes(stage) ? 'exp' : [3, 7, 11, 15].includes(stage) ? 'rrl' : ''; return <button key={stage} className={special} onClick={() => onStage(selectedTile, stage)} title={`Tile ${selectedTile} · Stage ${stage} · Lane ${lane} · Local Q${queue}`}><b>S{stage}</b><span>L{lane}</span><i>Q{queue}</i></button>})}</div>)}</div>
    <div className="vxm-stage-map">{queueWidths.map((width, queue) => <span key={queue}><b>Q{queue}</b><i>{width} bit</i><strong>S{queue} + S{queue + 8}</strong></span>)}</div>
    <div className="vxm-special-placement"><span className="basic"><i />Q0/Q2/Q4/Q6 · Basic-only</span><span className="exp"><i />Q1/Q5 · Exp · S1/5/9/13</span><span className="rrl"><i />Q3/Q7 · Recip/Rsqrt/Log · S3/7/11/15</span></div>
  </section>
}

function LaneChainView() {
  const [chainLength, setChainLength] = useState(4)
  const [lane, setLane] = useState(0)
  const [lhs, setLhs] = useState('Stream')
  const [rhs, setRhs] = useState('Immediate')
  const clock = useAnimationClock(17, 0, 0)
  const tokenStage = clock.step - 1
  const sourceOptions = ['Previous', 'Stream', 'Original', 'Auxiliary', 'Immediate', 'Accumulator', 'Feedback']
  return <section className="vxm-lane-view" data-vxm-view="lane-chain">
    <header className="vxm-view-heading"><div><span>L3 · SINGLE LANE</span><h3>Lane {lane} · 16 Fixed Physical Stages</h3><p>物理链不变，chain_length 只重定义 Head / Internal / Tail 分组。Stage 间寄存器传递 value、original、auxiliary 三个 32-bit 字段和 valid。</p></div><VxmMetrics items={[["CONTAINER", '32 bit'], ['TOKEN FIELDS', 3], ['CHAIN LENGTH', chainLength], ['CHAINS', 16 / chainLength]]} /></header>
    <div className="vxm-chain-toolbar"><label>LANE<select name="vxm-lane" value={lane} onChange={(event) => { setLane(Number(event.target.value)); clock.reset() }}>{lanes.map((item) => <option key={item}>{item}</option>)}</select></label><div>{[2, 4, 8].map((length) => <button key={length} className={chainLength === length ? 'active' : ''} onClick={() => { setChainLength(length); clock.reset() }}>{length}-STAGE CHAIN</button>)}</div><label>LHS<select name="vxm-lhs-source" value={lhs} onChange={(event) => setLhs(event.target.value)}>{sourceOptions.map((source) => <option key={source}>{source}</option>)}</select></label><label>RHS<select name="vxm-rhs-source" value={rhs} onChange={(event) => setRhs(event.target.value)}>{sourceOptions.map((source) => <option key={source}>{source}</option>)}</select></label></div>
    <Controls clock={clock} label={clock.step === 0 ? 'Token waiting at chain input' : clock.step <= 16 ? `Token at Stage ${tokenStage}` : 'Token emitted by chain tail'} />
    <div className="vxm-chain-track">{stages.map((stage) => { const offset = stage % chainLength; const role = offset === 0 ? 'head' : offset === chainLength - 1 ? 'tail' : 'internal'; const chain = Math.floor(stage / chainLength); return <div className={`vxm-chain-stage ${role} ${tokenStage === stage ? 'active' : ''}`} data-chain={chain % 4} key={stage}><small>CHAIN {chain}</small><b>ALU[{stage}]</b><span>{role.toUpperCase()}</span><i>Q{stage % 8}</i>{stage < 15 && <em>→</em>}</div>})}</div>
    <div className="vxm-token-contract"><section><header>OPERAND MUX · CURRENT SELECTION</header><span><b>LHS</b>{lhs}</span><span><b>RHS</b>{rhs}</span><small>Chain Head 可建立新 Token；Internal Stage 的合法组合由 local decoder 限制，不表示七类来源都可同时无条件使用。</small></section><section><header>REGISTERED TOKEN</header><span><b>value</b>32 bit</span><span><b>original</b>32 bit</span><span><b>auxiliary</b>32 bit</span><small>valid 与三字段跨 Stage 同步传播；Accumulator / Feedback 为独立状态来源。</small></section></div>
  </section>
}

function StreamFormatView() {
  const [format, setFormat] = useState<DataFormat>('FP32')
  const [block, setBlock] = useState(0)
  const [readyLo, setReadyLo] = useState(true)
  const [readyHi, setReadyHi] = useState(true)
  const maxStep = format === 'FP32' ? 6 : 4
  const clock = useAnimationClock(maxStep, 0, 0)
  const labels = format === 'FP32' ? ['WAIT', 'INPUT LOW16', 'INPUT HIGH16', 'OPERAND READY', 'OUTPUT LOW16', 'OUTPUT HIGH16', 'DONE'] : ['WAIT', 'INPUT 16', 'OPERAND READY', 'OUTPUT 16', 'DONE']
  return <section className="vxm-stream-view" data-vxm-view="stream-format">
    <header className="vxm-view-heading"><div><span>L3 · STREAM INTERFACE</span><h3>Block {block} · Four Byte Streams × Eight Lanes</h3><p>每两个 Stage 共用一个 Stream Block。四条输入 Stream 分别承载 LHS/RHS 的低、高 Byte；FP32 使用相同 Stream 分两拍组装。</p></div><VxmMetrics items={[["BLOCKS / TILE", 8], ['STREAMS / BLOCK', 4], ['STREAMS / TILE', 32], ['STREAM WIDTH', '64 bit']]} /></header>
    <div className="vxm-format-toolbar"><div>{(['FP16', 'BF16', 'FP32'] as DataFormat[]).map((item) => <button key={item} className={format === item ? 'active' : ''} onClick={() => { setFormat(item); clock.reset() }}>{item}</button>)}</div><label>BLOCK<select name="vxm-stream-block" value={block} onChange={(event) => { setBlock(Number(event.target.value)); clock.reset() }}>{lanes.map((item) => <option key={item}>{item}</option>)}</select></label><label><input type="checkbox" name="vxm-ready-lo" checked={readyLo} onChange={(event) => setReadyLo(event.target.checked)} /> output_ready[{block * 2}]</label><label><input type="checkbox" name="vxm-ready-hi" checked={readyHi} onChange={(event) => setReadyHi(event.target.checked)} /> output_ready[{block * 2 + 1}]</label></div>
    <Controls clock={clock} label={`${format} · ${labels[clock.step]}`} />
    <div className="vxm-stream-assembly"><section><header><b>32 INPUT STREAMS</b><span>Block {block} uses S{block * 4}…S{block * 4 + 3}</span></header>{['LHS BYTE 0', 'LHS BYTE 1', 'RHS BYTE 0', 'RHS BYTE 1'].map((name, index) => <div className={clock.step === 1 || (format === 'FP32' && clock.step === 2) ? 'active' : ''} key={name}><b>S{block * 4 + index}</b><span>{name}</span><em>{lanes.map((lane) => <i key={lane}>L{lane}</i>)}</em></div>)}</section><div className="vxm-beat-assembler"><span className={clock.step === 1 ? 'active' : ''}><b>CYCLE 0</b>{format === 'FP32' ? 'LOW 16 bit' : `${format} 16 bit`}</span>{format === 'FP32' && <><i>↓</i><span className={clock.step === 2 ? 'active' : ''}><b>CYCLE 1</b>HIGH 16 bit</span></>}<i>↓</i><strong className={clock.step === (format === 'FP32' ? 3 : 2) ? 'active' : ''}>{format} OPERAND READY</strong><small>LHS / RHS phase states are independent and retain complete operands until the matching Chain Head request is accepted.</small></div><section className="vxm-stream-output"><header><b>FIXED OUTPUT PAIR</b><span>S{block * 2} + S{block * 2 + 1}</span></header><div className={clock.step === (format === 'FP32' ? 4 : 3) ? 'active' : ''}><b>{format === 'FP32' ? 'LOW16' : '16-bit Beat'}</b><span>8 lane bytes × two streams</span></div>{format === 'FP32' && <div className={clock.step === 5 ? 'active' : ''}><b>HIGH16</b><span>second serialized beat</span></div>}<footer className={readyLo && readyHi ? 'ready' : 'blocked'}>{readyLo && readyHi ? 'ATOMIC PAIR READY' : 'OUTPUT PENDING · both ready required'}</footer></section></div>
  </section>
}

function AluView() {
  const [special, setSpecial] = useState('Log')
  const details: Record<string, string[]> = {
    Exp: ['Range reduction', '64-entry Function 0 LUT', 'Linear interpolation', 'FP32 cubic Horner continuation', 'Exponent restore'],
    Reciprocal: ['Normalize operand', '64-entry Function 1 LUT', 'Linear interpolation', 'FP32 Newton refinement', 'Format pack'],
    Rsqrt: ['Normalize + exponent parity', '64-entry Function 2 LUT', 'Linear interpolation', 'FP32 Newton refinement', 'Format pack'],
    Log: ['Normalize + residual', '64-entry Function 3 · 50-bit row', 'Base / Inverse response', 'Horner polynomial in FP32 path', 'Result restore'],
  }
  return <section className="vxm-alu-view" data-vxm-view="alu-architecture">
    <header className="vxm-view-heading"><div><span>L3 / L4 · ALU ARCHITECTURE</span><h3>32-bit Container · Basic / Special Dispatch</h3><p>FP16/BF16 使用 [15:0]，FP32 使用 [31:0]；Reserved format 不是正常模式。Special 能力只出现在指定物理 Stage。</p></div><VxmMetrics items={[["BASIC", 6], ['SPECIAL', 4], ['BASIC LATENCY', '1 / 2 cycles'], ['SPECIAL NOMINAL', '8 cycles + LUT wait']]} /></header>
    <div className="vxm-alu-dispatch"><span>OPERAND LHS / RHS</span><i>→</i><span>UNPACK + FORMAT</span><i>→</i><span>OPCODE DECODE</span><i>→</i><div><strong>BASIC ALU</strong><strong>SPECIAL ALU</strong></div><i>→</i><span>RESULT REGISTER</span></div>
    <div className="vxm-alu-columns"><section><header>BASIC ALU</header><div className="vxm-basic-ops">{['Bypass', 'Add', 'Subtract', 'Multiply', 'Negate', 'Max'].map((op) => <span key={op}><b>{op}</b><small>{op === 'Multiply' ? '2 cycles · shared segmented multiplier' : op === 'Add' || op === 'Subtract' ? 'shared 27-bit add/sub' : op === 'Max' ? 'shared comparator' : '1 cycle'}</small></span>)}</div><footer><b>Arithmetic details</b><span>14-bit + 13-bit carry groups · Grouped LZC · 3×3 8-bit multiplier blocks</span></footer></section><section><header>SPECIAL ALU · PHYSICAL PLACEMENT</header><div className="vxm-special-buttons">{Object.keys(details).map((op) => <button key={op} className={special === op ? 'active' : ''} onClick={() => setSpecial(op)}>{op}</button>)}</div><div className="vxm-special-pipeline">{details[special].map((stage, index) => <span key={stage}><b>{index + 1}</b>{stage}{index < details[special].length - 1 && <i>→</i>}</span>)}</div><div className="vxm-stage-capabilities">{stages.map((stage) => <i className={[1, 5, 9, 13].includes(stage) ? 'exp' : [3, 7, 11, 15].includes(stage) ? 'rrl' : 'basic'} key={stage} title={`Stage ${stage} · Q${stage % 8}`}><b>S{stage}</b><small>{[1, 5, 9, 13].includes(stage) ? 'EXP' : [3, 7, 11, 15].includes(stage) ? 'R/R/L' : 'BASIC'}</small></i>)}</div><footer><b>Log contract</b><span>Q3/Q7 extension · canonical 6'b100110 (0x26) · Function 3 · Stage 3/7/11/15</span></footer></section></div>
  </section>
}

function LutView() {
  const [functionId, setFunctionId] = useState(3)
  const [tile, setTile] = useState(0)
  const [lane, setLane] = useState(0)
  const [stage, setStage] = useState(3)
  const [address, setAddress] = useState(18)
  const clock = useAnimationClock(9)
  const fn = lutFunctions[functionId]
  const phases = ['IDLE', 'SPECIAL ACCEPT', 'LUT REQUEST', 'SRAM READ', 'TAGGED RESPONSE', 'INTERPOLATE', 'PIPELINE', 'PIPELINE', 'RESULT VALID', 'DONE']
  return <section className="vxm-lut-view" data-vxm-view="lut-array">
    <header className="vxm-view-heading"><div><span>L3 · PRIVATE TILE / LANE LUT SRAM</span><h3>4 Tiles × 4 Functions × 8 Lanes = 128 SRAMs</h3><p>四个 Tile 各自拥有 32 个逻辑单读口 SRAM；同 Function/Lane 的多 Stage 同拍请求为协议 Fault，不同 Function 或 Lane 可并行。</p></div><VxmMetrics items={[["SRAMS / TILE", 32], ['SRAMS / VXM', 128], ['ENTRIES / SRAM', 64], ['READ', '1 cycle + stage tag']]} /></header>
    <div className="vxm-lut-toolbar"><label>FUNCTION<select name="vxm-lut-function" value={functionId} onChange={(event) => { setFunctionId(Number(event.target.value)); clock.reset() }}>{lutFunctions.map((item) => <option key={item.id} value={item.id}>{item.id} · {item.name}</option>)}</select></label><label>TILE<select name="vxm-lut-tile" value={tile} onChange={(event) => { setTile(Number(event.target.value)); clock.reset() }}>{tiles.map((item) => <option key={item}>{item}</option>)}</select></label><label>LANE<select name="vxm-lut-lane" value={lane} onChange={(event) => { setLane(Number(event.target.value)); clock.reset() }}>{lanes.map((item) => <option key={item}>{item}</option>)}</select></label><label>STAGE<select name="vxm-lut-stage" value={stage} onChange={(event) => { setStage(Number(event.target.value)); clock.reset() }}>{stages.map((item) => <option key={item}>{item}</option>)}</select></label><label>ADDRESS<input name="vxm-lut-address" type="number" min={0} max={63} value={address} onChange={(event) => { setAddress(Math.max(0, Math.min(63, Number(event.target.value)))); clock.reset() }} /></label></div>
    <Controls clock={clock} label={`${phases[clock.step]} · T${tile} F${functionId} L${lane} A${address} · tag S${stage}`} />
    <div className="vxm-lut-content"><div className="vxm-lut-array">{tiles.map((tileId) => <section className={tileId === tile ? 'active' : ''} key={tileId}><header>TILE {tileId} · PRIVATE COPY</header><div>{lanes.flatMap((laneId) => lutFunctions.map((item) => <button key={`${laneId}-${item.id}`} className={tileId === tile && laneId === lane && item.id === functionId ? 'active' : ''} onClick={() => { setTile(tileId); setLane(laneId); setFunctionId(item.id); clock.reset() }} title={`Tile ${tileId} · ${item.name} · Lane ${laneId} · 64×${item.width} bit`}><b>F{item.id}</b><span>L{laneId}</span></button>))}</div></section>)}</div><div className="vxm-lut-inspector"><header><b>FUNCTION {fn.id} · {fn.name}</b><span>{fn.width} bit × 64 entries</span></header><dl><div><dt>ROW FORMAT</dt><dd>{fn.row}</dd></div><div><dt>ALLOWED STAGES</dt><dd>{fn.stages}</dd></div><div><dt>READ ADDRESS</dt><dd>{address} / 63</dd></div><div><dt>RETURN TAG</dt><dd>Physical Stage {stage}</dd></div></dl><div className="vxm-lut-pipeline">{['ALU accept', `F${functionId}/L${lane}`, `addr ${address}`, 'SRAM', `tag S${stage}`, 'Special ALU', 'result'].map((item, index) => <span className={clock.step >= index + 1 ? 'active' : ''} key={item}>{item}{index < 6 && <i>→</i>}</span>)}</div></div></div>
    <aside className="vxm-boundary-note"><b>Slice Interface Available / Top-level Tie-off</b><span>`lpu_vxm_slice` 提供 LUT config/write 广播接口；当前 `lpu_top.sv` 将 valid tie-off 为 0，不能宣称 Top 已支持外部编程。此处 SRAM 是逻辑单端口存储，不宣称物理 Macro 映射。</span></aside>
  </section>
}

function BridgeView() {
  const [mode, setMode] = useState<'pass' | 'consume' | 'produce' | 'conflict'>('pass')
  const [hemisphere, setHemisphere] = useState(0)
  const [tile, setTile] = useState(0)
  const [stream, setStream] = useState(0)
  const clock = useAnimationClock(3, 0, 0)
  const descriptions = { pass: 'West traffic is not consumed → cross to opposite Hemisphere East edge', consume: 'West traffic is consumed by VXM → no passive forwarding', produce: 'Active VXM result occupies the selected output cell', conflict: 'Two producers target the same output cell → conflict_o=1' }
  return <section className="vxm-bridge-view" data-vxm-view="stream-bridge">
    <header className="vxm-view-heading"><div><span>L2 · DIRECTION-AWARE STREAM BRIDGE</span><h3>External East · West From MEM · Produced Result</h3><p>Bridge 只有组合路由与 Conflict 检测；没有额外仲裁器、FIFO 或缓存。</p></div><VxmMetrics items={[["CELLS", '2×4×32'], ['WORD', '64 bit'], ['BUFFER', 'None'], ['FAULT', 'conflict_o']]} /></header>
    <div className="vxm-bridge-toolbar"><div>{(['pass', 'consume', 'produce', 'conflict'] as const).map((item) => <button key={item} className={`${mode === item ? 'active' : ''} ${item === 'conflict' ? 'fault' : ''}`} onClick={() => { setMode(item); clock.reset() }}>{item.toUpperCase()}</button>)}</div><label>HEMI<select name="vxm-bridge-hemi" value={hemisphere} onChange={(event) => { setHemisphere(Number(event.target.value)); clock.reset() }}><option>0</option><option>1</option></select></label><label>TILE<select name="vxm-bridge-tile" value={tile} onChange={(event) => { setTile(Number(event.target.value)); clock.reset() }}>{tiles.map((item) => <option key={item}>{item}</option>)}</select></label><label>STREAM<select name="vxm-bridge-stream" value={stream} onChange={(event) => { setStream(Number(event.target.value)); clock.reset() }}>{streams.map((item) => <option key={item}>{item}</option>)}</select></label></div>
    <Controls clock={clock} label={`H${hemisphere} · T${tile} · S${stream} · ${mode.toUpperCase()}`} />
    <div className={`vxm-bridge-diagram mode-${mode}`}><section className={clock.step >= 1 ? 'active' : ''}><b>EXTERNAL EAST</b><span>local cell enters unchanged</span></section><section className={clock.step >= 1 ? 'active' : ''}><b>WEST FROM MEM</b><span>consumed={mode === 'consume' ? 1 : 0}</span></section><i>→</i><article className={clock.step >= 2 ? 'active' : ''}><b>STREAM BRIDGE</b><span>cell index H{hemisphere}/T{tile}/S{stream}</span><strong>{descriptions[mode]}</strong></article><i>→</i><section className={`${clock.step >= 3 ? 'active' : ''} ${mode === 'conflict' ? 'fault' : ''}`}><b>OPPOSITE EAST-TO-MEM</b><span>H{hemisphere ^ 1} / T{tile} / S{stream}</span></section><section className={mode === 'produce' || mode === 'conflict' ? 'active result' : ''}><b>VXM PRODUCED RESULT</b><span>same conflict rules as any producer</span></section></div>
  </section>
}

export default function VxmFunctionalExplorer({ block, current, nodes, onNavigate, onSelectNode }: Props) {
  const [view, setView] = useState<VxmView>(() => viewForNode(current))
  const selectedTile = useMemo(() => Number(current.id.match(/:tile:(\d+)/)?.[1] ?? 0), [current.id])
  useEffect(() => setView(viewForNode(current)), [current.id, current.nodeType])
  const open = (suffix: string) => {
    const node = findNode(nodes, block.id, suffix)
    if (node) node.childIds.length ? onNavigate(node.id) : onSelectNode(node.id)
  }
  const openTile = (tile: number) => {
    const node = findNode(nodes, block.id, `:tiles:tile:${tile}`)
    if (node) onNavigate(node.id)
    else setView('tile')
  }
  const openStage = (tile: number, stage: number) => {
    const node = findNode(nodes, block.id, `:tiles:tile:${tile}:stage:${stage}`)
    if (node) onSelectNode(node.id)
  }
  return <div className="vxm-explorer" data-vxm-root={current.id}>
    <header className="vxm-hero"><div><span>LOCAL RTL · CURRENT WORKSPACE</span><h2>{block.displayName} · Interactive VXM Architecture</h2><p>从一个 Slice 下钻到四个 Superlane、16×8 执行阵列、Lane Chain、Stream 格式、Basic/Special ALU 与私有 LUT。</p></div><div className="vxm-status-stack"><b>RTL STRUCTURE CONFIRMED</b><span>u_vxm_subsystem.u_execution · one Slice</span><i>4 Tile · 32 Lane · 512 positions</i></div></header>
    <nav className="vxm-tabs" aria-label="VXM architecture views">{viewLabels.map(([id, label]) => <button key={id} className={view === id ? 'active' : ''} onClick={() => setView(id)}>{label}</button>)}</nav>
    {view === 'overview' && <OverviewView open={open} />}
    {view === 'control' && <ControlView />}
    {view === 'tile' && <TileArrayView selectedTile={selectedTile} onTile={openTile} onStage={openStage} />}
    {view === 'lane' && <LaneChainView />}
    {view === 'stream' && <StreamFormatView />}
    {view === 'alu' && <AluView />}
    {view === 'lut' && <LutView />}
    {view === 'bridge' && <BridgeView />}
    <section className="vxm-evidence-panel"><div><span>ACTIVE IN CURRENT SLICE</span><b>4 Tile Execution · 4 Tile LUT · 8 Local + 1 Global Wave · Stream Bridge · Basic/Special ALU</b></div><div><span>IMPLEMENTED / INTEGRATION PENDING</span><b>lpu_vxm_instruction_controller · Repeat / Interval path</b></div><div><span>INTERFACE / TOP TIE-OFF</span><b>LUT Configuration + Write valid = 0 at lpu_top</b></div><div><span>RESERVED / FAULT</span><b>Reserved format/chain · READ_BITS_8 unsupported by Tile · active_width not interpreted as lane gating</b></div><button onClick={() => onSelectNode(current.id)}>打开当前节点 Inspector</button></section>
  </div>
}
