import { useEffect, useMemo, useState } from 'react'
import type {
  HierarchyEdge,
  HierarchyNode,
  ModuleDefinition,
  PhysicalFunctionalBlock,
  RawConnection,
  SemanticInterface,
  Warning,
} from '../types'

interface SourceExcerpt {
  file: string
  absolutePath: string
  focusLine: number
  startLine: number
  lines: Array<{ number: number; text: string }>
}

interface Props {
  node: HierarchyNode | null
  definition: ModuleDefinition | null
  parentEdge: HierarchyEdge | null
  selectedInterface: SemanticInterface | null
  selectedRawConnection: RawConnection | null
  rawConnections: Map<string, RawConnection>
  relatedInterfaces: SemanticInterface[]
  warnings: Warning[]
  onSelectInterface: (id: string) => void
  onSelectRawConnection: (id: string | null) => void
  onSaveDescription: (moduleName: string, description: string) => Promise<void>
  physicalBlocks?: PhysicalFunctionalBlock[]
  onSelectPhysicalBlock?: (id: string) => void
}

type ModuleTab = 'overview' | 'ports' | 'interfaces' | 'source'

function widthLabel(raw: RawConnection) {
  if (raw.resolvedWidth !== null) return `${raw.resolvedWidth} bit`
  return raw.widthExpressions.length ? raw.widthExpressions.join(' / ') : '未静态解析'
}

function endpointLabel(endpoint: RawConnection['sourceEndpoints'][number]) {
  return `${endpoint.boundary ? 'scope_boundary' : endpoint.instanceName}.${endpoint.portName}`
}

function SourceViewer({ file, line }: { file: string; line: number | null }) {
  const [source, setSource] = useState<SourceExcerpt | null>(null)
  const [error, setError] = useState('')
  useEffect(() => {
    const controller = new AbortController()
    setSource(null)
    setError('')
    fetch(`/api/source?file=${encodeURIComponent(file)}&line=${line ?? 1}`, { signal: controller.signal })
      .then(async (response) => {
        if (!response.ok) throw new Error((await response.json()).error ?? '无法读取源码')
        return response.json()
      })
      .then(setSource)
      .catch((fetchError) => { if (fetchError.name !== 'AbortError') setError(fetchError.message) })
    return () => controller.abort()
  }, [file, line])
  if (error) return <div className="error-banner">{error}</div>
  if (!source) return <div className="inline-empty">正在读取本地源码片段…</div>
  return <>
    <div className="absolute-path">{source.absolutePath}</div>
    <pre className="source-code">{source.lines.map((sourceLine) => (
      <div key={sourceLine.number} className={sourceLine.number === source.focusLine ? 'focus-line' : ''}>
        <span>{String(sourceLine.number).padStart(4, ' ')}</span>{sourceLine.text || ' '}
      </div>
    ))}</pre>
  </>
}

function SignalInspector({ raw, onBack }: { raw: RawConnection; onBack: () => void }) {
  const [showSource, setShowSource] = useState(false)
  return (
    <aside className="inspector interface-inspector">
      <div className="inspector-heading signal-heading">
        <div className="eyebrow">SIGNAL INSPECTOR</div>
        <button className="back-link" onClick={onBack}>← 返回接口</button>
        <h2>{raw.signalName}</h2>
        <div className="heading-tags">
          <span className="evidence-badge source-backed">RTL CONNECTION</span>
          {raw.evidence.includes('continuous-assignment') && <span className="evidence-badge assignment">ASSIGN</span>}
        </div>
      </div>
      <div className="inspector-content">
        <section className="detail-section signal-facts">
          <div><span>Width</span><strong>{widthLabel(raw)}</strong></div>
          <div><span>Semantic group</span><strong>{raw.signalGroup?.name ?? 'Unclassified'}</strong></div>
          <div><span>Status</span><strong>{raw.connectionStatus}</strong></div>
        </section>
        <section className="detail-section">
          <h3>真实传输方向</h3>
          <div className="signal-direction-map">
            <div>{raw.sourceEndpoints.map((endpoint) => <code key={endpoint.id}>{endpointLabel(endpoint)} <small>({endpoint.portDirection})</small></code>)}</div>
            <b>→</b>
            <div>{raw.destinationEndpoints.map((endpoint) => <code key={endpoint.id}>{endpointLabel(endpoint)} <small>({endpoint.portDirection})</small></code>)}</div>
          </div>
          {raw.unresolvedEndpoints.length > 0 && <p className="needs-review-note">另有 {raw.unresolvedEndpoints.length} 个端点方向未解析。</p>}
        </section>
        <section className="detail-section">
          <h3>Connection Expression</h3>
          <code className="full-expression">{raw.connectionExpression || '/* unconnected */'}</code>
          <div className="source-location compact-location"><code>{raw.sourceFile}:{raw.line ?? '?'}</code></div>
          <button className="quiet-button source-jump" onClick={() => setShowSource((value) => !value)}>{showSource ? '收起源码' : '定位源码'}</button>
        </section>
        <section className="detail-section">
          <h3>端点与模块端口方向</h3>
          <table className="endpoint-table">
            <thead><tr><th>端点</th><th>模块端口方向</th><th>传输角色</th><th>位宽</th></tr></thead>
            <tbody>{[...raw.sourceEndpoints, ...raw.destinationEndpoints, ...raw.unresolvedEndpoints].map((endpoint) => (
              <tr key={endpoint.id}><td><code>{endpointLabel(endpoint)}</code></td><td>{endpoint.portDirection}</td><td>{endpoint.flow}</td><td>{endpoint.width ?? endpoint.widthExpression ?? '?'}</td></tr>
            ))}</tbody>
          </table>
        </section>
        {showSource && <section className="detail-section source-section"><SourceViewer file={raw.sourceFile} line={raw.line} /></section>}
      </div>
    </aside>
  )
}

