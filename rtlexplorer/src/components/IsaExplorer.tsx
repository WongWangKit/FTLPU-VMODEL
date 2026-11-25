import { useEffect, useMemo, useState } from 'react'
import { isaCatalogReviewedAt, isaInstructions, isaVersions } from '../lib/isa-catalog'
import type { IsaField, IsaFu, IsaInstruction, IsaRepository } from '../lib/isa-catalog'

type Section = 'overview' | 'macro' | 'matrix' | 'dispatch'
interface Props {
  initialFu?: IsaFu
  onOpenArchitecture: (fu: IsaFu) => void
  onOpenDecoder: (fu: 'MEM' | 'MXM') => void
}
const sections: { id: Section; label: string }[] = [
  { id: 'overview', label: 'FU Native ISA' },
  { id: 'macro', label: 'Shared Macro' },
  { id: 'matrix', label: 'Cross-FU Matrix' },
  { id: 'dispatch', label: 'ICU Dispatch' },
]
const fus: IsaFu[] = ['MEM', 'MXM', 'VXM', 'SXM']
const repoNames: IsaRepository[] = ['VMODEL', 'CMODEL', 'SOFTWARE']

function BitRangeText({ text }: { text: string }) {
  return <>{text.split(/(\[\d+(?::\d+)?\])/g).map((part, index) => /^\[\d+(?::\d+)?\]$/.test(part) ? <span className="isa-bit-range" key={index}>{part}</span> : part)}</>
}

function BitField({ field, active, onClick }: { field: IsaField; active: boolean; onClick: () => void }) {
  const choices = field.choices?.map((choice) => `${choice.value}=${choice.label}`).join('；')
  return <button className={`isa-bit ${active ? 'active' : ''}`} style={{ flexGrow: field.width }} onClick={onClick} title={`${field.bits} · ${field.meaning}${choices ? `；${choices}` : ''}`}><span>{field.bits}</span><strong>{field.name}</strong><small>{field.width} bit</small></button>
}

function FieldChoices({ choices }: { choices: NonNullable<IsaField['choices']> }) {
  return <span className="isa-field-choices">{choices.map((choice) => <span key={choice.value}><b>{choice.value}</b><strong>{choice.label}</strong></span>)}</span>
}

