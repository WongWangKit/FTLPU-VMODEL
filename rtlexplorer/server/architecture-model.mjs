import { promises as fs } from 'node:fs'
import { buildPhysicalArchitectureModel } from './physical-architecture-model.mjs'
import { buildConfigurationOverviewModel } from './configuration-overview-model.mjs'

const FALLBACK_RULES = {
  primaryTopInstances: ['u_program_controller', 'u_fu_subsystems'],
  legacyTopInstances: ['u_mem', 'u_sxm', 'u_mxm', 'u_vxm'],
  semanticRules: [
    { id: 'clock-reset', name: 'Clock / Reset', category: 'clock-reset', confidence: 'high', patterns: ['(^|_)(clk|clock|rst|reset)(_|$)'] },
    { id: 'east-stream', name: 'East Stream Interface', category: 'stream', confidence: 'high', patterns: ['(^|_)east(_|$)'] },
    { id: 'west-stream', name: 'West Stream Interface', category: 'stream', confidence: 'high', patterns: ['(^|_)west(_|$)'] },
    { id: 'program-load', name: 'Program Load Interface', category: 'program', confidence: 'high', patterns: ['(^|_)(program|imem)(_|$)'] },
    { id: 'host-memory', name: 'Host Memory Interface', category: 'host', confidence: 'high', patterns: ['(^|_)host(_|$)'] },
    { id: 'queue-enqueue', name: 'Queue Enqueue Interface', category: 'queue', confidence: 'high', patterns: ['(^|_)enqueue(_|$)'] },
    { id: 'queue-dequeue', name: 'Queue Dequeue Interface', category: 'queue', confidence: 'high', patterns: ['(^|_)dequeue(_|$)'] },
    { id: 'issue', name: 'Issue Interface', category: 'issue', confidence: 'high', patterns: ['(^|_)issue(_|$)'] },
    { id: 'queue-control', name: 'Queue Control Interface', category: 'control', confidence: 'medium', patterns: ['(^|_)(qctl|scheduler|schedule_cycle|queue_active)(_|$)'] },
    { id: 'configuration', name: 'Configuration Interface', category: 'configuration', confidence: 'medium', patterns: ['(^|_)(config|mode|enable|partition)(_|$)'] },
    { id: 'status-fault', name: 'Status / Fault Interface', category: 'status', confidence: 'high', patterns: ['(^|_)(fault|error|conflict)(_|$)'] },
    { id: 'status', name: 'Status Interface', category: 'status', confidence: 'medium', patterns: ['(^|_)(busy|done|complete|configured|idle|primed|status)(_|$)'] },
    { id: 'load', name: 'Load Interface', category: 'load', confidence: 'medium', patterns: ['(^|_)load(_|$)'] },
  ],
  signalGroupRules: [
    { id: 'data', name: 'Data / Payload', patterns: ['(^|_)(data|payload|result|value)(_|$)'] },
    { id: 'address', name: 'Address', patterns: ['(^|_)(addr|address|offset)(_|$)'] },
    { id: 'handshake', name: 'Handshake', patterns: ['(^|_)(valid|ready|fire|consume)(_|$)'] },
    { id: 'command', name: 'Command / Instruction', patterns: ['(^|_)(command|opcode|issue|instr|instruction)(_|$)'] },
    { id: 'configuration', name: 'Configuration', patterns: ['(^|_)(config|mode|enable|parameter|partition)(_|$)'] },
    { id: 'status', name: 'Status', patterns: ['(^|_)(busy|done|complete|configured|idle|primed|status|level)(_|$)'] },
    { id: 'fault', name: 'Fault / Error', patterns: ['(^|_)(fault|error|conflict)(_|$)'] },
    { id: 'clock-reset', name: 'Clock / Reset', patterns: ['(^|_)(clk|clock|rst|reset)(_|$)'] },
  ],
  manualInterfaces: [],
}

const RESERVED_IDENTIFIERS = new Set([
  'assign', 'begin', 'end', 'if', 'else', 'for', 'genvar', 'logic', 'wire', 'signed',
  'unsigned', 'and', 'or', 'not', 'posedge', 'negedge', 'default', 'true', 'false',
])

