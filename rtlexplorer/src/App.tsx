import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { Viewport } from '@xyflow/react'
import ArchitectureGraph from './components/ArchitectureGraph'
import BusDetailView from './components/BusDetailView'
import ConfigurationOverview from './components/ConfigurationOverview'
import FunctionalBlockDetail from './components/FunctionalBlockDetail'
import HierarchyTree from './components/HierarchyTree'
import Inspector from './components/Inspector'
import IsaExplorer from './components/IsaExplorer'
import PhysicalArchitectureGraph from './components/PhysicalArchitectureGraph'
import PhysicalInspector from './components/PhysicalInspector'
import PhysicalNavigator from './components/PhysicalNavigator'
import type { ArchitectureDrillNode, SearchResult, Snapshot, ViewMode } from './types'
import type { IsaFu } from './lib/isa-catalog'

interface AppConfig {
  projectRoot: string
  sourceDirectory: string
  filelist: string
  veribleExecutable: string
  preferredTop: string
  appRoot?: string
  snapshotPath?: string
}

interface ScanState {
  running: boolean
  phase: string
  completed: number
  total: number
  message: string
  error: string | null
}

type BusDetailTarget = { kind: 'physical' | 'drill'; id: string } | null

interface ExplorerHistoryState {
  __rtlExplorer: true
  viewMode: ViewMode
  physicalBlockId: string | null
  drillScopeId: string | null
  selectedArchitectureNodeId: string | null
  busDetailTarget: BusDetailTarget
}

const viewOptions: Array<{ value: ViewMode; label: string; hint: string }> = [
  { value: 'physical', label: 'Physical Architecture', hint: '物理拓扑' },
  { value: 'functional', label: 'Functional Block', hint: '功能单元' },
  { value: 'hierarchy', label: 'RTL Hierarchy', hint: '源码层次' },
  { value: 'configuration', label: 'Configuration', hint: '规模与组成' },
  { value: 'isa', label: 'Unified ISA', hint: '指令与编码' },
]

async function responseJson<T>(response: Response): Promise<T> {
  const body = await response.json()
  if (!response.ok) throw new Error(body.error ?? `HTTP ${response.status}`)
  return body
}

