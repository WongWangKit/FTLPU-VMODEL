import { useEffect, useMemo, useRef, useState } from 'react'
import type { ReactFlowInstance, Viewport } from '@xyflow/react'
import FunctionalConnectivityGraph from './FunctionalConnectivityGraph'
import MemFunctionalExplorer from './MemFunctionalExplorer'
import MxmFunctionalExplorer from './MxmFunctionalExplorer'
import SxmFunctionalExplorer from './SxmFunctionalExplorer'
import VxmFunctionalExplorer from './VxmFunctionalExplorer'
import FuArchitectureOverview from './FuArchitectureOverview'
import { buildHardwareQuickSpec } from '../lib/hardware-spec'
import type { ArchitectureDrillInterface, ArchitectureDrillNode, PhysicalFunctionalBlock, PhysicalInterface, RawConnection } from '../types'

interface Props {
  block: PhysicalFunctionalBlock
  nodes: ArchitectureDrillNode[]
  drillInterfaces: ArchitectureDrillInterface[]
  physicalInterfaces: PhysicalInterface[]
  rawConnections: RawConnection[]
  currentNodeId: string
  selectedNodeId: string | null
  selectedInterfaceId: string | null
  selectedPhysicalInterfaceId: string | null
  viewState: Map<string, Viewport>
  onBack: () => void
  onNavigate: (id: string) => void
  onSelectNode: (id: string) => void
  onSelectInterface: (id: string) => void
  onSelectPhysicalInterface: (id: string) => void
  onOpenIsa: () => void
}

function levelLabel(level: ArchitectureDrillNode['architectureLevel']) {
  return level === 'functional' ? 'L2' : level === 'structural' ? 'L3' : 'L4'
}

function isStorageNode(node: ArchitectureDrillNode) {
  if (node.id.startsWith('arch:control:qctl') && node.childIds.length) return false
  return /(fifo|queue|storage)/i.test(`${node.nodeType} ${node.displayName}`) && !/reserved/i.test(node.nodeType)
}

function StorageNodeDetail({ node, nodes, interfaces, onOpenInspector }: { node: ArchitectureDrillNode; nodes: Map<string, ArchitectureDrillNode>; interfaces: ArchitectureDrillInterface[]; onOpenInspector: () => void }) {
  const scopeIds = new Set<string>([node.id])
  let ancestor = node.parentId ? nodes.get(node.parentId) : undefined
  while (ancestor) { scopeIds.add(ancestor.id); ancestor = ancestor.parentId ? nodes.get(ancestor.parentId) : undefined }
  const connected = interfaces.filter((item) => scopeIds.has(item.sourceNodeId) || scopeIds.has(item.destinationNodeId))
  const producers = [...new Set(connected.filter((item) => scopeIds.has(item.destinationNodeId) && !scopeIds.has(item.sourceNodeId)).map((item) => nodes.get(item.sourceNodeId)?.displayName ?? item.sourceNodeId))]
  const consumers = [...new Set(connected.filter((item) => scopeIds.has(item.sourceNodeId) && !scopeIds.has(item.destinationNodeId)).map((item) => nodes.get(item.destinationNodeId)?.displayName ?? item.destinationNodeId))]
  const spec = buildHardwareQuickSpec(node)
  return <div className="storage-node-detail">
    <header><span>{spec.eyebrow}</span><h2>{node.displayName}</h2><p>基础存储节点默认只展示核心硬件规格；完整 RTL 映射保留在右侧高级证据中。</p></header>
    <section className="storage-quick-spec"><span>{spec.primaryLabel}</span><strong>{spec.primaryValue}</strong>{spec.needsReview && <small>Needs Review · 当前快照无法静态求值的部分保留参数表达式</small>}</section>
    <section className="storage-flow"><div><span>PRODUCER</span>{producers.length ? producers.map((item) => <strong key={item}>{item}</strong>) : <strong>Scope input / Needs Review</strong>}</div><b>→</b><div><span>STORED CONTENT</span><strong>{node.description}</strong></div><b>→</b><div><span>CONSUMER</span>{consumers.length ? consumers.map((item) => <strong key={item}>{item}</strong>) : <strong>Scope output / Needs Review</strong>}</div></section>
    <button className="storage-inspector-button" onClick={onOpenInspector}>打开规格 Inspector</button>
  </div>
}