function NativeDetail({ instruction, selectedField, setSelectedField, onOpenArchitecture }: {
  instruction: IsaInstruction
  selectedField: string | null
  setSelectedField: (value: string | null) => void
  onOpenArchitecture: (fu: IsaFu) => void
}) {
  return <div className="isa-native-detail">
    <div className="isa-detail-head"><div><span className="isa-eyebrow">{instruction.fu} · {instruction.kind}</span><h2>{instruction.name}</h2><p><BitRangeText text={instruction.summary} /></p></div><span className={`isa-status status-${instruction.status.toLowerCase()}`}>{instruction.status}</span></div>
    <div className="isa-metrics"><div><span>INSTRUCTION WIDTH</span><strong>{instruction.width}</strong></div><div><span>OPCODE / QUEUE</span><strong><BitRangeText text={instruction.opcode} /></strong></div><div><span>VERSION</span><strong>{instruction.version}</strong></div></div>
    {instruction.fields.length ? <><h3>Instruction Encoding</h3><div className="isa-bit-layout" aria-label={`${instruction.name} 位域图`}>{instruction.fields.map((item) => <BitField key={item.name} field={item} active={selectedField === item.name} onClick={() => setSelectedField(item.name)} />)}</div><div className="isa-field-table"><div className="isa-table-head"><span>FIELD</span><span>BIT RANGE</span><span>WIDTH</span><span>SIGNED</span><span>MEANING</span></div>{instruction.fields.map((item) => <button key={item.name} className={selectedField === item.name ? 'active' : ''} onClick={() => setSelectedField(item.name)}><strong>{item.name}</strong><code>{item.bits}</code><span>{item.width} bit</span><span>{item.signed ? '是' : '否'}</span><span><BitRangeText text={item.meaning} />{item.choices && <FieldChoices choices={item.choices} />}</span></button>)}</div></> : <div className="isa-unverified"><strong>无可确认的生产 RTL 位域</strong><p>这里展示 CModel typed 指令类别，不编造硬件 opcode、位宽或 bit range。</p></div>}
    {instruction.fu === 'VXM' && <div className="isa-subpanel"><h3>局部 Opcode 与实际 stage</h3><div className="isa-opcode-grid">{[
      ['0', 'BYPASS', 'Q0–Q7', '直接传递'], ['1', 'ADD', 'Q0–Q7', '加法'], ['2', 'SUBTRACT', 'Q0–Q7', '减法'], ['3', 'MULTIPLY', 'Q0–Q7', '乘法'], ['4', 'NEGATE', 'Q0–Q7', '取负'], ['5', 'MAX', 'Q0–Q7', '取最大'],
      ['6', 'EXP', 'Q1 / Q5', '特殊 ALU'], ['6', 'RECIPROCAL', 'Q3 / Q7', '特殊 ALU'], ['7', 'RSQRT', 'Q3 / Q7', '特殊 ALU'], ['8*', 'LOG', 'Q3 / Q7', 'bit[5] 扩展，原始紧凑字 6\'b100110'],
    ].map(([opcode, name, stages, detail]) => <div key={`${opcode}-${name}`}><code>{opcode}</code><strong>{name}</strong><span>{stages}</span><small><BitRangeText text={detail} /></small></div>)}</div><p>操作数来源由 stage 的链首/链中位置解释；8* 为译码后的有效 opcode，不是独立 4-bit 原生 opcode 位段。</p></div>}
    {instruction.fu === 'SXM' && instruction.kind === 'CModel typed instruction' && <div className="isa-subpanel"><h3>CModel typed API 字段</h3><p>{instruction.name === 'ShiftSelect' ? 'shift_source（Unshifted / NorthShifted / SouthShifted）、shift_distance、src_streams、dst_streams。' : instruction.name === 'Distribute' ? 'lane_map、src_streams、dst_streams；将一个字节流对分配到转置行。' : instruction.name === 'Transpose' ? 'src_streams、dst_streams、input_row、output_row、output_tile；以行/Tile 关系进行转置。' : 'permute_map、src_streams、dst_streams；按 lane 索引表重排。'}这些是 C++ 对象成员，尚未与 native ROW bit range 对齐。</p></div>}
    {instruction.caution && <p className="isa-caution"><BitRangeText text={instruction.caution} /></p>}
    <h3>Decode → Dispatch → Execution</h3><div className="isa-path">{instruction.path.map((step, index) => <div key={`${step}-${index}`}>{index > 0 && <b>→</b>}<span>{step}</span></div>)}</div>
    <button className="isa-action" onClick={() => onOpenArchitecture(instruction.fu)}>打开 {instruction.fu} 架构 →</button>
    {instruction.example && <div className="isa-example"><strong>Testbench 字段构造实例</strong><code>{instruction.example.word}</code><code>{BigInt(instruction.example.word).toString(2).padStart(64, '0')}</code><p><BitRangeText text={instruction.example.meaning} /></p></div>}
  </div>
}

