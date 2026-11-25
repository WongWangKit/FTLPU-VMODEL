import { useEffect, useMemo, useState } from 'react'
import { signalGroupOrder, signalSemanticPresentation } from '../lib/signal-presentation'
import type {
  ArchitectureDrillInterface,
  ArchitectureDrillNode,
  HierarchyNode,
  PhysicalFunctionalBlock,
  PhysicalInterface,
  RawConnection,
} from '../types'

type FlowDirection = 'forward' | 'reverse' | 'bidirectional' | 'unknown'

interface EndpointView {
  id: string
  name: string
  region: string
  moduleNames: string[]
  instanceNames: string[]
  evidence: string
  category: 'compute' | 'control' | 'storage' | 'interface'
  tokens: Set<string>
  onOpen: () => void
}

function endpointCategory(value: string): EndpointView['category'] {
  const identity = value.toLowerCase()
  if (/(fifo|queue|buffer|storage|store|register|imem|instruction-memory|reservoir|elastic)/.test(identity)) return 'storage'
  if (/(interface|stream|port|boundary|ingress|egress)/.test(identity)) return 'interface'
  if (/(control|router|dispatch|scheduler|decoder|select|coordinator|frontend|reassembly|distributor|source|adapter|retirement|branch|fault|status)/.test(identity)) return 'control'
  if (/(mem|mxm|sxm|vxm|execution|compute|array|tile|matrix|vector|builder|transpose|permutation)/.test(identity)) return 'compute'
  return 'control'
}

function physicalRegionLabel(regionId: PhysicalFunctionalBlock['regionId']) {
  if (regionId === 'west') return 'West Hemisphere'
  if (regionId === 'east') return 'East Hemisphere'
  if (regionId === 'central') return 'Central / On-chip Bisection'
  return 'Control Plane'
}

interface Props {
  physicalInterface: PhysicalInterface | null
  drillInterface: ArchitectureDrillInterface | null
  blocks: Map<string, PhysicalFunctionalBlock>
  drillNodes: Map<string, ArchitectureDrillNode>
  hierarchyNodes: Map<string, HierarchyNode>
  rawConnections: Map<string, RawConnection>
  onBack: () => void
  onOpenPhysicalEndpoint: (id: string) => void
  onOpenDrillEndpoint: (id: string) => void
  onLocateRtlNode: (id: string) => void
}

interface SourceResponse {
  absolutePath: string
  focusLine: number
  lines: Array<{ number: number; text: string }>
}

function unique(values: Array<string | null | undefined>) {
  return [...new Set(values.filter((value): value is string => Boolean(value)))]
}

function tokenSet(values: Array<string | null | undefined>) {
  return new Set(unique(values).map((value) => value.toLowerCase()))
}

function endpointMatches(endpoint: RawConnection['sourceEndpoints'][number], tokens: Set<string>) {
  // instanceId is a full hierarchy path and therefore contains ancestor names
  // such as lpu_top.  Using it here makes a deep queue endpoint spuriously
  // match both architecture sides.  Module and local instance identity are
  // the actual endpoint evidence for this direction decision.
  const values = [endpoint.moduleName, endpoint.instanceName].filter(Boolean).map((value) => value.toLowerCase())
  return values.some((value) => tokens.has(value) || [...tokens].some((token) => value.includes(token) || token.includes(value)))
}

function signalDirection(raw: RawConnection, leftTokens: Set<string>, rightTokens: Set<string>): FlowDirection {
  if ([...raw.sourceEndpoints, ...raw.destinationEndpoints].some((endpoint) => endpoint.portDirection === 'inout')) return 'bidirectional'
  let forward = 0
  let reverse = 0
  for (const endpoint of raw.sourceEndpoints) {
    const left = endpointMatches(endpoint, leftTokens)
    const right = endpointMatches(endpoint, rightTokens)
    if (left) forward += 1
    if (right) reverse += 1
  }
  for (const endpoint of raw.destinationEndpoints) {
    const left = endpointMatches(endpoint, leftTokens)
    const right = endpointMatches(endpoint, rightTokens)
    if (right) forward += 1
    if (left) reverse += 1
  }
  if (forward > reverse) return 'forward'
  if (reverse > forward) return 'reverse'
  if (forward > 0 && reverse > 0) return 'bidirectional'
  return 'unknown'
}

