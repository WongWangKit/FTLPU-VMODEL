import { useEffect, useMemo, useState } from 'react'
import { buildHardwareQuickSpec } from '../lib/hardware-spec'
import type { ArchitectureDrillInterface, ArchitectureDrillNode, ModuleDefinition, PhysicalFunctionalBlock, PhysicalInterface, RawConnection } from '../types'

interface SourceExcerpt {
  absolutePath: string
  focusLine: number
  lines: Array<{ number: number; text: string }>
}

interface Props {
  block: PhysicalFunctionalBlock | null
  selectedInterface: PhysicalInterface | null
  architectureNode: ArchitectureDrillNode | null
  selectedDrillInterface: ArchitectureDrillInterface | null
  drillNodes: Map<string, ArchitectureDrillNode>
  selectedRawConnection: RawConnection | null
  blocks: Map<string, PhysicalFunctionalBlock>
  rawConnections: Map<string, RawConnection>
  modules: Map<string, ModuleDefinition>
  onSelectInterface: (id: string) => void
  onSelectRawConnection: (id: string | null) => void
  onLocateRtlNode: (id: string) => void
}

function SourceViewer({ file, line }: { file: string; line: number | null }) {
  const [source, setSource] = useState<SourceExcerpt | null>(null)
  const [error, setError] = useState('')
  useEffect(() => {
    const controller = new AbortController()
    setSource(null); setError('')
    fetch(`/api/source?file=${encodeURIComponent(file)}&line=${line ?? 1}`, { signal: controller.signal })
      .then(async (response) => { if (!response.ok) throw new Error((await response.json()).error ?? '无法读取源码'); return response.json() })
      .then(setSource)
      .catch((fetchError) => { if (fetchError.name !== 'AbortError') setError(fetchError.message) })
    return () => controller.abort()
  }, [file, line])
  if (error) return <div className="error-banner">{error}</div>
  if (!source) return <div className="inline-empty">正在读取本地源码片段…</div>
  return <><div className="absolute-path">{source.absolutePath}</div><pre className="source-code">{source.lines.map((item) => <div key={item.number} className={item.number === source.focusLine ? 'focus-line' : ''}><span>{String(item.number).padStart(4, ' ')}</span>{item.text || ' '}</div>)}</pre></>
}

function endpointName(endpoint: RawConnection['sourceEndpoints'][number]) {
  return `${endpoint.boundary ? 'scope_boundary' : endpoint.instanceName}.${endpoint.portName}`
}

function widthLabel(raw: RawConnection) {
  return raw.resolvedWidth !== null ? `${raw.resolvedWidth} bit` : raw.widthExpressions.join(' / ') || 'expression'
}

function Evidence({ value }: { value: string }) {
  return <span className={`status-pill status-${value}`}>{value}</span>
}

function PhysicalSignalInspector({ raw, onBack }: { raw: RawConnection; onBack: () => void }) {
  const [showSource, setShowSource] = useState(true)
  return <aside className="inspector interface-inspector physical-inspector">
    <div className="inspector-heading signal-heading"><div className="eyebrow">RTL SIGNAL</div><button className="back-link" onClick={onBack}>← 返回物理接口</button><h2>{raw.signalName}</h2><div className="heading-tags"><Evidence value={raw.connectionStatus === 'rtl-confirmed' ? 'rtl-confirmed' : 'needs-review'} />{raw.evidence.includes('continuous-assignment') && <span className="evidence-badge assignment">ASSIGN</span>}</div></div>
    <div className="inspector-content">
      <section className="detail-section signal-facts"><div><span>Width</span><strong>{widthLabel(raw)}</strong></div><div><span>Group</span><strong>{raw.signalGroup?.name ?? 'Unclassified'}</strong></div><div><span>Status</span><strong>{raw.connectionStatus}</strong></div></section>
      <section className="detail-section"><h3>RTL 端点</h3><div className="signal-direction-map"><div>{raw.sourceEndpoints.map((endpoint) => <code key={endpoint.id}>{endpointName(endpoint)} <small>({endpoint.portDirection})</small></code>)}</div><b>→</b><div>{raw.destinationEndpoints.map((endpoint) => <code key={endpoint.id}>{endpointName(endpoint)} <small>({endpoint.portDirection})</small></code>)}</div></div>{raw.connectionStatus !== 'rtl-confirmed' && <p className="needs-review-note">该单条记录只解析到一侧端点；完整物理接口可能通过同名向量切片或显式处理阶段聚合。</p>}</section>
      <section className="detail-section"><h3>Connection Expression</h3><code className="full-expression">{raw.connectionExpression}</code><div className="source-location compact-location"><code>{raw.sourceFile}:{raw.line ?? '?'}</code></div><button className="quiet-button source-jump" onClick={() => setShowSource((value) => !value)}>{showSource ? '收起源码' : '定位源码'}</button></section>
      {showSource && <section className="detail-section source-section"><SourceViewer file={raw.sourceFile} line={raw.line} /></section>}
    </div>
  </aside>
}