function MacroView({ onOpenDecoder }: { onOpenDecoder: Props['onOpenDecoder'] }) {
  const [variant, setVariant] = useState<'MEM' | 'MXM'>('MEM')
  const [stage, setStage] = useState('Control')
  const stages = [
    { name: 'Control', state: 'IDLE_GLOBAL', detail: 'bit[0] valid、bit[1] reserved=0、bit[3:2]=01；高位保留区必须为 0。' },
    { name: 'Dictionary', state: 'DICT_STORE / DICT_LOOKUP', detail: '先读取 3-bit 字典项数（0–7），再按每项 36 bit 保存 start delta[21:0] 与 signed operand delta[35:22]。' },
    { name: 'Run Header', state: 'RUN_HEADER', detail: '先读取 1-bit repeat 标志；置位时再读取 16-bit run_length_minus_1，实际长度加 1。' },
    { name: 'Template', state: 'TEMPLATE', detail: 'Extended Header 共 33 bit（标志 + Native32）；Compact Header 共 11 bit，后续 payload 长度由 shape 决定。' },
    { name: 'Delta / Escape', state: 'GET_DELTA / ESCAPE / APPLY_DELTA', detail: '解析差分或显式值，更新绝对上下文。' },
    { name: 'Output', state: 'OUTPUT_CONTEXT', detail: '生成并保持 decoded context，等待下游 ready。' },
  ]
  const current = stages.find((item) => item.name === stage) ?? stages[0]
  return <section className="isa-card"><span className="isa-eyebrow">SHARED ISA · PACKED-V1</span><h2>Macro Compression & Expansion</h2><p>MEM 与 MXM 的 Control 低位规则相同；iMEM 字宽和原生 payload 各自不同。VXM / SXM 不能据此标成同一条已接入的 Macro 路径。</p><div className="isa-tabs">{(['MEM', 'MXM'] as const).map((fu) => <button key={fu} className={variant === fu ? 'active' : ''} onClick={() => setVariant(fu)}>{fu} · {fu === 'MEM' ? '96-bit iMEM' : '128-bit iMEM'}</button>)}</div>
    <div className="isa-metrics"><div><span>CONTROL</span><strong><BitRangeText text="[3:2]=01 · bit0 valid" /></strong></div><div><span>RESERVED</span><strong><BitRangeText text={`${variant === 'MEM' ? '[95:28]' : '[127:28]'}=0 · bit1=0`} /></strong></div><div><span>OUTPUT</span><strong>{variant === 'MEM' ? 'MEM context / Native32' : 'Queue-specific native payload'}</strong></div></div>
    <div className="isa-bit-layout"><button className="isa-bit" style={{ flexGrow: 8 }} onClick={() => setStage('Control')}><span>{variant === 'MEM' ? '[95:28]' : '[127:28]'}</span><strong>Reserved = 0</strong></button><button className="isa-bit" style={{ flexGrow: 3 }} onClick={() => setStage('Control')}><span>[27:4]</span><strong>Queue Macro Count</strong></button><button className="isa-bit" style={{ flexGrow: 1 }} onClick={() => setStage('Control')}><span>[3:2]</span><strong>01</strong></button><button className="isa-bit" style={{ flexGrow: 1 }} onClick={() => setStage('Control')}><span>[1:0]</span><strong>0 / valid</strong></button></div>
    <div className="isa-macro-grammar"><div><b>1 · Control Word</b><span>{variant === 'MEM' ? '96' : '128'} bit · 独立的首字</span></div><div><b>2 · Dictionary</b><span>3-bit count + 36 bit / entry</span></div><div><b>3 · Initial State</b><span><BitRangeText text={variant === 'MEM' ? '45 bit：start cycle[31:0] + address[44:32]' : 'variant-specific，点击源码核对'} /></span></div><div><b>4 · Run / Template</b><span>1-bit flag + 可选 16-bit length；compact / extended</span></div><div><b>5 · Delta / Escape</b><span>Prefix 选择字典或显式差分；按需跨 iMEM 字取位</span></div><div><b>6 · Output</b><span>Context valid / ready 后发射原生字段</span></div></div>
    {variant === 'MEM' && <div className="isa-example"><strong>当前 RTL Testbench 的 Control Word</strong><code>96'h000000000000000000000015</code><p><BitRangeText text="sim/tb/lpu_mem_macro_decoder_tb.sv:396 · bit[27:4]=1、bit[3:2]=01、bit[1]=0、bit[0]=1。这里只展示真实首字；余下数据需按该测试的后续 iMEM 字读取。" /></p></div>}
    <div className="isa-macro-stages">{stages.map((item) => <button key={item.name} className={stage === item.name ? 'active' : ''} onClick={() => setStage(item.name)}>{item.name}</button>)}</div><div className="isa-stage-detail"><strong>{current.state}</strong><p><BitRangeText text={current.detail} /></p></div><button className="isa-action" onClick={() => onOpenDecoder(variant)}>打开现有 {variant} Macro Decoder 状态机 →</button>
  </section>
}

const compatibility: { fu: IsaFu; encoding: string; semantic: string; dispatch: string; execution: string }[] = [
  { fu: 'MEM', encoding: 'MATCH · READ/WRITE', semantic: 'PARTIAL · Gather/Scatter', dispatch: 'PARTIAL · READ/WRITE', execution: 'UNVERIFIED · 未做三端同输入回归' },
  { fu: 'MXM', encoding: 'PARTIAL · Macro 头部', semantic: 'UNVERIFIED · 原生三端', dispatch: 'PARTIAL · 五队列 RTL', execution: 'UNVERIFIED · 未做三端同输入回归' },
  { fu: 'VXM', encoding: 'UNVERIFIED', semantic: 'UNVERIFIED', dispatch: 'NOT_INTEGRATED', execution: 'NOT_INTEGRATED' },
  { fu: 'SXM', encoding: 'PARTIAL · native CTRL/EXEC', semantic: 'UNVERIFIED · CModel ROW', dispatch: 'INTEGRATED · Program Target 5/6', execution: 'PARTIAL · RTL VCS PASS' },
]

function MatrixView({ onSelect }: { onSelect: (instruction: IsaInstruction) => void }) {
  const [fu, setFu] = useState<IsaFu | 'ALL'>('ALL')
  return <section className="isa-card"><span className="isa-eyebrow">CROSS-FU ISA CONSISTENCY</span><h2>指令与三端证据</h2><p>状态表示目前已确认的覆盖范围，不等同系统级 PASS。点击一行检查字段。</p><div className="isa-tabs">{(['ALL', ...fus] as const).map((item) => <button className={fu === item ? 'active' : ''} key={item} onClick={() => setFu(item)}>{item}</button>)}</div><div className="isa-matrix"><div className="isa-matrix-head"><span>FU / INSTRUCTION</span><span>WIDTH</span><span>OPCODE</span><span>SOFTWARE</span><span>CMODEL</span><span>VMODEL</span><span>STATUS</span></div>{isaInstructions.filter((item) => fu === 'ALL' || fu === item.fu).map((item) => <button key={item.id} onClick={() => onSelect(item)}><strong>{item.fu} · {item.name}</strong><span>{item.width}</span><span><BitRangeText text={item.opcode} /></span>{repoNames.map((repo) => <span key={repo}>{item.evidence.some((entry) => entry.repo === repo) ? '源码定位' : '待核'}</span>)}<span className={`isa-status status-${item.status.toLowerCase()}`}>{item.status}</span></button>)}</div><h3>Compatibility by dimension</h3><div className="isa-matrix isa-compat"><div className="isa-compat-head"><span>FU</span><span>ENCODING</span><span>SEMANTIC</span><span>DISPATCH</span><span>EXECUTION</span></div>{compatibility.filter((item) => fu === 'ALL' || fu === item.fu).map((item) => <div key={item.fu}><strong>{item.fu}</strong><span>{item.encoding}</span><span>{item.semantic}</span><span>{item.dispatch}</span><span>{item.execution}</span></div>)}</div><div className="isa-unverified"><strong>判定边界</strong><p>MEM READ/WRITE 的编码位段可在 RTL 和 CModel 中逐项核对；这不足以证明系统级执行一致。其余字段或路径没有足够证据时明确保留 UNVERIFIED。</p></div></section>
}

function DispatchView() {
  return <section className="isa-card"><span className="isa-eyebrow">ICU → FU INSTRUCTION DISPATCH</span><h2>真实目标由装载目的地和队列决定</h2><p>当前没有一条覆盖全部原生 FU 字的统一 FU_ID。Program Load Destination、Macro 解码和 QCTL 发射属于不同层。</p><div className="isa-dispatch-grid"><div><b>Program Load Destination · 13 bit</b><strong><BitRangeText text="[12] Hemisphere · [11:8] Target Kind · [7:0] Index" /></strong></div><div><b>MEM · 已接入</b><strong>MEM Bank local iMEM → Macro Decoder → Context → Scheduler → MEM64</strong></div><div><b>MXM · 已接入</b><strong>五条独立队列 → 共享 Macro 解析 → Queue-specific Native</strong></div><div><b>SXM · 已接入</b><strong>R6 Outer Local → Target 5/6 → CTRL/EXEC Calendar → ROW Core</strong></div><div className="disconnected"><b>VXM · 当前断点</b><strong>Program target 枚举存在；正式本地发射路径未接通</strong></div></div></section>
}

export default function IsaExplorer({ initialFu = 'MEM', onOpenArchitecture, onOpenDecoder }: Props) {
  const [section, setSection] = useState<Section>('overview')
  const [fu, setFu] = useState<IsaFu>(initialFu)
  const [instructionId, setInstructionId] = useState('mem-read')
  const [selectedField, setSelectedField] = useState<string | null>(null)
  const [repository, setRepository] = useState<IsaRepository>('VMODEL')
  useEffect(() => { setFu(initialFu); setSection('overview'); setInstructionId(isaInstructions.find((item) => item.fu === initialFu)?.id ?? 'mem-read'); setSelectedField(null) }, [initialFu])
  const instruction = useMemo(() => isaInstructions.find((item) => item.id === instructionId) ?? isaInstructions[0], [instructionId])
  const selectInstruction = (item: IsaInstruction) => { setFu(item.fu); setInstructionId(item.id); setSelectedField(null); setSection('overview') }
  return <div className="isa-explorer"><div className="isa-hero"><span className="isa-eyebrow">LPU RTL · THREE-REPOSITORY EVIDENCE · 核查于 {isaCatalogReviewedAt}</span><h1>Unified ISA Explorer</h1><p>从 Macro 压缩到 FU 原生字，逐项查看位域、译码路径、目标队列和三仓库证据。</p></div><nav className="isa-section-nav" aria-label="ISA 页面">{sections.map((item) => <button key={item.id} className={section === item.id ? 'active' : ''} onClick={() => setSection(item.id)}>{item.label}</button>)}</nav>
    {section === 'overview' ? <div className="isa-main-grid"><aside className="isa-catalog-list"><span className="isa-eyebrow">FUNCTIONAL UNIT</span><div className="isa-tabs">{fus.map((item) => <button key={item} className={fu === item ? 'active' : ''} onClick={() => { setFu(item); setInstructionId(isaInstructions.find((entry) => entry.fu === item)?.id ?? 'mem-read'); setSelectedField(null) }}>{item}</button>)}</div><h3>{fu} Native ISA</h3>{isaInstructions.filter((item) => item.fu === fu).map((item) => <button className={`isa-instruction-link ${instruction.id === item.id ? 'active' : ''}`} key={item.id} onClick={() => selectInstruction(item)}><strong>{item.name}</strong><span>{item.width}</span><small>{item.status}</small></button>)}<button className="isa-action" onClick={() => setSection('macro')}>查看 Shared Macro →</button></aside><section className="isa-card"><NativeDetail instruction={instruction} selectedField={selectedField} setSelectedField={setSelectedField} onOpenArchitecture={onOpenArchitecture} /></section><aside className="isa-inspector"><span className="isa-eyebrow">SOURCE & VERSION</span><h3>仓库视图</h3><div className="isa-tabs vertical">{repoNames.map((item) => <button key={item} className={repository === item ? 'active' : ''} onClick={() => setRepository(item)}>{item}</button>)}</div>{isaVersions.map((entry) => entry.repo === repository && <div key={entry.repo} className="isa-version"><strong>{entry.repo}</strong><code>{entry.root}</code><span>{entry.branch} · {entry.head}</span><p>{entry.state}</p></div>)}</aside></div> : section === 'macro' ? <MacroView onOpenDecoder={onOpenDecoder} /> : section === 'matrix' ? <MatrixView onSelect={selectInstruction} /> : <DispatchView />}
  </div>
}