function directionLabel(direction: FlowDirection) {
  if (direction === 'forward') return 'Source → Destination'
  if (direction === 'reverse') return 'Destination → Source'
  if (direction === 'bidirectional') return 'Bidirectional / inout'
  return 'Needs Review'
}

function semanticLabel(name: string) {
  const lower = name.trim().toLowerCase()
  if (lower === 'data' || lower === 'payload') return 'Program Word Payload'
  if (lower === 'command' || lower === 'instruction') return 'Command / Instruction'
  if (lower === 'fault' || lower === 'status') return 'Status / Fault'
  if (lower === 'ready') return 'Ready / Backpressure'
  if (/strb|strobe|mask/.test(lower)) return 'Word Strobe / Mask'
  if (/scope|destination|routing/.test(lower)) return 'Scope / 13-bit Destination / iMEM Address'
  if (/target|address|queue/.test(lower)) return 'Address / Legacy Routing'
  return name
}

function signalAttribute(raw: RawConnection) {
  const text = `${raw.signalName} ${raw.connectionExpression}`.toLowerCase()
  if (/(fault|error|conflict)/.test(text)) return 'Fault'
  if (/(data|payload|result|value)/.test(text)) return 'Data'
  if (/(instruction|command|opcode)/.test(text)) return 'Instruction'
  if (/(cycle|schedule|deadline)/.test(text)) return 'Schedule'
  if (/(valid|ready|enable|request|ack)/.test(text)) return 'Handshake'
  if (/(address|row|column|bank|tile|select)/.test(text)) return 'Address / Control'
  return 'Needs Review'
}

function widthLabel(raw: RawConnection) {
  if (raw.resolvedWidth !== null) return raw.resolvedWidth === 1 ? '1 bit' : `[${raw.resolvedWidth - 1}:0] · ${raw.resolvedWidth} bit`
  return raw.widthExpressions.join(' / ') || 'unresolved width'
}

function endpointLabel(endpoint: RawConnection['sourceEndpoints'][number]) {
  return `${endpoint.boundary ? 'scope_boundary' : endpoint.instanceName}.${endpoint.portName}`
}

function SourceSnippet({ file, line }: { file: string; line: number | null }) {
  const [source, setSource] = useState<SourceResponse | null>(null)
  const [error, setError] = useState('')
  useEffect(() => {
    const controller = new AbortController()
    setSource(null)
    setError('')
    fetch(`/api/source?file=${encodeURIComponent(file)}&line=${line ?? 1}`, { signal: controller.signal })
      .then(async (response) => {
        const body = await response.json()
        if (!response.ok) throw new Error(body.error ?? `HTTP ${response.status}`)
        setSource(body)
      })
      .catch((nextError) => { if (nextError.name !== 'AbortError') setError(nextError.message) })
    return () => controller.abort()
  }, [file, line])
  if (error) return <div className="needs-review-note">{error}</div>
  if (!source) return <div className="inline-empty">正在读取只读 RTL 源码片段…</div>
  return <div className="bus-source-snippet"><code>{source.absolutePath}</code><pre>{source.lines.map((item) => <div key={item.number} className={item.number === source.focusLine ? 'focus-line' : ''}><span>{item.number}</span>{item.text || ' '}</div>)}</pre></div>
}

function EndpointCard({ side, endpoint }: { side: 'source' | 'destination'; endpoint: EndpointView }) {
  return <article className={`bus-endpoint-card endpoint-${side} category-${endpoint.category} ${endpoint.evidence === 'architecture-inferred' || endpoint.evidence === 'needs-review' ? 'evidence-secondary' : ''}`}>
    <span>{side === 'source' ? 'SOURCE ENDPOINT / 源端' : 'DESTINATION ENDPOINT / 目标端'}</span>
    <h2>{endpoint.name}</h2>
    <p>{endpoint.region}</p>
    <button onClick={endpoint.onOpen}>进入功能架构 →</button>
  </article>
}