function PhysicalInterfaceInspector({ item, blocks, rawConnections, onSelectRawConnection }: Pick<Props, 'blocks' | 'rawConnections' | 'onSelectRawConnection'> & { item: PhysicalInterface }) {
  const source = blocks.get(item.sourceBlockId)
  const destination = blocks.get(item.destinationBlockId)
  const groups = item.signalGroups.map((group) => ({ ...group, signals: group.rawConnectionIds.map((id) => rawConnections.get(id)).filter(Boolean) as RawConnection[] }))
  return <aside className="inspector interface-inspector physical-inspector">
    <div className="inspector-heading"><div className="eyebrow">PHYSICAL INTERFACE BUS</div><h2>{item.name}</h2><div className="heading-tags"><Evidence value={item.evidenceStatus} /><Evidence value={item.topologyStatus} /><span className={`plane-badge ${item.plane}`}>{item.plane.toUpperCase()} PLANE</span></div></div>
    <div className="inspector-content">
      <section className="detail-section interface-summary-grid"><div><span>Raw links</span><strong>{item.signalCount}</strong></div><div><span>Resolved width</span><strong>{item.totalResolvedWidth ?? 'partial'}</strong></div><div><span>Direction</span><strong>{item.direction}</strong></div><div><span>Path</span><strong>{item.pathKind}</strong></div></section>
      <section className="detail-section"><h3>Functional endpoints</h3><div className="interface-endpoints"><div><span>SOURCE</span><code>{source?.displayName}<small>{source?.rtlMappings.map((mapping) => mapping.moduleName).filter(Boolean).join(', ')}</small></code></div><b>→</b><div><span>DESTINATION</span><code>{destination?.displayName}<small>{destination?.rtlMappings.map((mapping) => mapping.moduleName).filter(Boolean).join(', ')}</small></code></div></div></section>
      {item.pathKind === 'processed-path' && <section className="detail-section processed-path-warning"><h3>包含真实处理逻辑</h3><p>该物理接口经过 merge/conflict 逻辑，不被建模成两个 RTL 实例之间的直接连线。</p></section>}
      <section className="detail-section inference-note"><h3>证据边界</h3><p><strong>接口聚合：</strong>{item.classificationBasis}</p>{item.notes.map((note) => <p key={note}>{note}</p>)}</section>
      <section className="detail-section physical-rtl-path"><h3>完整 RTL 路径</h3>{item.rtlPath.map((step, index) => <div key={`${step.file}:${step.line}:${index}`}><span>{index + 1}</span><div><strong>{step.label}</strong><small>{step.kind}</small><code>{step.file}:{step.line}</code></div></div>)}</section>
      <section className="detail-section signal-groups-section"><h3>信号分组</h3>{groups.map((group, index) => <details key={group.id} open={index < 2}><summary><span>{group.name}</span><b>{group.signals.length}</b></summary><div className="group-signal-list">{group.signals.map((raw) => <button key={raw.id} onClick={() => onSelectRawConnection(raw.id)}><span><code>{raw.signalName}</code><small>{raw.sourceEndpoints.map(endpointName).join(', ') || 'partial source'} → {raw.destinationEndpoints.map(endpointName).join(', ') || 'partial destination'}</small></span><b>{widthLabel(raw)}</b></button>)}</div></details>)}</section>
    </div>
  </aside>
}