export default function FunctionalBlockDetail({ block, nodes, drillInterfaces, physicalInterfaces, rawConnections, currentNodeId, selectedNodeId, selectedInterfaceId, selectedPhysicalInterfaceId, viewState, onBack, onNavigate, onSelectNode, onSelectInterface, onSelectPhysicalInterface, onOpenIsa }: Props) {
  const [zoom, setZoom] = useState(1)
  const [fullscreen, setFullscreen] = useState(false)
  const workspaceRef = useRef<HTMLDivElement>(null)
  const flowRef = useRef<ReactFlowInstance<any, any> | null>(null)
  const nodeMap = useMemo(() => new Map(nodes.map((node) => [node.id, node])), [nodes])
  const blockMap = useMemo(() => new Map([[block.id, block]]), [block])
  const current = nodeMap.get(currentNodeId)
  const presentation = useMemo(() => {
    const baseChildren = current?.childIds.map((id) => nodeMap.get(id)).filter(Boolean) as ArchitectureDrillNode[] ?? []
    const directChildIds = new Set(baseChildren.map((item) => item.id))
    const baseInterfaces = drillInterfaces.filter((item) => item.scopeNodeId === currentNodeId)
    const stageInterfaces = !current?.parentId && ['mxm', 'sxm', 'vxm'].includes(block.kind)
      ? baseInterfaces.filter((item) => directChildIds.has(item.sourceNodeId) && directChildIds.has(item.destinationNodeId))
      : baseInterfaces
    if (!current || current.parentId || block.kind !== 'mem') return { children: baseChildren, interfaces: stageInterfaces }
    const macro = baseChildren.find((item) => item.nodeType === 'macro-decode')
    if (!macro) return { children: baseChildren, interfaces: baseInterfaces }
    const macroChildren = macro.childIds.map((id) => nodeMap.get(id)).filter(Boolean) as ArchitectureDrillNode[]
    const wordFifo = macroChildren.find((item) => /word fifo/i.test(item.displayName))
    const scheduler = macroChildren.find((item) => /scheduler/i.test(item.displayName))
    if (!wordFifo || !scheduler) return { children: baseChildren, interfaces: baseInterfaces }
    return {
      children: baseChildren.flatMap((item) => item.id === macro.id ? macroChildren : [item]),
      interfaces: [
        ...baseInterfaces.map((item) => item.destinationNodeId === macro.id ? { ...item, destinationNodeId: wordFifo.id, name: 'Fetched Macro Words → Word FIFO' } : item.sourceNodeId === macro.id ? { ...item, sourceNodeId: scheduler.id, name: 'Macro Scheduler → MEM64 / Native32 Adapter' } : item),
        ...drillInterfaces.filter((item) => item.scopeNodeId === macro.id),
      ],
    }
  }, [block.kind, current, currentNodeId, drillInterfaces, nodeMap])
  const children = presentation.children
  const localInterfaces = presentation.interfaces
  const breadcrumbs = useMemo(() => {
    const result: ArchitectureDrillNode[] = []
    let cursor: ArchitectureDrillNode | undefined = current
    while (cursor) { result.unshift(cursor); cursor = cursor.parentId ? nodeMap.get(cursor.parentId) : undefined }
    return result
  }, [current, nodeMap])

  useEffect(() => {
    const handler = () => setFullscreen(document.fullscreenElement === workspaceRef.current)
    document.addEventListener('fullscreenchange', handler)
    return () => document.removeEventListener('fullscreenchange', handler)
  }, [])
  useEffect(() => {
    const handler = (event: KeyboardEvent) => { if (event.key === 'Escape' && fullscreen && !document.fullscreenElement) setFullscreen(false) }
    document.addEventListener('keydown', handler)
    return () => document.removeEventListener('keydown', handler)
  }, [fullscreen])

  if (!current) return <div className="inline-empty">当前功能块缺少多级架构节点。</div>

  const rememberView = () => {
    const viewport = flowRef.current?.getViewport()
    if (viewport) viewState.set(currentNodeId, viewport)
  }
  const navigate = (id: string) => { rememberView(); onNavigate(id) }
  const openNode = (node: ArchitectureDrillNode) => node.childIds.length && !isStorageNode(node) ? navigate(node.id) : onSelectNode(node.id)
  const toggleFullscreen = async () => {
    if (document.fullscreenElement) await document.exitFullscreen()
    else if (fullscreen) setFullscreen(false)
    else {
      try { await workspaceRef.current?.requestFullscreen(); if (!document.fullscreenElement) setFullscreen(true) }
      catch { setFullscreen(true) }
    }
  }

  return <div className={`drilldown-workspace graph-first-workspace ${fullscreen ? 'is-fullscreen' : ''}`} ref={workspaceRef} data-block-id={block.id}>
    <div className="drill-commandbar">
      <button className="drill-back" onClick={() => { rememberView(); onBack() }} title={current.parentId ? `返回 ${nodeMap.get(current.parentId)?.displayName ?? '上一级'}` : '返回 L1 Physical Architecture'}>← {current.parentId ? levelLabel(nodeMap.get(current.parentId)?.architectureLevel ?? 'functional') : 'L1'} · {current.parentId ? (nodeMap.get(current.parentId)?.displayName ?? '上一级') : 'LPU'}</button>
      <nav className="drill-breadcrumbs"><button onClick={onBack}>LPU</button>{breadcrumbs.map((item) => <button key={item.id} className={item.id === current.id ? 'active' : ''} onClick={() => navigate(item.id)}><b>›</b>{item.displayName}</button>)}</nav>
      <div className="drill-current-title"><span>{levelLabel(current.architectureLevel)}</span><strong>{current.displayName}</strong><i className={`evidence-dot status-${current.confidenceStatus}`} /></div>
      {(['mem', 'mxm', 'vxm', 'sxm'] as string[]).includes(block.kind) && <button className="drill-isa-link" onClick={onOpenIsa}>ISA 字段 →</button>}
      <div className="drill-zoom" aria-label="画布缩放"><button onClick={() => flowRef.current?.zoomOut()} title="Zoom Out">−</button><span>{Math.round(zoom * 100)}%</span><button onClick={() => flowRef.current?.zoomIn()} title="Zoom In">＋</button><button onClick={() => flowRef.current?.fitView(current.layout === 'qctl-overview' ? { padding: .08, maxZoom: 1.05 } : { padding: .22, maxZoom: .92 })} title="Fit current topology">FIT</button><button onClick={toggleFullscreen} title="全屏架构画布">{fullscreen ? 'EXIT' : '⛶'}</button></div>
    </div>

    <div className={`connectivity-canvas-shell ${block.kind === 'mem' || block.kind === 'mxm' || block.kind === 'sxm' || block.kind === 'vxm' ? 'custom-explorer-scroll' : 'react-flow-explorer'}`}>
      {!current.parentId && (block.kind === 'mem' || block.kind === 'sxm' || block.kind === 'vxm') && <FuArchitectureOverview
        key={`${block.kind}:${block.regionId}`}
        kind={block.kind}
        block={block}
        nodes={nodeMap}
        onNavigate={navigate}
        onSelectNode={onSelectNode}
        onReady={async (instance) => { flowRef.current = instance; const saved = viewState.get(currentNodeId); if (saved) await instance.setViewport(saved); else await instance.fitView({ padding: .12, maxZoom: 1 }); setZoom(instance.getZoom()) }}
        onViewportChange={(viewport) => { viewState.set(currentNodeId, viewport); setZoom(viewport.zoom) }}
      />}
      {block.kind === 'mem' ? <MemFunctionalExplorer
        block={block}
        current={current}
        nodes={nodeMap}
        onNavigate={navigate}
        onSelectNode={onSelectNode}
      /> : block.kind === 'mxm' ? <MxmFunctionalExplorer
        block={block}
        current={current}
        nodes={nodeMap}
        onNavigate={navigate}
        onSelectNode={onSelectNode}
      /> : block.kind === 'sxm' ? <SxmFunctionalExplorer
        block={block}
        current={current}
        onSelectNode={onSelectNode}
      /> : block.kind === 'vxm' ? <VxmFunctionalExplorer
        block={block}
        current={current}
        nodes={nodeMap}
        onNavigate={navigate}
        onSelectNode={onSelectNode}
      /> : children.length ? <FunctionalConnectivityGraph
        current={current}
        children={children}
        allNodes={nodeMap}
        localInterfaces={localInterfaces}
        physicalInterfaces={physicalInterfaces}
        rawConnections={rawConnections}
        blocks={blockMap}
        selectedNodeId={selectedNodeId}
        selectedInterfaceId={selectedInterfaceId}
        selectedPhysicalInterfaceId={selectedPhysicalInterfaceId}
        savedViewport={viewState.get(currentNodeId)}
        onReady={async (instance) => { flowRef.current = instance; const saved = viewState.get(currentNodeId); if (current.layout === 'qctl-overview') await instance.fitView({ padding: .08, maxZoom: 1.05 }); else if (saved) await instance.setViewport(saved); else await instance.fitView({ padding: .22, maxZoom: .92 }); setZoom(instance.getZoom()) }}
        onViewportChange={(viewport) => { viewState.set(currentNodeId, viewport); setZoom(viewport.zoom) }}
        onOpenNode={openNode}
        onOpenInterface={(id, physical) => physical ? onSelectPhysicalInterface(id) : onSelectInterface(id)}
      /> : isStorageNode(current) ? <StorageNodeDetail node={current} nodes={nodeMap} interfaces={drillInterfaces} onOpenInspector={() => onSelectNode(current.id)} /> : <div className="drill-leaf-view"><span>{levelLabel(current.architectureLevel)}</span><h3>{current.displayName}</h3><p>当前快照在此处没有更细的架构容器。完整说明、参数和 RTL 位置保留在 Inspector。</p><button onClick={() => onSelectNode(current.id)}>查看详细证据</button></div>}
    </div>
  </div>
}