export default function BusDetailView({ physicalInterface, drillInterface, blocks, drillNodes, hierarchyNodes, rawConnections, onBack, onOpenPhysicalEndpoint, onOpenDrillEndpoint, onLocateRtlNode }: Props) {
  const item = physicalInterface ?? drillInterface
  const rawIds = item?.rawConnectionIds ?? []
  const raws = useMemo(() => rawIds.map((id) => rawConnections.get(id)).filter(Boolean) as RawConnection[], [rawIds, rawConnections])
  const [signalQuery, setSignalQuery] = useState('')
  const [selectedSignalId, setSelectedSignalId] = useState<string | null>(null)
  const [expandedGroups, setExpandedGroups] = useState<Set<string>>(new Set())
  const [showSource, setShowSource] = useState(false)
  const signalPresentations = useMemo(() => new Map(raws.map((raw) => [raw.id, signalSemanticPresentation(raw)])), [raws])

  const endpointViews = useMemo(() => {
    if (physicalInterface) {
      const left = blocks.get(physicalInterface.sourceBlockId)
      const right = blocks.get(physicalInterface.destinationBlockId)
      const make = (block: PhysicalFunctionalBlock | undefined, side: 'source' | 'destination'): EndpointView => {
        const modules = unique([...(block?.definitionNames ?? []), ...(block?.rtlMappings.map((mapping) => mapping.moduleName) ?? [])])
        const instances = unique(block?.rtlMappings.flatMap((mapping) => [mapping.instanceName, mapping.instanceSelector]) ?? [])
        return {
          id: block?.id ?? `${side}:unknown`,
          name: block?.displayName ?? 'Unresolved architecture endpoint',
          region: block ? `${physicalRegionLabel(block.regionId)} · ${block.kind.toUpperCase()} Block` : 'Needs Review',
          moduleNames: modules,
          instanceNames: instances,
          evidence: block?.placementStatus ?? 'needs-review',
          category: endpointCategory(`${block?.kind ?? ''} ${block?.displayName ?? ''}`),
          tokens: tokenSet([block?.id, block?.displayName, block?.shortName, ...modules, ...instances]),
          onOpen: () => block && onOpenPhysicalEndpoint(block.id),
        }
      }
      return { left: make(left, 'source'), right: make(right, 'destination') }
    }
    const make = (node: ArchitectureDrillNode | undefined, fallback: string): EndpointView => {
      const modules = unique([...(node?.rtlModuleRefs ?? []), ...(node?.rtlInstanceRefs.map((mapping) => mapping.moduleName) ?? [])])
      const instances = unique(node?.rtlInstanceRefs.flatMap((mapping) => [mapping.rtlPath, mapping.instanceSelector]) ?? [])
      return {
        id: node?.id ?? fallback,
        name: node?.displayName ?? fallback,
        region: node ? `${node.architectureLevel.toUpperCase()} · ${node.nodeType}` : 'NEEDS REVIEW',
        moduleNames: modules,
        instanceNames: instances,
        evidence: node?.confidenceStatus ?? 'needs-review',
        category: endpointCategory(`${node?.nodeType ?? ''} ${node?.displayName ?? ''}`),
        tokens: tokenSet([node?.id, node?.displayName, ...modules, ...instances]),
        onOpen: () => node && onOpenDrillEndpoint(node.id),
      }
    }
    return {
      left: make(drillInterface ? drillNodes.get(drillInterface.sourceNodeId) : undefined, drillInterface?.sourceNodeId ?? 'source'),
      right: make(drillInterface ? drillNodes.get(drillInterface.destinationNodeId) : undefined, drillInterface?.destinationNodeId ?? 'destination'),
    }
  }, [physicalInterface, drillInterface, blocks, drillNodes, onOpenPhysicalEndpoint, onOpenDrillEndpoint])

  const groups = useMemo(() => {
    if (!item) return []
    const originalGroupBySignal = new Map(item.signalGroups.flatMap((group) => group.rawConnectionIds.map((id) => [id, group.name] as const)))
    const grouped = new Map<string, { id: string; name: string; attribute: string; rawConnectionIds: string[]; signals: RawConnection[] }>()
    for (const raw of raws) {
      const presentation = signalSemanticPresentation(raw, originalGroupBySignal.get(raw.id))
      const groupName = semanticLabel(presentation.groupAlias)
      const current = grouped.get(groupName) ?? { id: `${item.id}:semantic:${groupName.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`, name: groupName, attribute: signalAttribute(raw), rawConnectionIds: [], signals: [] }
      current.rawConnectionIds.push(raw.id)
      current.signals.push(raw)
      if (current.attribute === 'Needs Review' && signalAttribute(raw) !== 'Needs Review') current.attribute = signalAttribute(raw)
      grouped.set(groupName, current)
    }
    return [...grouped.values()].sort((left, right) => signalGroupOrder(left.name) - signalGroupOrder(right.name) || left.name.localeCompare(right.name))
  }, [item, raws, rawConnections])

  useEffect(() => {
    setSignalQuery('')
    setSelectedSignalId(null)
    setShowSource(false)
    setExpandedGroups(new Set())
  }, [item?.id, groups.length])

  if (!item) return null
  const plane = item.plane
  const evidence = physicalInterface ? physicalInterface.evidenceStatus : drillInterface!.confidenceStatus
  const pathKind = physicalInterface?.pathKind ?? 'semantic architecture path'
  const selectedSignal = selectedSignalId ? rawConnections.get(selectedSignalId) ?? null : null
  const selectedSignalPresentation = selectedSignal ? signalPresentations.get(selectedSignal.id) ?? signalSemanticPresentation(selectedSignal) : null
  const selectedDirection = selectedSignal ? signalDirection(selectedSignal, endpointViews.left.tokens, endpointViews.right.tokens) : null
  const needle = signalQuery.trim().toLowerCase()
  const hasProgramRoute = raws.some((raw) => /(?:program|load|word|distributor|config).*(?:scope|destination)|(?:scope|destination).*(?:program|load|word|distributor|config)/i.test(`${raw.signalName} ${raw.connectionExpression}`))

  return <section className={`bus-detail-view engineering-detail plane-${plane}`} aria-label={`Bus Detail: ${item.name}`}>
    <header className="bus-detail-header">
      <button className="bus-detail-back" onClick={onBack}>← 返回原架构</button>
      <div><span>LPU / {physicalInterface ? 'Physical Architecture' : 'Functional Block'} / Bus Detail</span><h1>{item.name}</h1></div>
      <div className="bus-detail-meta"><b>{plane.toUpperCase()} PLANE</b><span className={`status-pill status-${evidence}`}>{evidence}</span><small>{groups.length} semantic groups</small></div>
    </header>

    <div className="bus-detail-toolbar">
      <div><span>PATH</span><strong>{pathKind}</strong></div>
      <div><span>DIRECTION MODEL</span><strong>per RTL signal</strong></div>
      <label><span>SEARCH INTERFACE FIELDS</span><input value={signalQuery} onChange={(event) => setSignalQuery(event.target.value)} placeholder="display name / RTL name / meaning" /></label>
    </div>

    {physicalInterface?.pathKind === 'processed-path' && <div className="bus-processed-warning"><b>PROCESSED PATH</b><span>此接口经过合并或组合处理逻辑；下方保留真实 RTL 路径，不把它伪装成直接连线。</span></div>}

    {((physicalInterface?.notes ?? drillInterface?.notes ?? []).length > 0) && <div className="bus-contract-notes"><b>INTERFACE CONTRACT</b><div>{(physicalInterface?.notes ?? drillInterface?.notes ?? []).map((note, index) => <span key={`${index}-${note}`}>{note}</span>)}</div></div>}

    {hasProgramRoute && <section className="program-route-field-map" aria-label="Program Load Route Field Map">
      <header><div><span>PROGRAM LOAD ROUTE CONTRACT</span><strong>Scope and Destination are independent fields</strong></div><small>RTL-confirmed internal contract</small></header>
      <div className="program-route-scope"><span>SCOPE [1:0]</span><b>EAST</b><b>WEST</b><b>BOTH</b><p>BOTH expands inside the Distributor into independent East and West ready/valid handshakes.</p></div>
      <div className="program-route-destination"><span>DESTINATION [11:0]</span><b className="destination-hemisphere">[11] Endpoint Hemisphere</b><b className="destination-kind">[10:8] FU Kind</b><b className="destination-index">[7:0] Local Target Index</b></div>
      <footer><span>MEM: local index 0..103 / endpoint · integrated</span><span>MXM Load, Compute, Dequant, Param Load, Backend: local index 0..1 / kind / endpoint · integrated</span><span>SXM: R6 → native CTRL/EXEC calendars · index 0 · integrated</span><span className="needs-review">VXM: central direct boundary · Relay bypass · Ready=0 · No Commit</span></footer>
    </section>}

    {hasProgramRoute && <section className="program-relay-interface-contract" aria-label="Program Load Relay Interface Contract">
      <header><div><span>PROGRAM LOAD RELAY CONTRACT</span><strong>165-bit Program Record → 2 × 7 stages; each stage is one registered boundary with skid capacity</strong></div><b>2×7 RTL INSTANCES · SYSTEM NEEDS REVIEW</b></header>
      <div className="program-relay-interface-flow">
        <article><span>INPUT</span><strong>Program Load Record</strong><small>Valid / Ready · 165-bit record</small></article>
        <i>→</i>
        <article className="relay-boundary"><span>RELAY</span><strong>Registered Boundary + Skid</strong><small>BUFFER_DEPTH=2 is capacity, not two independent pipeline stages</small></article>
        <i>→</i>
        <article><span>OUTPUT</span><strong>Local MEM range or R6 Outer Local</strong><small>MEM/MXM integrated · invalid route → fault/status return</small></article>
      </div>
      <footer><span>Input Ready has no combinational dependency on Forward Ready</span><span>Target initiation interval: II=1</span><span>14 independent Relay Local Program Ports · 7 per Hemisphere</span><span>Each port owns one fixed MEM Bank range and independent Valid/Ready/Error</span><span>Program Reset clears 14 Relay buffers + per-port handshake / Commit state</span><span>SXM: native Program/ROW integrated</span><span className="needs-review">VXM: boundary connected / endpoint not integrated</span></footer>
    </section>}

    <div className="bus-detail-columns">
      <aside className="bus-endpoint-column"><EndpointCard side="source" endpoint={endpointViews.left} /></aside>

      <main className="bus-signal-groups">
        <div className="bus-signal-groups-heading"><div><span>SEMANTIC CONNECTIONS</span><p>主层只表达语义组与流向；点击分组后再查看原始 RTL signal、端口和位宽。</p></div><div className="bus-direction-legend"><span>→ forward</span><span>← return</span><span>↔ handshake</span><span>? review</span></div></div>
        {groups.map((group) => {
          const matching = group.signals.filter((raw) => { const presentation = signalPresentations.get(raw.id)!; return !needle || `${presentation.displayName} ${presentation.rtlName} ${presentation.meaning} ${raw.connectionExpression} ${raw.sourceEndpoints.map(endpointLabel).join(' ')} ${raw.destinationEndpoints.map(endpointLabel).join(' ')}`.toLowerCase().includes(needle) })
          if (!matching.length) return null
          const expanded = expandedGroups.has(group.id) || Boolean(needle)
          const directions = unique(matching.map((raw) => signalDirection(raw, endpointViews.left.tokens, endpointViews.right.tokens))) as FlowDirection[]
          return <section className={`bus-signal-group ${expanded ? 'expanded' : 'collapsed'}`} key={group.id}>
            <button className="bus-group-heading" onClick={() => setExpandedGroups((current) => { const next = new Set(current); if (next.has(group.id)) next.delete(group.id); else next.add(group.id); return next })}>
              <span>{expanded ? '−' : '+'}</span><strong>{semanticLabel(group.name)}</strong><b>{group.attribute} · {matching.length} field{matching.length === 1 ? '' : 's'}</b>
            </button>
            <div className="bus-semantic-flow">{directions.map((direction) => <div className={`bus-semantic-lane direction-${direction}`} key={direction}>
              <span><i /><b>{direction === 'forward' ? '→' : direction === 'reverse' ? '←' : direction === 'bidirectional' ? '↔' : '?'}</b></span>
              <strong>{direction === 'forward' ? 'Forward to destination' : direction === 'reverse' ? 'Return to source' : direction === 'bidirectional' ? 'Bidirectional channel' : 'Direction needs review'}</strong>
              <small>{group.attribute} · {matching.length} semantic field{matching.length === 1 ? '' : 's'}</small>
            </div>)}</div>
            {expanded && <div className="bus-signal-list">{matching.map((raw) => {
              const direction = signalDirection(raw, endpointViews.left.tokens, endpointViews.right.tokens)
              const presentation = signalPresentations.get(raw.id)!
              return <button className={`bus-signal-row direction-${direction} ${selectedSignalId === raw.id ? 'selected' : ''}`} key={raw.id} onClick={() => { setSelectedSignalId(raw.id); setShowSource(false) }}>
                <span className="bus-signal-name" title={`RTL name: ${presentation.rtlName}`}><strong>{presentation.displayName}</strong><code>{presentation.rtlName}</code><p>{presentation.meaning}</p></span><small>{widthLabel(raw)}</small><span className="bus-signal-arrow"><i /><b>{direction === 'forward' ? '→' : direction === 'reverse' ? '←' : direction === 'bidirectional' ? '↔' : '?'}</b></span><em>{directionLabel(direction)}</em>
              </button>
            })}</div>}
            {!expanded && <button className="bus-group-more" onClick={() => setExpandedGroups((current) => new Set(current).add(group.id))}>展开 {matching.length} 个语义字段与 RTL 证据</button>}
          </section>
        })}
        {needle && groups.every((group) => group.signals.every((raw) => { const presentation = signalPresentations.get(raw.id)!; return !`${presentation.displayName} ${presentation.rtlName} ${presentation.meaning} ${raw.connectionExpression}`.toLowerCase().includes(needle) })) && <div className="inline-empty">没有匹配的接口字段。</div>}
      </main>

      <aside className="bus-endpoint-column"><EndpointCard side="destination" endpoint={endpointViews.right} /></aside>
    </div>

    {selectedSignal && selectedSignalPresentation && <section className="bus-signal-detail" aria-label={`Signal Detail: ${selectedSignalPresentation.displayName}`}>
      <header><div><span>INTERFACE FIELD DETAIL</span><h2>{selectedSignalPresentation.displayName}</h2><code title="完整 RTL 原名">{selectedSignalPresentation.rtlName}</code></div><button onClick={() => setSelectedSignalId(null)}>返回 Bus Detail ×</button></header>
      <div className="bus-signal-detail-grid">
        <div><span>MEANING / 语义</span><strong>{selectedSignalPresentation.meaning}</strong></div><div><span>WIDTH</span><strong>{widthLabel(selectedSignal)}</strong></div><div><span>SEMANTIC GROUP</span><strong>{selectedSignalPresentation.groupAlias}</strong></div><div><span>ACTUAL FLOW</span><strong>{selectedDirection ? directionLabel(selectedDirection) : 'Needs Review'}</strong></div><div><span>EVIDENCE</span><strong>{selectedSignal.connectionStatus}</strong></div>
      </div>
      <div className="bus-signal-route"><div><span>RTL SOURCE PORTS</span>{selectedSignal.sourceEndpoints.length ? selectedSignal.sourceEndpoints.map((endpoint) => <code key={endpoint.id}>{endpointLabel(endpoint)} <small>{endpoint.portDirection}</small></code>) : <code>partial / unresolved source</code>}</div><b>{selectedDirection === 'reverse' ? '←' : selectedDirection === 'bidirectional' ? '↔' : selectedDirection === 'unknown' ? '?' : '→'}</b><div><span>RTL DESTINATION PORTS</span>{selectedSignal.destinationEndpoints.length ? selectedSignal.destinationEndpoints.map((endpoint) => <code key={endpoint.id}>{endpointLabel(endpoint)} <small>{endpoint.portDirection}</small></code>) : <code>partial / unresolved destination</code>}</div></div>
      <div className="bus-signal-evidence"><div><span>CONNECTION EXPRESSION</span><code>{selectedSignal.connectionExpression}</code></div><div><span>RTL LOCATION</span><code>{selectedSignal.sourceFile}:{selectedSignal.line ?? '?'}</code></div></div>
      <div className="bus-signal-actions"><button onClick={() => setShowSource((current) => !current)}>{showSource ? '收起源码片段' : '查看源码片段'}</button>{unique([...selectedSignal.sourceEndpoints, ...selectedSignal.destinationEndpoints].map((endpoint) => endpoint.instanceId)).filter((id) => hierarchyNodes.has(id)).slice(0, 2).map((id) => <button key={id} onClick={() => onLocateRtlNode(id)}>定位 RTL Hierarchy · {hierarchyNodes.get(id)?.name}</button>)}</div>
      {showSource && <SourceSnippet file={selectedSignal.sourceFile} line={selectedSignal.line} />}
    </section>}

    <footer className="bus-detail-evidence"><div><span>EVIDENCE / RTL CONNECTION</span><strong>{physicalInterface?.classificationBasis ?? drillInterface?.semanticDescription}</strong></div><div>{physicalInterface?.rtlPath.map((step, index) => <code key={`${step.file}:${step.line}:${index}`}>{index + 1}. {step.label} · {step.file}:{step.line}</code>)}{drillInterface?.sourceEvidence.map((source, index) => <code key={`${source.file}:${source.line}:${index}`}>{source.basis} · {source.file}:{source.line ?? '?'}</code>)}</div></footer>
  </section>
}