function DrillInterfaceInspector({ item, nodes, rawConnections, onSelectRawConnection }: { item: ArchitectureDrillInterface; nodes: Map<string, ArchitectureDrillNode>; rawConnections: Map<string, RawConnection>; onSelectRawConnection: (id: string | null) => void }) {
  const source = nodes.get(item.sourceNodeId)
  const destination = nodes.get(item.destinationNodeId)
  const groups = item.signalGroups.map((group) => ({ ...group, signals: group.rawConnectionIds.map((id) => rawConnections.get(id)).filter(Boolean) as RawConnection[] }))
  return <aside className="inspector interface-inspector physical-inspector drill-inspector">
    <div className="inspector-heading"><div className="eyebrow">SEMANTIC ARCHITECTURE BUS</div><h2>{item.name}</h2><div className="heading-tags"><Evidence value={item.confidenceStatus} /><span className={`plane-badge ${item.plane}`}>{item.plane.toUpperCase()} PLANE</span></div></div>
    <div className="inspector-content">
      <section className="detail-section interface-summary-grid"><div><span>Category</span><strong>{item.category}</strong></div><div><span>Direction</span><strong>{item.direction}</strong></div><div><span>Raw signals</span><strong>{item.signalCount}</strong></div><div><span>Resolved width</span><strong>{item.totalResolvedWidth ?? 'partial'}</strong></div></section>
      <section className="detail-section"><h3>Architecture endpoints</h3><div className="interface-endpoints"><div><span>SOURCE</span><code>{source?.displayName ?? item.sourceNodeId}<small>{source?.rtlModuleRefs.join(', ')}</small></code></div><b>→</b><div><span>DESTINATION</span><code>{destination?.displayName ?? item.destinationNodeId}<small>{destination?.rtlModuleRefs.join(', ')}</small></code></div></div></section>
      <section className="detail-section inference-note"><h3>接口语义</h3><p>{item.semanticDescription}</p>{item.notes.map((note) => <p key={note}>{note}</p>)}</section>
      <section className="detail-section signal-groups-section"><h3>聚合端口与信号</h3>{groups.length ? groups.map((group, index) => <details key={group.id} open={index < 2}><summary><span>{group.name}</span><b>{group.signals.length}</b></summary><div className="group-signal-list">{group.signals.map((raw) => <button key={raw.id} onClick={() => onSelectRawConnection(raw.id)}><span><code>{raw.signalName}</code><small>{raw.sourceEndpoints.map(endpointName).join(', ') || 'partial source'} → {raw.destinationEndpoints.map(endpointName).join(', ') || 'partial destination'}</small></span><b>{widthLabel(raw)}</b></button>)}</div></details>) : <p className="needs-review-note">当前语义接口由 RTL 结构或过程块确认，但快照解析器尚未把过程内赋值还原为逐条 raw net。</p>}</section>
      {item.sourceEvidence.map((evidence, index) => <section className="detail-section" key={`${evidence.file}:${evidence.line}:${index}`}><h3>Source evidence</h3><p>{evidence.basis}</p><code>{evidence.file}:{evidence.line ?? '?'}</code><SourceViewer file={evidence.file} line={evidence.line} /></section>)}
    </div>
  </aside>
}