function mergeRules(value = {}) {
  return {
    ...FALLBACK_RULES,
    ...value,
    semanticRules: value.semanticRules ?? FALLBACK_RULES.semanticRules,
    signalGroupRules: value.signalGroupRules ?? FALLBACK_RULES.signalGroupRules,
    manualInterfaces: value.manualInterfaces ?? [],
  }
}

export async function loadArchitectureRules(filePath) {
  try { return mergeRules(JSON.parse(await fs.readFile(filePath, 'utf8'))) }
  catch { return mergeRules() }
}

function normalize(value) {
  return String(value ?? '').replace(/\s+/g, ' ').trim()
}

function signalBase(value) {
  const match = normalize(value).match(/^([A-Za-z_$\\][A-Za-z0-9_$\\]*)(?:\s*\[[^\]]+\])?$/)
  return match?.[1] ?? null
}

function identifiers(value) {
  const matches = normalize(value).match(/[A-Za-z_$][A-Za-z0-9_$]*/g) ?? []
  return [...new Set(matches.filter((item) => !RESERVED_IDENTIFIERS.has(item.toLowerCase()) && !/^\d/.test(item)))]
}

function uniqueBy(values, key) {
  const result = []
  const seen = new Set()
  for (const value of values) {
    const id = key(value)
    if (seen.has(id)) continue
    seen.add(id)
    result.push(value)
  }
  return result
}

function inferRole(node) {
  const value = `${node.name} ${node.moduleName}`.toLowerCase()
  if (value.includes('frontend')) return 'frontend'
  if (value.includes('timed_queue') || value.includes('issue_queue') || /(^|_)queue/.test(value)) return 'queue'
  if (value.includes('coordinator')) return 'coordinator'
  if (value.includes('execution') || value.includes('slice') || value.includes('hemisphere')) return 'execution'
  if (value.includes('qctl')) return 'queue-control'
  if (value.includes('icu')) return 'instruction-control'
  if (value.includes('program')) return 'program-control'
  if (value.includes('cluster')) return 'cluster'
  if (value.includes('subsystem')) return 'subsystem'
  if (value.includes('control')) return 'control'
  return 'module'
}