function InterfaceInspector({
  item,
  rawConnections,
  onSelectRawConnection,
}: {
  item: SemanticInterface
  rawConnections: Map<string, RawConnection>
  onSelectRawConnection: (id: string | null) => void
}) {
  const groups = item.signalGroups.map((group) => ({
    ...group,
    signals: group.rawConnectionIds.map((id) => rawConnections.get(id)).filter(Boolean) as RawConnection[],
  }))
  return (
    <aside className="inspector interface-inspector">
      <div className="inspector-heading">
        <div className="eyebrow">INTERFACE INSPECTOR</div>
        <h2>{item.semanticName}</h2>
        <div className="heading-tags">
          <span className="evidence-badge source-backed">RTL 连接已确认</span>
          <span className={`evidence-badge ${item.semanticStatus === 'needs-review' ? 'needs-confirmation' : 'inferred'}`}>{item.semanticStatus}</span>
        </div>
      </div>
      <div className="inspector-content">
        <section className="detail-section interface-summary-grid">
          <div><span>Signals</span><strong>{item.signalCount}</strong></div>
          <div><span>Total width</span><strong>{item.totalWidth ?? '含未解析表达式'}</strong></div>
          <div><span>Direction</span><strong>{item.bidirectional ? '双向子通道' : '单向'}</strong></div>
          <div><span>Confidence</span><strong>{item.confidence}</strong></div>
        </section>
        <section className="detail-section">
          <h3>来源与目标</h3>
          <div className="interface-endpoints">
            <div><span>SOURCE</span>{item.sourceInstances.map((source) => <code key={source.id}>{source.boundary ? 'scope_boundary' : source.name}<small>{source.moduleName}</small></code>)}</div>
            <b>→</b>
            <div><span>DESTINATION</span>{item.destinationInstances.map((destination) => <code key={destination.id}>{destination.boundary ? 'scope_boundary' : destination.name}<small>{destination.moduleName}</small></code>)}</div>
          </div>
        </section>
        <section className="detail-section inference-note">
          <h3>证据边界</h3>
          <p><strong>连接事实：</strong>实例端口绑定与连续赋值。</p>
          <p><strong>语义名称：</strong>{item.classificationBasis}</p>
          {!item.manuallyConfirmed && <p className="needs-review-note">当前语义尚未人工确认，不代表 RTL 中存在同名物理总线。</p>}
        </section>
        <section className="detail-section signal-groups-section">
          <h3>信号语义分组</h3>
          {groups.map((group, groupIndex) => (
            <details key={group.id} open={groupIndex < 2 || group.id === 'handshake'}>
              <summary><span>{group.name}</span><b>{group.signals.length}</b></summary>
              <div className="group-signal-list">
                {group.signals.map((raw) => (
                  <button key={raw.id} onClick={() => onSelectRawConnection(raw.id)}>
                    <span><code>{raw.signalName}</code><small>{raw.sourceEndpoints.map(endpointLabel).join(', ')} → {raw.destinationEndpoints.map(endpointLabel).join(', ')}</small></span>
                    <b>{widthLabel(raw)}</b>
                  </button>
                ))}
              </div>
            </details>
          ))}
        </section>
        <section className="detail-section source-location">
          <h3>连接来源</h3>
          {item.sourceLocations.map((location) => <code key={`${location.file}:${location.line}`}>{location.file}:{location.line ?? '?'}</code>)}
        </section>
      </div>
    </aside>
  )
}