function DrillNodeInspector({ node, onLocateRtlNode }: { node: ArchitectureDrillNode; onLocateRtlNode: (id: string) => void }) {
  const spec = buildHardwareQuickSpec(node)
  return <aside className="inspector physical-inspector drill-inspector">
    <div className="inspector-heading"><div className="eyebrow">SPECIFICATION · {node.architectureLevel.toUpperCase()}</div><h2>{node.displayName}</h2><div className="heading-tags"><Evidence value={node.confidenceStatus} />{node.tags.map((tag) => <span className="evidence-badge" key={`${tag.label}:${tag.value}`}>{tag.label}: {tag.value}</span>)}</div></div>
    <div className="inspector-content">
      <section className="detail-section inspector-quick-spec"><span>{spec.primaryLabel}</span><strong>{spec.primaryValue}</strong>{spec.secondary.map((fact) => <small key={fact.label}>{fact.label}: {fact.value}</small>)}{spec.needsReview && <p className="needs-review-note">无法静态求值的规格保持参数表达式或 Needs Review，不补造数值。</p>}</section>
      <section className="detail-section"><h3>硬件职责</h3><p className="description-text">{node.description}</p></section>
      <details className="detail-section advanced-evidence"><summary>高级 RTL 证据与参数</summary>
        <section className="interface-summary-grid"><div><span>Level</span><strong>{node.architectureLevel}</strong></div><div><span>Inside</span><strong>{node.childIds.length}</strong></div><div><span>Interfaces</span><strong>{node.interfaceIds.length}</strong></div><div><span>Source kind</span><strong>{node.sourceKind}</strong></div></section>
        {node.selector && <section><h3>Generate / parameter selector</h3><code className="full-expression">{node.selector}</code></section>}
        {node.parameterRefs.length > 0 && <section><h3>RTL-backed parameters</h3><div className="physical-fact-list">{node.parameterRefs.map((item) => <div key={`${item.name}:${item.expression}`}><span><strong>{item.name}</strong><small>{item.expression} · {item.source.file}:{item.source.line ?? '?'}</small></span><b>{item.value ?? 'expr'}</b><Evidence value={item.evidenceStatus} /></div>)}</div></section>}
        <section className="rtl-mapping-list"><h3>Architecture → RTL mapping</h3>{node.rtlInstanceRefs.map((mapping, index) => <article key={`${mapping.moduleName}:${index}`}><div><span>{mapping.moduleName}</span></div><code>{mapping.rtlPath ?? 'symbolic / generated structure'}</code><p>{mapping.instanceSelector}</p>{mapping.rtlNodeId && <button className="quiet-button" onClick={() => onLocateRtlNode(mapping.rtlNodeId!)}>在 RTL Hierarchy 中定位</button>}</article>)}</section>
        {node.sourceEvidence.map((evidence, index) => <section className="source-section" key={`${evidence.file}:${evidence.line}:${index}`}><h3>Source evidence</h3><p>{evidence.basis}</p><div className="heading-tags"><Evidence value={evidence.evidenceStatus} /></div><SourceViewer file={evidence.file} line={evidence.line} /></section>)}
      </details>
    </div>
  </aside>
}