function friendlyName(node, parentNode) {
  const bare = node.name.replace(/^u_/, '').replace(/#\d+$/, '')
  if (!node.generated) return bare
  if (parentNode?.moduleName === 'lpu_mem_subsystem' && bare === 'frontend') return 'frontend[bank]'
  if (parentNode?.moduleName === 'lpu_mem_subsystem' && bare === 'timed_queue') return 'timed_queue[bank]'
  if (parentNode?.moduleName === 'lpu_fu_subsystem_cluster' && bare === 'mem_subsystem') return 'mem_subsystem[hemisphere]'
  if (parentNode?.moduleName === 'lpu_fu_subsystem_cluster' && bare === 'sxm_subsystem') return 'sxm_subsystem[hemisphere]'
  if (parentNode?.moduleName === 'lpu_fu_subsystem_cluster' && bare === 'mxm_subsystem') return 'mxm_subsystem[unit]'
  if (node.moduleName === 'lpu_icu_queue') return 'queue[index]'
  return `${bare}[*]`
}

function boundaryEndpoint(scope, port, flow, sourceFile) {
  return {
    id: `boundary:${scope.id}:${port.name}`,
    instanceId: `boundary:${scope.id}`,
    instanceName: 'scope_boundary',
    moduleName: scope.moduleName,
    portName: port.name,
    portDirection: port.direction,
    flow,
    width: port.width,
    widthExpression: port.widthExpression,
    sourceFile,
    line: port.line,
    generated: false,
    boundary: true,
  }
}

function childEndpoint(edge, node, connection, index) {
  return {
    id: `${edge.id}:port:${connection.port ?? index}`,
    instanceId: node.id,
    instanceName: node.name,
    moduleName: node.moduleName,
    portName: connection.port ?? `#${connection.positionalIndex ?? index}`,
    portDirection: connection.direction,
    flow: connection.direction === 'output' ? 'source' : connection.direction === 'input' ? 'destination' : 'unknown',
    width: connection.width,
    widthExpression: connection.widthExpression,
    sourceFile: node.sourceFile,
    line: connection.line ?? node.line,
    generated: node.generated,
    boundary: false,
  }
}

function compilePatterns(rule) {
  return (rule.patterns ?? []).map((pattern) => new RegExp(pattern, 'i'))
}

function selectSemantic(text, scopeModule, rules, contextText = '') {
  const haystack = text.replace(/\s+/g, '_')
  const contextHaystack = contextText.replace(/\s+/g, '_')
  for (const manual of rules.manualInterfaces ?? []) {
    if (manual.scopeModule && manual.scopeModule !== scopeModule) continue
    if (new RegExp(manual.pattern, 'i').test(haystack)) {
      return {
        id: manual.id,
        name: manual.name,
        category: manual.category ?? 'manual',
        confidence: 'confirmed',
        semanticStatus: 'manual-confirmed',
        basis: `应用配置人工映射：${manual.pattern}`,
      }
    }
  }
  for (const rule of rules.semanticRules) {
    const matched = compilePatterns(rule).find((pattern) => pattern.test(haystack))
    if (matched) return {
      id: rule.id,
      name: rule.name,
      category: rule.category,
      confidence: rule.confidence ?? 'medium',
      semanticStatus: 'auto-inferred',
      basis: `端口、连接表达式与模块上下文匹配规则 ${matched.source}`,
    }
  }
  for (const rule of rules.semanticRules) {
    const matched = compilePatterns(rule).find((pattern) => pattern.test(contextHaystack))
    if (matched) return {
      id: rule.id,
      name: rule.name,
      category: rule.category,
      confidence: rule.confidence === 'high' ? 'medium' : 'low',
      semanticStatus: 'auto-inferred',
      basis: `端口与表达式未命中；仅由模块上下文匹配规则 ${matched.source}`,
    }
  }
  return {
    id: 'unclassified',
    name: 'Unclassified Interface',
    category: 'unclassified',
    confidence: 'low',
    semanticStatus: 'needs-review',
    basis: '未命中可靠语义规则；保留真实连接并标记待确认',
  }
}

function selectSignalGroup(text, rules) {
  const haystack = text.replace(/\s+/g, '_')
  for (const rule of rules.signalGroupRules) {
    if (compilePatterns(rule).some((pattern) => pattern.test(haystack))) return { id: rule.id, name: rule.name }
  }
  return { id: 'unclassified', name: 'Unclassified / Needs Review' }
}

function rawWidth(endpoints) {
  const widths = endpoints.map((endpoint) => endpoint.width).filter((width) => Number.isFinite(width))
  if (!widths.length) return null
  return Math.max(...widths)
}

function makeRawConnection({ id, scope, expression, signalName, endpoints, evidence, sourceFile, line }) {
  const sources = uniqueBy(endpoints.filter((endpoint) => endpoint.flow === 'source'), (endpoint) => endpoint.id)
  const destinations = uniqueBy(endpoints.filter((endpoint) => endpoint.flow === 'destination'), (endpoint) => endpoint.id)
  const unknown = uniqueBy(endpoints.filter((endpoint) => endpoint.flow === 'unknown'), (endpoint) => endpoint.id)
  const all = uniqueBy([...sources, ...destinations, ...unknown], (endpoint) => endpoint.id)
  return {
    id,
    scopeId: scope.id,
    scopeModule: scope.moduleName,
    signalName,
    connectionExpression: expression,
    sourceEndpoints: sources,
    destinationEndpoints: destinations,
    unresolvedEndpoints: unknown,
    resolvedWidth: rawWidth(all),
    widthExpressions: [...new Set(all.map((endpoint) => endpoint.widthExpression).filter(Boolean))],
    sourceFile,
    line,
    evidence,
    connectionStatus: sources.length && destinations.length ? 'rtl-confirmed' : 'partial-or-unresolved',
  }
}

function endpointInstances(endpoints) {
  return uniqueBy(endpoints.map((endpoint) => ({
    id: endpoint.instanceId,
    name: endpoint.instanceName,
    moduleName: endpoint.moduleName,
    boundary: endpoint.boundary,
  })), (value) => value.id)
}

function buildInterfaces(rawConnections, rules) {
  const groups = new Map()
  for (const raw of rawConnections) {
    if (raw.connectionStatus !== 'rtl-confirmed') continue
    const endpoints = [...raw.sourceEndpoints, ...raw.destinationEndpoints]
    const text = normalize([
      raw.signalName,
      raw.connectionExpression,
      ...endpoints.map((endpoint) => `${endpoint.portName} ${endpoint.instanceName}`),
    ].join(' ')).toLowerCase()
    const contextText = normalize(endpoints.map((endpoint) => endpoint.moduleName).join(' ')).toLowerCase()
    const semantic = selectSemantic(text, raw.scopeModule, rules, contextText)
    const signalGroup = selectSignalGroup(`${text} ${contextText}`, rules)
    raw.semanticId = semantic.id
    raw.semanticName = semantic.name
    raw.signalGroup = signalGroup
    const instanceSet = [...new Set(endpoints.map((endpoint) => endpoint.instanceId))].sort()
    const key = `${raw.scopeId}|${semantic.id}|${instanceSet.join('|')}`
    const current = groups.get(key) ?? {
      id: `interface:${raw.scopeId}:${semantic.id}:${groups.size}`,
      scopeId: raw.scopeId,
      scopeModule: raw.scopeModule,
      semanticName: semantic.name,
      category: semantic.category,
      connectionStatus: 'rtl-confirmed',
      semanticStatus: semantic.semanticStatus,
      confidence: semantic.confidence,
      classificationBasis: semantic.basis,
      manuallyConfirmed: semantic.semanticStatus === 'manual-confirmed',
      rawConnectionIds: [],
      sourceInstances: [],
      destinationInstances: [],
      signalGroups: [],
      sourceLocations: [],
      totalWidth: 0,
      hasUnresolvedWidth: false,
    }
    current.rawConnectionIds.push(raw.id)
    current.sourceInstances = uniqueBy([...current.sourceInstances, ...endpointInstances(raw.sourceEndpoints)], (value) => value.id)
    current.destinationInstances = uniqueBy([...current.destinationInstances, ...endpointInstances(raw.destinationEndpoints)], (value) => value.id)
    current.sourceLocations = uniqueBy([...current.sourceLocations, { file: raw.sourceFile, line: raw.line }], (value) => `${value.file}:${value.line}`)
    if (raw.resolvedWidth === null) current.hasUnresolvedWidth = true
    else current.totalWidth += raw.resolvedWidth
    const existingSignalGroup = current.signalGroups.find((group) => group.id === signalGroup.id)
    if (existingSignalGroup) existingSignalGroup.rawConnectionIds.push(raw.id)
    else current.signalGroups.push({ ...signalGroup, rawConnectionIds: [raw.id] })
    groups.set(key, current)
  }
  return [...groups.values()].map((item) => {
    const sourceIds = new Set(item.sourceInstances.map((value) => value.id))
    const destinationIds = new Set(item.destinationInstances.map((value) => value.id))
    return {
      ...item,
      signalCount: item.rawConnectionIds.length,
      bidirectional: [...sourceIds].some((id) => destinationIds.has(id)),
      totalWidth: item.hasUnresolvedWidth ? null : item.totalWidth,
    }
  })
}

export function buildArchitectureModel(snapshot, suppliedRules = {}) {
  const rules = mergeRules(suppliedRules)
  const nodeMap = new Map(snapshot.hierarchy.nodes.map((node) => [node.id, node]))
  const moduleMap = new Map(snapshot.modules.map((module) => [module.name, module]))
  const root = snapshot.hierarchy.nodes.find((node) => !node.parentId)
  const legacyRootIds = new Set(snapshot.hierarchy.nodes
    .filter((node) => node.parentId === root?.id && rules.legacyTopInstances.includes(node.name.replace(/#\d+$/, '')))
    .map((node) => node.id))

  function isLegacy(node) {
    let current = node
    while (current) {
      if (legacyRootIds.has(current.id)) return true
      current = current.parentId ? nodeMap.get(current.parentId) : null
    }
    return false
  }

  const containers = snapshot.hierarchy.nodes.map((node) => {
    const parentNode = node.parentId ? nodeMap.get(node.parentId) : null
    const legacy = isLegacy(node)
    return {
      ...node,
      displayName: friendlyName(node, parentNode),
      role: inferRole(node),
      classification: legacy ? 'legacy-direct-instantiation' : 'primary-subsystem-path',
      primary: !legacy,
      template: node.generated,
      childCount: snapshot.hierarchy.nodes.filter((candidate) => candidate.parentId === node.id).length,
    }
  })
  const containment = snapshot.hierarchy.nodes.filter((node) => node.parentId).map((node) => ({
    id: `containment:${node.parentId}:${node.id}`,
    parentId: node.parentId,
    childId: node.id,
    relation: 'containment',
    primary: !isLegacy(node),
  }))

  const edgesByScope = new Map()
  for (const edge of snapshot.hierarchy.edges) edgesByScope.set(edge.source, [...(edgesByScope.get(edge.source) ?? []), edge])
  const rawConnections = []

  for (const scope of snapshot.hierarchy.nodes) {
    const childEdges = edgesByScope.get(scope.id) ?? []
    if (!childEdges.length) continue
    const scopeDefinition = moduleMap.get(scope.moduleName)
    if (!scopeDefinition) continue
    const scopePorts = new Map(scopeDefinition.ports.map((port) => [port.name, port]))
    const childRecords = []
    childEdges.forEach((edge) => {
      const child = nodeMap.get(edge.target)
      if (!child) return
      edge.connections.forEach((connection, index) => {
        const endpoint = childEndpoint(edge, child, connection, index)
        childRecords.push({ edge, child, connection, endpoint, expression: normalize(connection.expression), base: signalBase(connection.expression) })
      })
    })

    const expressionGroups = new Map()
    for (const record of childRecords) {
      const key = record.expression || `unconnected:${record.endpoint.id}`
      expressionGroups.set(key, [...(expressionGroups.get(key) ?? []), record])
    }

    let rawIndex = 0
    for (const [expression, records] of expressionGroups) {
      const endpoints = records.map((record) => record.endpoint)
      const base = records[0]?.base
      const parentPort = base ? scopePorts.get(base) : null
      if (parentPort) {
        const flow = parentPort.direction === 'input' ? 'source' : parentPort.direction === 'output' ? 'destination' : 'unknown'
        endpoints.push(boundaryEndpoint(scope, parentPort, flow, scopeDefinition.file))
      }
      rawConnections.push(makeRawConnection({
        id: `raw:${scope.id}:${rawIndex++}`,
        scope,
        expression: expression.startsWith('unconnected:') ? '' : expression,
        signalName: base ?? records[0]?.connection.port ?? 'unconnected',
        endpoints,
        evidence: ['instance-port-binding'],
        sourceFile: records[0]?.child.sourceFile ?? scopeDefinition.file,
        line: records[0]?.connection.line ?? records[0]?.child.line ?? scopeDefinition.line,
      }))
    }

    const recordsByBase = new Map()
    for (const record of childRecords) {
      if (!record.base) continue
      recordsByBase.set(record.base, [...(recordsByBase.get(record.base) ?? []), record])
    }
    for (const assignment of scopeDefinition.assignments ?? []) {
      const leftIds = identifiers(assignment.left)
      const rightIds = identifiers(assignment.right)
      const endpoints = []
      for (const id of rightIds) {
        for (const record of recordsByBase.get(id) ?? []) {
          if (record.endpoint.flow === 'source') endpoints.push(record.endpoint)
        }
        const port = scopePorts.get(id)
        if (port?.direction === 'input') endpoints.push(boundaryEndpoint(scope, port, 'source', scopeDefinition.file))
      }
      for (const id of leftIds) {
        for (const record of recordsByBase.get(id) ?? []) {
          if (record.endpoint.flow === 'destination') endpoints.push(record.endpoint)
        }
        const port = scopePorts.get(id)
        if (port?.direction === 'output') endpoints.push(boundaryEndpoint(scope, port, 'destination', scopeDefinition.file))
      }
      const uniqueEndpoints = uniqueBy(endpoints, (endpoint) => endpoint.id)
      if (!uniqueEndpoints.some((endpoint) => endpoint.flow === 'source') || !uniqueEndpoints.some((endpoint) => endpoint.flow === 'destination')) continue
      rawConnections.push(makeRawConnection({
        id: `raw:${scope.id}:assign:${assignment.id}`,
        scope,
        expression: assignment.expression,
        signalName: assignment.left,
        endpoints: uniqueEndpoints,
        evidence: ['instance-port-binding', 'continuous-assignment'],
        sourceFile: assignment.file,
        line: assignment.line,
      }))
    }
  }

  const uniqueRawConnections = uniqueBy(rawConnections, (raw) => [
    raw.scopeId,
    raw.signalName,
    raw.sourceEndpoints.map((endpoint) => endpoint.id).sort().join(','),
    raw.destinationEndpoints.map((endpoint) => endpoint.id).sort().join(','),
    raw.connectionExpression,
  ].join('|'))
  const interfaces = buildInterfaces(uniqueRawConnections, rules)
  const coverageByModule = ['lpu_mem_subsystem', 'lpu_mxm_subsystem', 'lpu_vxm_subsystem'].map((moduleName) => {
    const scopes = containers.filter((container) => container.moduleName === moduleName && container.primary)
    const scopeIds = new Set(scopes.map((scope) => scope.id))
    const moduleInterfaces = interfaces.filter((item) => scopeIds.has(item.scopeId))
    return {
      moduleName,
      scopeCount: scopes.length,
      interfaceCount: moduleInterfaces.length,
      signalCount: moduleInterfaces.reduce((sum, item) => sum + item.signalCount, 0),
      needsReviewCount: moduleInterfaces.filter((item) => item.semanticStatus === 'needs-review').length,
    }
  })

  return {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    policy: {
      defaultView: 'architecture',
      primaryOrganization: 'subsystem',
      primaryTopInstances: rules.primaryTopInstances,
      legacyTopInstances: rules.legacyTopInstances,
      legacyRootIds: [...legacyRootIds],
      statement: '当前主架构展示优先采用 subsystem 组织方式。其他历史或并存实例路径仅作为辅助排查信息，不作为默认主视图。',
      semanticDisclaimer: '连线事实来自实例端口绑定及已解析的连续赋值；接口名称和信号分组属于规则聚合，除非明确标记人工确认。',
    },
    containers,
    containment,
    interfaces,
    rawConnections: uniqueRawConnections,
    summary: {
      containerCount: containers.length,
      primaryContainerCount: containers.filter((container) => container.primary).length,
      legacyContainerCount: containers.filter((container) => !container.primary).length,
      containmentCount: containment.length,
      interfaceCount: interfaces.length,
      rawConnectionCount: uniqueRawConnections.length,
      confirmedConnectionCount: uniqueRawConnections.filter((raw) => raw.connectionStatus === 'rtl-confirmed').length,
      inferredSemanticCount: interfaces.filter((item) => item.semanticStatus === 'auto-inferred').length,
      manualSemanticCount: interfaces.filter((item) => item.semanticStatus === 'manual-confirmed').length,
      needsReviewCount: interfaces.filter((item) => item.semanticStatus === 'needs-review').length,
      coverageByModule,
    },
  }
}

export function attachArchitectureModel(snapshot, rules = {}, physicalRules = {}) {
  const architecture = buildArchitectureModel(snapshot, rules)
  const physicalArchitecture = buildPhysicalArchitectureModel(snapshot, architecture, physicalRules)
  return {
    ...snapshot,
    architecture,
    physicalArchitecture,
    configurationOverview: buildConfigurationOverviewModel(snapshot, physicalArchitecture),
  }
}