export default function Inspector({
  node,
  definition,
  parentEdge,
  selectedInterface,
  selectedRawConnection,
  rawConnections,
  relatedInterfaces,
  warnings,
  onSelectInterface,
  onSelectRawConnection,
  onSaveDescription,
  physicalBlocks = [],
  onSelectPhysicalBlock,
}: Props) {
  const [tab, setTab] = useState<ModuleTab>('overview')
  const [direction, setDirection] = useState('all')
  const [portQuery, setPortQuery] = useState('')
  const [draft, setDraft] = useState('')
  const [saving, setSaving] = useState(false)
  useEffect(() => setDraft(definition?.userDescription ?? ''), [definition?.name, definition?.userDescription])

  const visiblePorts = useMemo(() => {
    const query = portQuery.trim().toLowerCase()
    return (definition?.ports ?? []).filter((port) =>
      (direction === 'all' || port.direction === direction) &&
      (!query || `${port.name} ${port.dataType} ${port.widthExpression}`.toLowerCase().includes(query)))
  }, [definition, direction, portQuery])
  const relatedWarnings = useMemo(() => warnings.filter((warning) =>
    warning.file === definition?.file || warning.file === node?.sourceFile), [warnings, definition?.file, node?.sourceFile])

  if (selectedRawConnection) return <SignalInspector raw={selectedRawConnection} onBack={() => onSelectRawConnection(null)} />
  if (selectedInterface) return <InterfaceInspector item={selectedInterface} rawConnections={rawConnections} onSelectRawConnection={onSelectRawConnection} />
  if (!node) return <aside className="inspector empty-panel"><div className="empty-mark">⌁</div><h2>选择模块或接口</h2><p>模块显示定义信息；接口总线显示聚合信号；点击信号继续追溯真实连接表达式。</p></aside>

  const incoming = relatedInterfaces.filter((item) => item.destinationInstances.some((endpoint) => endpoint.id === node.id))
  const outgoing = relatedInterfaces.filter((item) => item.sourceInstances.some((endpoint) => endpoint.id === node.id))
  return (
    <aside className="inspector">
      <div className="inspector-heading">
        <div className="eyebrow">MODULE INSPECTOR</div>
        <h2>{node.name}</h2>
        <div className="module-definition-name">{node.moduleName}</div>
        <div className="path-chip" title={node.path}>{node.path}</div>
        <div className="heading-tags">
          <span className="tag definition">DEF</span>
          {node.generated && <span className="tag generated">GENERATE TEMPLATE [*]</span>}
          {node.unresolved && <span className="tag unresolved">BLACK BOX</span>}
        </div>
      </div>
      <nav className="inspector-tabs" aria-label="模块详情">
        {([
          ['overview', '概览'],
          ['ports', `端口 ${definition?.ports.length ?? 0}`],
          ['interfaces', `接口 ${relatedInterfaces.length}`],
          ['source', '源码'],
        ] as Array<[ModuleTab, string]>).map(([value, label]) => <button key={value} className={tab === value ? 'active' : ''} onClick={() => setTab(value)}>{label}</button>)}
      </nav>
      <div className="inspector-content">
        {tab === 'overview' && <>
          <section className="detail-section">
            <div className="section-title-row"><h3>功能说明</h3><span className={`evidence-badge ${definition?.description.status === 'source-backed' ? 'source-backed' : 'needs-confirmation'}`}>{definition?.description.status === 'source-backed' ? 'RTL 注释' : '待确认'}</span></div>
            <p className="description-text">{definition?.description.text || '未找到可引用的 RTL 注释。'}</p>
          </section>
          <section className="detail-section">
            <div className="section-title-row"><h3>人工补充</h3><span className="save-location">独立 metadata</span></div>
            <textarea value={draft} onChange={(event) => setDraft(event.target.value)} placeholder="补充经过人工确认的模块职责；不会写回 RTL。" rows={4} />
            <button className="primary-button compact" disabled={!definition || saving} onClick={async () => { if (!definition) return; setSaving(true); try { await onSaveDescription(definition.name, draft) } finally { setSaving(false) } }}>{saving ? '保存中…' : '保存说明'}</button>
          </section>
          <section className="detail-section stats-grid">
            <div><span>输入</span><strong>{definition?.ports.filter((port) => port.direction === 'input').length ?? 0}</strong></div>
            <div><span>输出</span><strong>{definition?.ports.filter((port) => port.direction === 'output').length ?? 0}</strong></div>
            <div><span>参数</span><strong>{definition?.parameters.length ?? 0}</strong></div>
            <div><span>子实例</span><strong>{definition?.instances.length ?? 0}</strong></div>
          </section>
          {definition?.parameters.length ? <section className="detail-section"><h3>参数</h3><div className="parameter-list">{definition.parameters.map((parameter) => <div key={parameter.name} className="parameter-row"><code>{parameter.name}</code><span title={parameter.default ?? ''}>{parameter.resolvedDefault ?? parameter.default ?? '—'}</span></div>)}</div></section> : null}
          <section className="detail-section source-location"><h3>定义位置</h3><code>{definition?.file ?? node.sourceFile}:{definition?.line ?? node.line}</code>{node.generateContext && <p className="generate-context">模板条件：{node.generateContext}</p>}</section>
          {physicalBlocks.length > 0 && <section className="detail-section rtl-to-physical"><h3>Physical Architecture Mapping</h3><p>该 RTL symbolic instance 映射到以下功能块：</p>{physicalBlocks.map((block) => <button key={block.id} onClick={() => onSelectPhysicalBlock?.(block.id)}><span>{block.displayName}<small>{block.regionId} · {block.instanceCountExpression}</small></span><b>OPEN</b></button>)}</section>}
          {relatedWarnings.length > 0 && <section className="detail-section warning-section"><h3>解析告警</h3>{relatedWarnings.slice(0, 8).map((warning, index) => <div key={`${warning.code}-${index}`} className="warning-item"><code>{warning.code}</code><span>{warning.message}</span></div>)}</section>}
        </>}
        {tab === 'ports' && <section className="ports-section">
          <div className="filter-row"><select value={direction} onChange={(event) => setDirection(event.target.value)}><option value="all">全部方向</option><option value="input">Input</option><option value="output">Output</option><option value="inout">Inout</option><option value="ref">Ref</option></select><input value={portQuery} onChange={(event) => setPortQuery(event.target.value)} placeholder="筛选端口…" /></div>
          <div className="port-table-wrap"><table className="port-table"><thead><tr><th>端口</th><th>方向</th><th>位宽</th><th>类型</th></tr></thead><tbody>{visiblePorts.map((port) => <tr key={`${port.name}-${port.line}`}><td><code>{port.name}</code></td><td><span className={`direction ${port.direction}`}>{port.direction}</span></td><td title={port.widthExpression}>{port.width ?? port.widthExpression}</td><td title={port.raw}>{port.dataType}</td></tr>)}</tbody></table></div>
        </section>}
        {tab === 'interfaces' && <section className="module-interface-list">
          <h3>Incoming Interfaces</h3>{incoming.length ? incoming.map((item) => <button key={`in-${item.id}`} onClick={() => onSelectInterface(item.id)}><span>{item.semanticName}<small>{item.signalCount} signals · {item.semanticStatus}</small></span><b>IN</b></button>) : <div className="inline-empty">当前层级未识别到输入接口。</div>}
          <h3>Outgoing Interfaces</h3>{outgoing.length ? outgoing.map((item) => <button key={`out-${item.id}`} onClick={() => onSelectInterface(item.id)}><span>{item.semanticName}<small>{item.signalCount} signals · {item.semanticStatus}</small></span><b>OUT</b></button>) : <div className="inline-empty">当前层级未识别到输出接口。</div>}
          <h3>实例端口映射</h3>{parentEdge ? <div className="connection-list">{parentEdge.connections.map((connection, index) => <div key={`${connection.port}-${index}`} className="connection-card"><div className="connection-card-head"><code>.{connection.port ?? `#${connection.positionalIndex}`}</code><span className={`direction ${connection.direction}`}>{connection.direction}</span></div><code className="signal-expression">{connection.expression || '/* unconnected */'}</code><div className="connection-meta"><span>{connection.kind}</span><span>{connection.width ?? connection.widthExpression ?? '?'} bit</span><span>line {connection.line ?? '?'}</span></div></div>)}</div> : <div className="inline-empty">顶层定义没有父实例端口映射。</div>}
        </section>}
        {tab === 'source' && <section className="source-section"><SourceViewer file={node.sourceFile} line={node.line ?? definition?.line ?? 1} /></section>}
      </div>
    </aside>
  )
}