function BlockInspector({ block, modules, onSelectInterface, onLocateRtlNode }: Pick<Props, 'modules' | 'onSelectInterface' | 'onLocateRtlNode'> & { block: PhysicalFunctionalBlock }) {
  const [tab, setTab] = useState<'overview' | 'structure' | 'rtl' | 'interfaces'>('overview')
  useEffect(() => setTab('overview'), [block.id])
  const definitions = block.definitionNames.map((name) => modules.get(name)).filter(Boolean) as ModuleDefinition[]
  return <aside className="inspector physical-inspector">
    <div className="inspector-heading"><div className="eyebrow">FUNCTIONAL BLOCK</div><h2>{block.displayName}</h2><div className="module-definition-name">{block.kind.toUpperCase()} · {block.regionId.toUpperCase()}</div><div className="heading-tags"><Evidence value={block.placementStatus} />{!block.enabledByDefault && <span className="evidence-badge needs-confirmation">INACTIVE DEFAULT</span>}</div></div>
    <nav className="inspector-tabs">{([['overview', '概览'], ['structure', '结构'], ['rtl', `RTL ${block.rtlMappings.length}`], ['interfaces', `接口 ${block.inputInterfaceIds.length + block.outputInterfaceIds.length}`]] as const).map(([value, label]) => <button key={value} className={tab === value ? 'active' : ''} onClick={() => setTab(value)}>{label}</button>)}</nav>
    <div className="inspector-content">
      {tab === 'overview' && <><section className="detail-section"><h3>硬件职责</h3><p className="description-text">{block.function}</p></section><section className="detail-section interface-summary-grid"><div><span>RTL instances</span><strong>{block.instanceCount}</strong></div><div><span>Region</span><strong>{block.regionId}</strong></div><div><span>Inputs</span><strong>{block.inputInterfaceIds.length}</strong></div><div><span>Outputs</span><strong>{block.outputInterfaceIds.length}</strong></div></section><section className="detail-section inference-note"><h3>空间映射</h3><p>{block.placementBasis}</p><p className="needs-review-note">功能拓扑位置不等价于后端 floorplan 坐标。</p></section>{block.parameters.length > 0 && <section className="detail-section"><h3>关键实例参数</h3><div className="parameter-list">{block.parameters.map((parameter) => <div className="parameter-row" key={parameter}><code>{parameter}</code></div>)}</div></section>}</>}
      {tab === 'structure' && <><section className="detail-section"><h3>RTL-backed dimensions</h3><div className="physical-fact-list">{(block.structure.facts ?? []).map((fact) => <div key={fact.label}><span><strong>{fact.label}</strong><small>{fact.expression}</small></span><b>{fact.value ?? 'expr'}</b><Evidence value={fact.evidenceStatus} /></div>)}</div></section>{block.structure.namingNote && <section className="detail-section inference-note"><h3>命名边界</h3><p>{block.structure.namingNote}</p></section>}</>}
      {tab === 'rtl' && <section className="detail-section rtl-mapping-list"><h3>Architecture → RTL mapping</h3>{block.rtlMappings.map((mapping, index) => <article key={`${mapping.rtlNodeId}:${index}`}><div><span>{mapping.moduleName}</span><Evidence value={mapping.evidenceStatus} /></div><code>{mapping.rtlPath}</code><p>{mapping.instanceSelector} · cardinality {mapping.cardinality}</p><small>{mapping.basis}</small>{mapping.source && <code>{mapping.source.file}:{mapping.source.line ?? '?'}</code>}{mapping.rtlNodeId && <button className="quiet-button" onClick={() => onLocateRtlNode(mapping.rtlNodeId!)}>在 RTL Hierarchy 中定位</button>}</article>)}<h3>Definitions</h3>{definitions.map((definition) => <div className="definition-location" key={definition.id}><strong>{definition.name}</strong><code>{definition.file}:{definition.line}</code></div>)}</section>}
      {tab === 'interfaces' && <section className="module-interface-list"><h3>Incoming</h3>{block.inputInterfaceIds.map((id) => <button key={id} onClick={() => onSelectInterface(id)}><span>{id.split(':').slice(-3).join(' · ')}</span><b>IN</b></button>)}<h3>Outgoing</h3>{block.outputInterfaceIds.map((id) => <button key={id} onClick={() => onSelectInterface(id)}><span>{id.split(':').slice(-3).join(' · ')}</span><b>OUT</b></button>)}</section>}
    </div>
  </aside>
}

export default function PhysicalInspector({ block, selectedInterface, architectureNode, selectedDrillInterface, drillNodes, selectedRawConnection, blocks, rawConnections, modules, onSelectInterface, onSelectRawConnection, onLocateRtlNode }: Props) {
  const interfaceForRaw = useMemo(() => selectedRawConnection ? null : selectedInterface, [selectedRawConnection, selectedInterface])
  if (selectedRawConnection) return <PhysicalSignalInspector raw={selectedRawConnection} onBack={() => onSelectRawConnection(null)} />
  if (selectedDrillInterface) return <DrillInterfaceInspector item={selectedDrillInterface} nodes={drillNodes} rawConnections={rawConnections} onSelectRawConnection={onSelectRawConnection} />
  if (interfaceForRaw) return <PhysicalInterfaceInspector item={interfaceForRaw} blocks={blocks} rawConnections={rawConnections} onSelectRawConnection={onSelectRawConnection} />
  if (architectureNode) return <DrillNodeInspector node={architectureNode} onLocateRtlNode={onLocateRtlNode} />
  if (block) return <BlockInspector block={block} modules={modules} onSelectInterface={onSelectInterface} onLocateRtlNode={onLocateRtlNode} />
  return <aside className="inspector empty-panel"><div className="empty-mark">⌁</div><h2>选择功能块或接口</h2><p>功能块显示物理区域、RTL 映射和真实参数；接口总线显示完整信号与源码证据。</p></aside>
}