export default function App() {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null)
  const [publicSnapshotMode, setPublicSnapshotMode] = useState(false)
  const [config, setConfig] = useState<AppConfig | null>(null)
  const [scanState, setScanState] = useState<ScanState | null>(null)
  const [error, setError] = useState('')
  const [viewMode, setViewMode] = useState<ViewMode>('physical')
  const [isaInitialFu, setIsaInitialFu] = useState<IsaFu>('MEM')
  const [focusId, setFocusId] = useState<string | null>(null)
  const [selectedNodeId, setSelectedNodeId] = useState<string | null>(null)
  const [selectedSemanticInterfaceId, setSelectedSemanticInterfaceId] = useState<string | null>(null)
  const [selectedPhysicalBlockId, setSelectedPhysicalBlockId] = useState<string | null>(null)
  const [selectedPhysicalInterfaceId, setSelectedPhysicalInterfaceId] = useState<string | null>(null)
  const [drillScopeId, setDrillScopeId] = useState<string | null>(null)
  const [selectedArchitectureNodeId, setSelectedArchitectureNodeId] = useState<string | null>(null)
  const [selectedDrillInterfaceId, setSelectedDrillInterfaceId] = useState<string | null>(null)
  const [busDetailTarget, setBusDetailTarget] = useState<BusDetailTarget>(null)
  const [drillSelectionByScope, setDrillSelectionByScope] = useState<Record<string, string>>({})
  const [fontScale, setFontScale] = useState<'compact' | 'comfortable' | 'large'>('large')
  const [leftSidebarOpen, setLeftSidebarOpen] = useState(false)
  const [rightSidebarOpen, setRightSidebarOpen] = useState(false)
  const [selectedRawConnectionId, setSelectedRawConnectionId] = useState<string | null>(null)
  const [expanded, setExpanded] = useState<Set<string>>(new Set())
  const [query, setQuery] = useState('')
  const [showSearch, setShowSearch] = useState(false)
  const [hideUnrelated, setHideUnrelated] = useState(false)
  const [showLegacy, setShowLegacy] = useState(false)
  const [planeFilter, setPlaneFilter] = useState<'all' | 'data' | 'control'>('all')
  const [signalQuery, setSignalQuery] = useState('')
  const [settingsOpen, setSettingsOpen] = useState(false)
  const [warningsOpen, setWarningsOpen] = useState(false)
  const [rescanBusy, setRescanBusy] = useState(false)
  const [topBusy, setTopBusy] = useState(false)
  const [toast, setToast] = useState('')
  const [decoderFocusMode, setDecoderFocusMode] = useState(false)
  const importInput = useRef<HTMLInputElement>(null)
  const drillViewportState = useRef(new Map<string, Viewport>())
  const historyInitialized = useRef(false)

  const loadSnapshot = useCallback(async () => {
    let next: Snapshot
    try {
      next = await responseJson<Snapshot>(await fetch('/api/snapshot', { headers: { Accept: 'application/json' } }))
      setPublicSnapshotMode(false)
    } catch {
      const publicSnapshotUrl = `/data/architecture-snapshot.json?v=${Date.now()}`
      next = await responseJson<Snapshot>(await fetch(publicSnapshotUrl, {
        headers: { Accept: 'application/json' },
        cache: 'no-store',
      }))
      setPublicSnapshotMode(true)
    }
    if (!next.architecture || !next.physicalArchitecture) throw new Error('Snapshot 缺少 Physical Architecture Model，请重新扫描 RTL。')
    setSnapshot(next)
    const rootId = next.architecture.containers.find((node) => !node.parentId)?.id ?? null
    setSelectedNodeId((current) => current && next.hierarchy.nodes.some((node) => node.id === current) ? current : rootId)
    setFocusId((current) => current && next.hierarchy.nodes.some((node) => node.id === current) ? current : rootId)
    setExpanded((current) => current.size ? current : new Set(next.hierarchy.nodes.filter((node) => node.depth <= 1).map((node) => node.id)))
    return next
  }, [])

  useEffect(() => {
    loadSnapshot()
      .then(async () => {
        const [nextConfig, nextState] = await Promise.all([
          fetch('/api/config', { headers: { Accept: 'application/json' } }).then((response) => responseJson<AppConfig>(response)).catch(() => null),
          fetch('/api/status', { headers: { Accept: 'application/json' } }).then((response) => responseJson<ScanState>(response)).catch(() => null),
        ])
        setConfig(nextConfig)
        setScanState(nextState)
      })
      .catch((loadError) => setError(loadError.message))
  }, [loadSnapshot])

  useEffect(() => {
    if (!scanState?.running && !rescanBusy) return
    const timer = window.setInterval(() => fetch('/api/status').then((response) => responseJson<ScanState>(response)).then(setScanState).catch(() => {}), 700)
    return () => window.clearInterval(timer)
  }, [scanState?.running, rescanBusy])

  useEffect(() => {
    if (!toast) return
    const timer = window.setTimeout(() => setToast(''), 3200)
    return () => window.clearTimeout(timer)
  }, [toast])

  const moduleMap = useMemo(() => new Map(snapshot?.modules.map((module) => [module.name, module]) ?? []), [snapshot])
  const nodeMap = useMemo(() => new Map(snapshot?.hierarchy.nodes.map((node) => [node.id, node]) ?? []), [snapshot])
  const containerMap = useMemo(() => new Map(snapshot?.architecture.containers.map((node) => [node.id, node]) ?? []), [snapshot])
  const semanticInterfaceMap = useMemo(() => new Map(snapshot?.architecture.interfaces.map((item) => [item.id, item]) ?? []), [snapshot])
  const rawConnectionMap = useMemo(() => new Map(snapshot?.architecture.rawConnections.map((item) => [item.id, item]) ?? []), [snapshot])
  const physicalBlockMap = useMemo(() => new Map(snapshot?.physicalArchitecture.blocks.map((item) => [item.id, item]) ?? []), [snapshot])
  const physicalInterfaceMap = useMemo(() => new Map(snapshot?.physicalArchitecture.interfaces.map((item) => [item.id, item]) ?? []), [snapshot])
  const drillNodeMap = useMemo(() => new Map(snapshot?.physicalArchitecture.drilldown.nodes.map((item) => [item.id, item]) ?? []), [snapshot])
  const drillInterfaceMap = useMemo(() => new Map(snapshot?.physicalArchitecture.drilldown.interfaces.map((item) => [item.id, item]) ?? []), [snapshot])
  const legacyIds = useMemo(() => new Set(snapshot?.architecture.containers.filter((node) => !node.primary).map((node) => node.id) ?? []), [snapshot])

  const writeNavigationHistory = useCallback((state: ExplorerHistoryState, mode: 'push' | 'replace' = 'push') => {
    if (mode === 'replace') window.history.replaceState(state, '')
    else window.history.pushState(state, '')
  }, [])

  const restoreNavigationHistory = useCallback((state: ExplorerHistoryState) => {
    if (!state?.__rtlExplorer) return
    setViewMode(state.viewMode)
    setSelectedPhysicalBlockId(state.physicalBlockId)
    setDrillScopeId(state.drillScopeId)
    setSelectedArchitectureNodeId(state.selectedArchitectureNodeId)
    setBusDetailTarget(state.busDetailTarget)
    setSelectedDrillInterfaceId(state.busDetailTarget?.kind === 'drill' ? state.busDetailTarget.id : null)
    setSelectedPhysicalInterfaceId(state.busDetailTarget?.kind === 'physical' ? state.busDetailTarget.id : null)
    setSelectedRawConnectionId(null)
  }, [])

  useEffect(() => {
    if (!snapshot || historyInitialized.current) return
    historyInitialized.current = true
    writeNavigationHistory({ __rtlExplorer: true, viewMode: 'physical', physicalBlockId: null, drillScopeId: null, selectedArchitectureNodeId: null, busDetailTarget: null }, 'replace')
  }, [snapshot, writeNavigationHistory])

  useEffect(() => {
    const onPopState = (event: PopStateEvent) => restoreNavigationHistory(event.state as ExplorerHistoryState)
    window.addEventListener('popstate', onPopState)
    return () => window.removeEventListener('popstate', onPopState)
  }, [restoreNavigationHistory])

  const searchResults = useMemo<SearchResult[]>(() => {
    if (!snapshot || !query.trim()) return []
    const needle = query.trim().toLowerCase()
    const results: SearchResult[] = []
    for (const block of snapshot.physicalArchitecture.blocks) if (`${block.displayName} ${block.kind} ${block.definitionNames.join(' ')} ${block.function}`.toLowerCase().includes(needle)) results.push({ id: block.id, kind: 'block', title: block.displayName, subtitle: `${block.regionId} · ${block.instanceCountExpression}`, physicalBlockId: block.id })
    for (const item of snapshot.physicalArchitecture.interfaces) if (`${item.name} ${item.direction} ${item.classificationBasis}`.toLowerCase().includes(needle)) results.push({ id: item.id, kind: 'interface', title: item.name, subtitle: `${item.plane} plane · ${item.signalCount} raw links`, physicalInterfaceId: item.id })
    for (const node of snapshot.physicalArchitecture.drilldown.nodes) if (`${node.displayName} ${node.description} ${node.nodeType} ${node.rtlModuleRefs.join(' ')}`.toLowerCase().includes(needle)) results.push({ id: `architecture:${node.id}`, kind: 'architecture', title: node.displayName, subtitle: `${node.architectureLevel} · ${node.sourceKind}`, physicalBlockId: node.blockId, architectureNodeId: node.id })
    for (const module of snapshot.modules) {
      if (`${module.name} ${module.file}`.toLowerCase().includes(needle)) results.push({ id: `module:${module.id}`, kind: module.name.toLowerCase().includes(needle) ? 'module' : 'file', title: module.name, subtitle: `${module.file}:${module.line}`, moduleName: module.name })
      for (const port of module.ports) if (`${port.name} ${port.dataType} ${port.widthExpression}`.toLowerCase().includes(needle)) results.push({ id: `port:${module.id}:${port.name}`, kind: 'port', title: `${module.name}.${port.name}`, subtitle: `${port.direction} · ${port.width ?? port.widthExpression} bit`, moduleName: module.name })
    }
    for (const node of snapshot.hierarchy.nodes) if (`${node.name} ${node.moduleName} ${node.path}`.toLowerCase().includes(needle)) results.push({ id: `instance:${node.id}`, kind: 'instance', title: node.name, subtitle: `${node.moduleName} · ${node.path}`, nodeId: node.id, moduleName: node.moduleName })
    for (const raw of snapshot.architecture.rawConnections) if (`${raw.signalName} ${raw.connectionExpression}`.toLowerCase().includes(needle)) results.push({ id: raw.id, kind: 'signal', title: raw.signalName, subtitle: `${raw.scopeModule} · ${raw.sourceFile}:${raw.line ?? '?'}`, rawConnectionId: raw.id, physicalInterfaceId: snapshot.physicalArchitecture.interfaces.find((item) => item.rawConnectionIds.includes(raw.id))?.id })
    return results.slice(0, 120)
  }, [snapshot, query])

  const matchedIds = useMemo(() => {
    if (!snapshot || !query.trim()) return new Set<string>()
    const needle = query.trim().toLowerCase()
    const matchingModules = new Set(snapshot.modules.filter((module) => `${module.name} ${module.file} ${module.ports.map((port) => port.name).join(' ')}`.toLowerCase().includes(needle)).map((module) => module.name))
    return new Set(snapshot.hierarchy.nodes.filter((node) => `${node.name} ${node.moduleName} ${node.path}`.toLowerCase().includes(needle) || matchingModules.has(node.moduleName)).map((node) => node.id))
  }, [snapshot, query])

  const expandAncestors = useCallback((nodeId: string) => {
    setExpanded((current) => {
      const next = new Set(current)
      let node = nodeMap.get(nodeId)
      while (node) { next.add(node.id); node = node.parentId ? nodeMap.get(node.parentId) : undefined }
      return next
    })
  }, [nodeMap])

  const selectNode = useCallback((nodeId: string, navigate = false) => {
    setSelectedNodeId(nodeId); setSelectedSemanticInterfaceId(null); setSelectedRawConnectionId(null); expandAncestors(nodeId)
    const container = containerMap.get(nodeId)
    if (navigate && container) setFocusId(container.childCount > 0 ? container.id : container.parentId ?? container.id)
  }, [containerMap, expandAncestors])

  const selectSemanticInterface = useCallback((id: string) => {
    const item = semanticInterfaceMap.get(id)
    if (!item) return
    setSelectedSemanticInterfaceId(id); setSelectedRawConnectionId(null); setFocusId(item.scopeId); setRightSidebarOpen(true)
  }, [semanticInterfaceMap])

  const selectPhysicalBlock = useCallback((id: string, open = true, historyMode: 'push' | 'replace' | 'none' = 'push') => {
    const rootId = snapshot?.physicalArchitecture.drilldown.rootNodeIdsByBlock[id] ?? null
    setSelectedPhysicalBlockId(id); setSelectedPhysicalInterfaceId(null); setSelectedRawConnectionId(null); setSelectedDrillInterfaceId(null); setBusDetailTarget(null)
    if (rootId) { setDrillScopeId(rootId); setSelectedArchitectureNodeId(rootId) }
    if (open) {
      setViewMode('functional')
      if (historyMode !== 'none') writeNavigationHistory({ __rtlExplorer: true, viewMode: 'functional', physicalBlockId: id, drillScopeId: rootId, selectedArchitectureNodeId: rootId, busDetailTarget: null }, historyMode)
    }
  }, [snapshot, writeNavigationHistory])

  const selectPhysicalInterface = useCallback((id: string) => {
    if (!physicalInterfaceMap.has(id)) return
    setSelectedPhysicalInterfaceId(id); setSelectedDrillInterfaceId(null); setSelectedRawConnectionId(null); setRightSidebarOpen(false); setBusDetailTarget({ kind: 'physical', id })
    writeNavigationHistory({ __rtlExplorer: true, viewMode, physicalBlockId: selectedPhysicalBlockId, drillScopeId, selectedArchitectureNodeId, busDetailTarget: { kind: 'physical', id } })
  }, [physicalInterfaceMap, viewMode, selectedPhysicalBlockId, drillScopeId, selectedArchitectureNodeId, writeNavigationHistory])

  const navigateDrill = useCallback((id: string, historyMode: 'push' | 'replace' | 'none' = 'push') => {
    if (!drillNodeMap.has(id)) return
    if (historyMode === 'push' && drillScopeId && id !== drillScopeId) {
      let cursor = drillNodeMap.get(drillScopeId)
      let distance = 0
      while (cursor?.parentId) {
        distance += 1
        if (cursor.parentId === id) { window.history.go(-distance); return }
        cursor = drillNodeMap.get(cursor.parentId)
      }
    }
    if (drillScopeId && selectedArchitectureNodeId) setDrillSelectionByScope((current) => ({ ...current, [drillScopeId]: selectedArchitectureNodeId }))
    const selectedId = drillSelectionByScope[id] ?? id
    setViewMode('functional'); setDrillScopeId(id); setSelectedArchitectureNodeId(selectedId); setSelectedDrillInterfaceId(null); setSelectedPhysicalInterfaceId(null); setSelectedRawConnectionId(null); setBusDetailTarget(null)
    if (historyMode !== 'none') writeNavigationHistory({ __rtlExplorer: true, viewMode: 'functional', physicalBlockId: drillNodeMap.get(id)?.blockId ?? selectedPhysicalBlockId, drillScopeId: id, selectedArchitectureNodeId: selectedId, busDetailTarget: null }, historyMode)
  }, [drillNodeMap, drillScopeId, selectedArchitectureNodeId, drillSelectionByScope, selectedPhysicalBlockId, writeNavigationHistory])

  const navigateDrillParent = useCallback(() => {
    const current = drillScopeId ? drillNodeMap.get(drillScopeId) : null
    if (busDetailTarget || current) { window.history.back(); return }
    setViewMode('physical')
  }, [busDetailTarget, drillScopeId, drillNodeMap])

  const selectDrillNode = useCallback((id: string) => {
    if (!drillNodeMap.has(id)) return
    setSelectedArchitectureNodeId(id); setSelectedDrillInterfaceId(null); setSelectedPhysicalInterfaceId(null); setSelectedRawConnectionId(null); setBusDetailTarget(null); setRightSidebarOpen(true)
  }, [drillNodeMap])

  const selectDrillInterface = useCallback((id: string) => {
    if (!drillInterfaceMap.has(id)) return
    setSelectedDrillInterfaceId(id); setSelectedPhysicalInterfaceId(null); setSelectedRawConnectionId(null); setRightSidebarOpen(false); setBusDetailTarget({ kind: 'drill', id })
    writeNavigationHistory({ __rtlExplorer: true, viewMode, physicalBlockId: selectedPhysicalBlockId, drillScopeId, selectedArchitectureNodeId, busDetailTarget: { kind: 'drill', id } })
  }, [drillInterfaceMap, viewMode, selectedPhysicalBlockId, drillScopeId, selectedArchitectureNodeId, writeNavigationHistory])

  const openDrillEndpoint = useCallback((id: string) => {
    const node = drillNodeMap.get(id)
    if (!node) return
    const scopeId = node.childIds.length ? node.id : node.parentId ?? node.id
    setBusDetailTarget(null); setViewMode('functional'); setSelectedPhysicalBlockId(node.blockId)
    setDrillScopeId(scopeId)
    setSelectedArchitectureNodeId(node.id); setSelectedDrillInterfaceId(null); setSelectedPhysicalInterfaceId(null); setSelectedRawConnectionId(null)
    writeNavigationHistory({ __rtlExplorer: true, viewMode: 'functional', physicalBlockId: node.blockId, drillScopeId: scopeId, selectedArchitectureNodeId: node.id, busDetailTarget: null })
  }, [drillNodeMap, writeNavigationHistory])

  const locateRtlNode = useCallback((id: string) => { setViewMode('hierarchy'); selectNode(id, true) }, [selectNode])

  const selectSearchResult = (result: SearchResult) => {
    if (result.architectureNodeId && result.physicalBlockId) {
      const node = drillNodeMap.get(result.architectureNodeId)
      const scopeId = node?.childIds.length ? node.id : node?.parentId ?? node?.id ?? null
      const trail: ArchitectureDrillNode[] = []
      let cursor = scopeId ? drillNodeMap.get(scopeId) : undefined
      while (cursor) { trail.unshift(cursor); cursor = cursor.parentId ? drillNodeMap.get(cursor.parentId) : undefined }
      for (const ancestor of trail) writeNavigationHistory({ __rtlExplorer: true, viewMode: 'functional', physicalBlockId: result.physicalBlockId, drillScopeId: ancestor.id, selectedArchitectureNodeId: ancestor.id, busDetailTarget: null })
      setViewMode('functional'); setSelectedPhysicalBlockId(result.physicalBlockId); setDrillScopeId(scopeId); setSelectedArchitectureNodeId(result.architectureNodeId); setSelectedDrillInterfaceId(null); setSelectedPhysicalInterfaceId(null); setBusDetailTarget(null); setRightSidebarOpen(!node?.childIds.length)
      if (!trail.length) writeNavigationHistory({ __rtlExplorer: true, viewMode: 'functional', physicalBlockId: result.physicalBlockId, drillScopeId: scopeId, selectedArchitectureNodeId: result.architectureNodeId, busDetailTarget: null })
    }
    else if (result.physicalBlockId) selectPhysicalBlock(result.physicalBlockId)
    else if (result.physicalInterfaceId) { setViewMode('physical'); selectPhysicalInterface(result.physicalInterfaceId); if (result.rawConnectionId) setSelectedRawConnectionId(result.rawConnectionId) }
    else {
      const nodeId = result.nodeId ?? snapshot?.hierarchy.nodes.find((node) => node.moduleName === result.moduleName)?.id
      if (nodeId) { setViewMode('hierarchy'); selectNode(nodeId, true) }
    }
    setShowSearch(false)
  }

  const focus = focusId ? containerMap.get(focusId) ?? null : null
  const breadcrumbs = useMemo(() => {
    const result = []
    let current = focus
    while (current) { result.unshift(current); current = current.parentId ? containerMap.get(current.parentId) ?? null : null }
    return result
  }, [focus, containerMap])
  const selectedNode = selectedNodeId ? nodeMap.get(selectedNodeId) ?? null : null
  const selectedDefinition = selectedNode ? moduleMap.get(selectedNode.moduleName) ?? null : null
  const parentEdge = selectedNode ? snapshot?.hierarchy.edges.find((edge) => edge.target === selectedNode.id) ?? null : null
  const selectedSemanticInterface = selectedSemanticInterfaceId ? semanticInterfaceMap.get(selectedSemanticInterfaceId) ?? null : null
  const selectedPhysicalBlock = selectedPhysicalBlockId ? physicalBlockMap.get(selectedPhysicalBlockId) ?? null : null
  const selectedPhysicalInterface = selectedPhysicalInterfaceId ? physicalInterfaceMap.get(selectedPhysicalInterfaceId) ?? null : null
  const selectedArchitectureNode = selectedArchitectureNodeId ? drillNodeMap.get(selectedArchitectureNodeId) ?? null : null
  const selectedDrillInterface = selectedDrillInterfaceId ? drillInterfaceMap.get(selectedDrillInterfaceId) ?? null : null
  const selectedRawConnection = selectedRawConnectionId ? rawConnectionMap.get(selectedRawConnectionId) ?? null : null
  const relatedSemanticInterfaces = useMemo(() => !selectedNode ? [] : snapshot?.architecture.interfaces.filter((item) => [...item.sourceInstances, ...item.destinationInstances].some((endpoint) => endpoint.id === selectedNode.id)) ?? [], [snapshot, selectedNode])
  const selectedNodePhysicalBlocks = useMemo(() => !selectedNode ? [] : snapshot?.physicalArchitecture.rtlMappings.filter((mapping) => mapping.rtlNodeId === selectedNode.id).flatMap((mapping) => { const block = physicalBlockMap.get(mapping.blockId); return block ? [block] : [] }) ?? [], [snapshot, selectedNode, physicalBlockMap])

  const toggleNode = (nodeId: string) => setExpanded((current) => { const next = new Set(current); if (next.has(nodeId)) next.delete(nodeId); else next.add(nodeId); return next })
  const saveDescription = async (moduleName: string, description: string) => {
    if (publicSnapshotMode) {
      setToast('公网预览为只读 Snapshot；请通过 Git 分支提交说明修改')
      return
    }
    await responseJson(await fetch('/api/metadata', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ moduleName, description }) }))
    setSnapshot((current) => current ? { ...current, modules: current.modules.map((module) => module.name === moduleName ? { ...module, userDescription: description, userDescriptionUpdatedAt: new Date().toISOString() } : module) } : current)
    setToast('模块说明已保存到独立 metadata 文件')
  }
  const resetNavigation = (next: Snapshot) => {
    const root = next.architecture.containers.find((node) => !node.parentId)
    setSelectedNodeId(root?.id ?? null); setFocusId(root?.id ?? null); setSelectedSemanticInterfaceId(null); setSelectedPhysicalBlockId(null); setSelectedPhysicalInterfaceId(null); setDrillScopeId(null); setSelectedArchitectureNodeId(null); setSelectedDrillInterfaceId(null); setDrillSelectionByScope({}); setSelectedRawConnectionId(null); setBusDetailTarget(null); setViewMode('physical')
    setExpanded(new Set(next.hierarchy.nodes.filter((node) => node.depth <= 1).map((node) => node.id)))
  }
  const changeTop = async (top: string) => {
    if (publicSnapshotMode) return
    setTopBusy(true); setError('')
    try { const next = await responseJson<Snapshot>(await fetch('/api/select-top', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ top }) })); setSnapshot(next); resetNavigation(next); setConfig((current) => current ? { ...current, preferredTop: top } : current) }
    catch (changeError) { setError((changeError as Error).message) } finally { setTopBusy(false) }
  }
  const rescan = async () => {
    if (!config) return
    setRescanBusy(true); setError(''); setScanState({ running: true, phase: 'starting', completed: 0, total: 0, message: 'Starting RTL scan', error: null })
    try { await responseJson(await fetch('/api/rescan', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(config) })); const next = await loadSnapshot(); resetNavigation(next); setSettingsOpen(false); setToast('RTL 已重新扫描，Physical Architecture Model 已更新'); setScanState(await responseJson<ScanState>(await fetch('/api/status'))) }
    catch (scanError) { setError((scanError as Error).message); setScanState(await responseJson<ScanState>(await fetch('/api/status')).catch(() => scanState as ScanState)) } finally { setRescanBusy(false) }
  }
  const importSnapshot = async (file: File) => {
    try { const body = JSON.parse(await file.text()); await responseJson(await fetch('/api/import-snapshot', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) })); const next = await loadSnapshot(); resetNavigation(next); setToast('Snapshot 已导入并重建语义与物理架构模型') }
    catch (importError) { setError((importError as Error).message) }
  }
  const switchView = (mode: ViewMode) => {
    let blockId = selectedPhysicalBlockId
    let scopeId = drillScopeId
    let architectureNodeId = selectedArchitectureNodeId
    if (mode === 'functional' && !selectedPhysicalBlockId) {
      const firstBlock = snapshot?.physicalArchitecture.blocks.find((item) => item.primary)
      if (firstBlock) {
        blockId = firstBlock.id
        scopeId = snapshot?.physicalArchitecture.drilldown.rootNodeIdsByBlock[firstBlock.id] ?? null
        architectureNodeId = scopeId
        selectPhysicalBlock(firstBlock.id, false, 'none')
      }
    }
    setBusDetailTarget(null); setDecoderFocusMode(false); setViewMode(mode)
    writeNavigationHistory({ __rtlExplorer: true, viewMode: mode, physicalBlockId: blockId, drillScopeId: scopeId, selectedArchitectureNodeId: architectureNodeId, busDetailTarget: null })
  }

  if (error && !snapshot) return <main className="fatal-screen"><div><span>RTL EXPLORER</span><h1>无法载入架构数据</h1><p>{error}</p><button onClick={() => window.location.reload()}>重试</button></div></main>
  if (!snapshot || !focusId) return <main className="loading-screen"><div className="scan-orbit" /><h1>LPU RTL Architecture Explorer</h1><p>{scanState?.message ?? '正在载入真实 RTL 架构…'}</p></main>

  const physicalMode = viewMode !== 'hierarchy' && viewMode !== 'configuration' && viewMode !== 'isa'
  const configurationMode = viewMode === 'configuration'
  const openIsa = (fu: IsaFu) => { setIsaInitialFu(fu); switchView('isa') }
  const openIsaArchitecture = (fu: IsaFu) => {
    const block = snapshot.physicalArchitecture.blocks.find((item) => item.kind === fu.toLowerCase())
    if (block) selectPhysicalBlock(block.id)
  }
  const openIsaDecoder = (fu: 'MEM' | 'MXM') => {
    const node = snapshot.physicalArchitecture.drilldown.nodes.find((item) => item.displayName.includes(fu === 'MEM' ? 'MEM Macro Decoder' : 'Shared MXM Macro Decoder Architecture'))
    if (node) { setSelectedPhysicalBlockId(node.blockId); navigateDrill(node.id) }
  }
  return <div className={`app-shell physical-era font-${fontScale} ${decoderFocusMode ? 'decoder-focus-mode' : ''}`}>
    <header className="topbar"><div className="brand"><div className="brand-mark"><span /><span /><span /></div><div><h1>LPU RTL</h1><p>Architecture Explorer</p></div></div><nav className="view-switcher" aria-label="架构视图">{viewOptions.map((option) => <button key={option.value} className={viewMode === option.value ? 'active' : ''} onClick={() => switchView(option.value)}><span>{option.label}</span><small>{option.hint}</small></button>)}</nav>{!decoderFocusMode && <div className="topbar-actions"><div className="font-scale-control" title="全局字体大小"><button className={fontScale === 'compact' ? 'active' : ''} onClick={() => setFontScale('compact')}>A−</button><button className={fontScale === 'comfortable' ? 'active' : ''} onClick={() => setFontScale('comfortable')}>A</button><button className={fontScale === 'large' ? 'active' : ''} onClick={() => setFontScale('large')}>A＋</button></div><button className="icon-button" onClick={() => setWarningsOpen(true)} title="解析告警"><span>△</span><b>{snapshot.warnings.length}</b></button>{publicSnapshotMode ? <><span className="wip-status">PUBLIC SNAPSHOT</span><a className="quiet-button export-action" href="/data/architecture-snapshot.json" download>导出 Snapshot</a></> : <><button className="quiet-button import-action" onClick={() => importInput.current?.click()}>导入</button><a className="quiet-button export-action" href="/api/export" download>导出 Snapshot</a><button className="primary-button" onClick={() => setSettingsOpen(true)}>重新扫描 RTL</button><input ref={importInput} type="file" accept="application/json,.json" hidden onChange={(event) => event.target.files?.[0] && importSnapshot(event.target.files[0])} /></>}</div>}</header>
    {!decoderFocusMode && <div className="status-strip"><span><i className="status-dot" /> SOURCE <code>{snapshot.project.projectRoot}</code></span><span>TOP <strong>{snapshot.summary.selectedTop}</strong></span><span className="wip-status" title={snapshot.project.statusNote ?? ''}>WIP RTL SNAPSHOT</span><span>FUNCTIONAL BLOCKS <strong>{snapshot.physicalArchitecture.summary.functionalBlockCount}</strong></span><span>DRILL NODES <strong>{snapshot.physicalArchitecture.drilldown.summary.nodeCount}</strong></span><span>SEMANTIC BUSES <strong>{snapshot.physicalArchitecture.drilldown.summary.interfaceCount}</strong></span><span className="status-time">SCAN {new Date(snapshot.generatedAt).toLocaleString('zh-CN', { hour12: false })}</span></div>}
    {error && <div className="error-banner global-error"><span>{error}</span><button onClick={() => setError('')}>×</button></div>}
    <main className={`workspace ${configurationMode ? 'configuration-workspace' : ''} ${viewMode === 'isa' ? 'isa-workspace' : ''} ${decoderFocusMode ? 'decoder-focus-workspace' : ''} ${leftSidebarOpen ? 'left-sidebar-open' : ''} ${rightSidebarOpen ? 'right-sidebar-open' : ''}`}>
      <aside className={`left-panel auto-sidebar ${leftSidebarOpen ? 'is-open' : ''}`}><button className="sidebar-edge-trigger left-edge" onClick={() => setLeftSidebarOpen((value) => !value)} aria-label={leftSidebarOpen ? '收起左侧导航' : '展开左侧导航'}>{leftSidebarOpen ? '‹' : '›'}</button><div className="search-block"><div className="search-box"><span>⌕</span><input value={query} onChange={(event) => { setQuery(event.target.value); setShowSearch(true) }} onFocus={() => setShowSearch(true)} placeholder="搜索功能块、RTL、接口、信号…" />{query && <button onClick={() => setQuery('')}>×</button>}</div>{showSearch && query.trim() && <div className="search-results"><div className="search-results-head"><span>{searchResults.length} 个结果</span><button onClick={() => setShowSearch(false)}>关闭</button></div>{searchResults.length ? searchResults.map((result) => <button key={result.id} onClick={() => selectSearchResult(result)}><span className={`search-kind ${result.kind}`}>{result.kind}</span><span><strong>{result.title}</strong><small>{result.subtitle}</small></span></button>) : <p>没有匹配项</p>}</div>}{!physicalMode && <label className="check-row"><input type="checkbox" checked={hideUnrelated} onChange={(event) => setHideUnrelated(event.target.checked)} /><span>搜索时隐藏无关模块</span></label>}</div>
        {physicalMode ? <><div className="left-section-heading"><div><span>PHYSICAL REGIONS</span><small>功能拓扑导航 · RTL-backed parameters</small></div></div><div className="tree-scroll"><PhysicalNavigator regions={snapshot.physicalArchitecture.regions} blocks={snapshot.physicalArchitecture.blocks} selectedBlockId={selectedPhysicalBlockId} query={query} onSelectBlock={selectPhysicalBlock} /></div><div className="left-footer physical-evidence-legend"><label>EVIDENCE</label><div className="legend"><span><i className="evidence-dot status-rtl-confirmed" />RTL confirmed</span><span><i className="evidence-dot status-architecture-inferred" />architecture inferred</span><span><i className="evidence-dot status-needs-review" />needs review</span></div></div></> : <><div className="left-section-heading"><div><span>RTL HIERARCHY</span><small>源码导航 · {snapshot.hierarchy.nodes.length} symbolic instances</small></div><div className="tree-actions"><button onClick={() => setExpanded(new Set(snapshot.hierarchy.nodes.map((node) => node.id)))}>＋</button><button onClick={() => setExpanded(new Set(snapshot.hierarchy.nodes.filter((node) => node.depth === 0).map((node) => node.id)))}>−</button></div></div><div className="tree-scroll"><HierarchyTree nodes={hideUnrelated && query.trim() ? snapshot.hierarchy.nodes.filter((node) => matchedIds.has(node.id) || [...matchedIds].some((id) => id.startsWith(`${node.id}.`))) : snapshot.hierarchy.nodes} modules={moduleMap} selectedId={selectedNodeId} expanded={expanded} matchedIds={matchedIds} legacyIds={legacyIds} onSelect={(id) => selectNode(id, true)} onToggle={toggleNode} /></div><div className="left-footer"><label>TOP MODULE</label><select value={snapshot.summary.selectedTop ?? ''} disabled={topBusy || publicSnapshotMode} title={publicSnapshotMode ? '公网 Snapshot 使用构建时选定的 Top' : undefined} onChange={(event) => changeTop(event.target.value)}>{snapshot.modules.slice().sort((a, b) => a.name.localeCompare(b.name)).map((module) => <option key={module.id} value={module.name}>{module.name}</option>)}</select></div></>}
      </aside>
      <section className="graph-panel">
        {!decoderFocusMode && <div className={`graph-toolbar architecture-toolbar ${viewMode === 'functional' ? 'functional-toolbar' : ''}`}>{viewMode === 'hierarchy' ? <><div className="scope-navigation"><span className="eyebrow">RTL HIERARCHY</span><div className="breadcrumbs">{breadcrumbs.map((item, index) => <button key={item.id} onClick={() => { setFocusId(item.id); selectNode(item.id) }} className={index === breadcrumbs.length - 1 ? 'active' : ''}>{item.displayName}</button>)}</div><strong>Containment uses nesting; semantic buses remain traceable in the inspector.</strong></div><div className="graph-controls-row"><label className="legacy-toggle"><input type="checkbox" checked={showLegacy} onChange={(event) => setShowLegacy(event.target.checked)} /><span>显示辅助 direct-instantiation 路径</span></label></div></> : <><div className="scope-navigation"><span className="eyebrow">{viewMode === 'functional' ? 'FUNCTIONAL BLOCK DETAIL' : 'LPU SYSTEM ARCHITECTURE'}</span><strong>{viewMode === 'functional' ? selectedPhysicalBlock?.displayName ?? 'Select a block' : 'West Hemisphere · Central VXM · East Hemisphere'}</strong></div>{viewMode !== 'functional' && <div className="graph-controls-row physical-controls"><div className="plane-switch"><button className={planeFilter === 'all' ? 'active' : ''} onClick={() => setPlaneFilter('all')}>ALL</button><button className={planeFilter === 'data' ? 'active' : ''} onClick={() => setPlaneFilter('data')}>DATA PLANE</button><button className={planeFilter === 'control' ? 'active' : ''} onClick={() => setPlaneFilter('control')}>CONTROL PLANE</button></div><input value={signalQuery} onChange={(event) => setSignalQuery(event.target.value)} placeholder="筛选物理接口…" /></div>}</>}
        </div>}
        <div className={`graph-canvas ${viewMode === 'functional' ? 'functional-canvas' : ''} ${configurationMode ? 'configuration-canvas' : ''}`}>
          {configurationMode ? <ConfigurationOverview model={snapshot.configurationOverview} />
            : viewMode === 'isa' ? <IsaExplorer initialFu={isaInitialFu} onOpenArchitecture={openIsaArchitecture} onOpenDecoder={openIsaDecoder} />
            : viewMode === 'functional' && selectedPhysicalBlock && drillScopeId ? <FunctionalBlockDetail block={selectedPhysicalBlock} nodes={snapshot.physicalArchitecture.drilldown.nodes.filter((node) => node.blockId === selectedPhysicalBlock.id)} drillInterfaces={snapshot.physicalArchitecture.drilldown.interfaces.filter((item) => item.blockId === selectedPhysicalBlock.id)} physicalInterfaces={snapshot.physicalArchitecture.interfaces} rawConnections={snapshot.architecture.rawConnections} currentNodeId={drillScopeId} selectedNodeId={selectedArchitectureNodeId} selectedInterfaceId={selectedDrillInterfaceId} selectedPhysicalInterfaceId={selectedPhysicalInterfaceId} viewState={drillViewportState.current} onBack={navigateDrillParent} onNavigate={navigateDrill} onSelectNode={selectDrillNode} onSelectInterface={selectDrillInterface} onSelectPhysicalInterface={selectPhysicalInterface} onOpenIsa={() => openIsa(selectedPhysicalBlock.kind.toUpperCase() as IsaFu)} />
              : viewMode === 'hierarchy' ? <ArchitectureGraph containers={snapshot.architecture.containers} interfaces={snapshot.architecture.interfaces} rawConnections={snapshot.architecture.rawConnections} modules={moduleMap} focusId={focusId} mode="containment" showLegacy={showLegacy} categoryFilter="all" signalQuery="" selectedNodeId={selectedNodeId} selectedInterfaceId={selectedSemanticInterfaceId} selectedRawConnectionId={selectedRawConnectionId} matchedIds={matchedIds} onSelectNode={(id) => selectNode(id)} onOpenContainer={setFocusId} onSelectInterface={selectSemanticInterface} />
                 : <PhysicalArchitectureGraph regions={snapshot.physicalArchitecture.regions} blocks={snapshot.physicalArchitecture.blocks} interfaces={snapshot.physicalArchitecture.interfaces} drillNodes={snapshot.physicalArchitecture.drilldown.nodes} drillInterfaces={snapshot.physicalArchitecture.drilldown.interfaces} frontends={snapshot.configurationOverview.frontends} rawConnections={snapshot.architecture.rawConnections} selectedBlockId={selectedPhysicalBlockId} selectedInterfaceId={selectedPhysicalInterfaceId} selectedRawConnectionId={selectedRawConnectionId} planeFilter={planeFilter} signalQuery={signalQuery} connectivityMode={false} onOpenBlock={selectPhysicalBlock} onSelectInterface={selectPhysicalInterface} onSelectDrillInterface={selectDrillInterface} onFocusModeChange={setDecoderFocusMode} />}
          {!configurationMode && busDetailTarget && <BusDetailView physicalInterface={busDetailTarget.kind === 'physical' ? physicalInterfaceMap.get(busDetailTarget.id) ?? null : null} drillInterface={busDetailTarget.kind === 'drill' ? drillInterfaceMap.get(busDetailTarget.id) ?? null : null} blocks={physicalBlockMap} drillNodes={drillNodeMap} hierarchyNodes={nodeMap} rawConnections={rawConnectionMap} onBack={() => window.history.back()} onOpenPhysicalEndpoint={(id) => selectPhysicalBlock(id)} onOpenDrillEndpoint={openDrillEndpoint} onLocateRtlNode={locateRtlNode} />}
        </div>
        <div className={`graph-legend-bar physical-graph-legend ${viewMode === 'functional' ? 'functional-legend' : ''}`}>{viewMode === 'hierarchy' ? <><span><i className="containment-swatch" />RTL containment = 矩形嵌套</span><span>纯组织 wrapper 只在此视图保留</span></> : <><span><i className="physical-data-swatch" />Data plane · East/West 独立方向</span><span><i className="physical-control-swatch" />Control plane · issue/load</span><span>参考图仅用于形式；所有参数以当前 RTL 为准</span></>}</div>
      </section>
      <div className={`right-sidebar-shell auto-sidebar ${rightSidebarOpen ? 'is-open' : ''}`}><button className="sidebar-edge-trigger right-edge" onClick={() => setRightSidebarOpen((value) => !value)} aria-label={rightSidebarOpen ? '收起右侧检查器' : '展开右侧检查器'}>{rightSidebarOpen ? '›' : '‹'}</button>{viewMode === 'hierarchy' ? <Inspector node={selectedNode} definition={selectedDefinition} parentEdge={parentEdge} selectedInterface={selectedSemanticInterface} selectedRawConnection={selectedRawConnection} rawConnections={rawConnectionMap} relatedInterfaces={relatedSemanticInterfaces} warnings={snapshot.warnings} onSelectInterface={selectSemanticInterface} onSelectRawConnection={setSelectedRawConnectionId} onSaveDescription={saveDescription} physicalBlocks={selectedNodePhysicalBlocks} onSelectPhysicalBlock={selectPhysicalBlock} /> : <PhysicalInspector block={selectedPhysicalBlock} selectedInterface={busDetailTarget ? null : selectedPhysicalInterface} architectureNode={viewMode === 'functional' ? selectedArchitectureNode : null} selectedDrillInterface={busDetailTarget ? null : viewMode === 'functional' ? selectedDrillInterface : null} drillNodes={drillNodeMap} selectedRawConnection={busDetailTarget ? null : selectedRawConnection} blocks={physicalBlockMap} rawConnections={rawConnectionMap} modules={moduleMap} onSelectInterface={selectPhysicalInterface} onSelectRawConnection={setSelectedRawConnectionId} onLocateRtlNode={locateRtlNode} />}</div>
    </main>
    {settingsOpen && config && <div className="modal-backdrop" onMouseDown={(event) => event.target === event.currentTarget && !rescanBusy && setSettingsOpen(false)}><section className="modal scan-modal"><div className="modal-heading"><div><span className="eyebrow">LOCAL SCAN CONFIGURATION</span><h2>重新扫描 RTL</h2></div><button disabled={rescanBusy} onClick={() => setSettingsOpen(false)}>×</button></div><p>只读取指定源码；生成数据写入 Explorer 自己的 <code>data/</code>，不会修改 RTL、filelist 或 Testbench。</p><label>RTL 工程根目录<input value={config.projectRoot} onChange={(event) => setConfig({ ...config, projectRoot: event.target.value })} /></label><div className="form-grid"><label>源码目录<input value={config.sourceDirectory} onChange={(event) => setConfig({ ...config, sourceDirectory: event.target.value })} /></label><label>主 filelist<input value={config.filelist} onChange={(event) => setConfig({ ...config, filelist: event.target.value })} /></label></div><label>Verible 解析器<input value={config.veribleExecutable} onChange={(event) => setConfig({ ...config, veribleExecutable: event.target.value })} /></label>{rescanBusy && scanState && <div className="scan-progress"><div><span>{scanState.message}</span><strong>{scanState.total ? Math.round(scanState.completed / scanState.total * 100) : 0}%</strong></div><progress max={scanState.total || 1} value={scanState.completed} /></div>}<div className="modal-actions"><button className="quiet-button" disabled={rescanBusy} onClick={() => setSettingsOpen(false)}>取消</button><button className="primary-button" disabled={rescanBusy} onClick={rescan}>{rescanBusy ? '解析中…' : '开始真实 RTL 扫描'}</button></div></section></div>}
    {warningsOpen && <div className="drawer-backdrop" onMouseDown={(event) => event.target === event.currentTarget && setWarningsOpen(false)}><aside className="warning-drawer"><div className="modal-heading"><div><span className="eyebrow">PARSER & MAPPING EVIDENCE</span><h2>解析配置与告警</h2></div><button onClick={() => setWarningsOpen(false)}>×</button></div><section className="drawer-summary"><div><span>Parser</span><code>{snapshot.configuration.parserVersion}</code></div><div><span>Filelist</span><code>{snapshot.project.filelist}</code></div><div><span>Physical model</span><p>{snapshot.physicalArchitecture.policy.accuracyStatement}</p></div></section><div className="warning-list">{snapshot.warnings.length ? snapshot.warnings.map((warning, index) => <article key={`${warning.code}-${index}`} className={warning.severity === 'error' ? 'error' : ''}><div><code>{warning.code}</code><span>{warning.severity}</span></div><p>{warning.message}</p><small>{warning.file}{warning.line ? `:${warning.line}` : ''}</small></article>) : <div className="inline-empty">当前没有解析告警。</div>}</div></aside></div>}
    {toast && <div className="toast">✓ {toast}</div>}
  </div>
}
