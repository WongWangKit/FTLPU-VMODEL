import { memo, useMemo } from 'react'
import {
  Background,
  BaseEdge,
  Controls,
  EdgeLabelRenderer,
  Handle,
  MarkerType,
  MiniMap,
  Position,
  ReactFlow,
  getSmoothStepPath,
  type Edge,
  type EdgeProps,
  type Node,
  type NodeProps,
} from '@xyflow/react'
import type {
  ArchitectureContainer,
  ModuleDefinition,
  RawConnection,
  SemanticInterface,
} from '../types'

interface ArchitectureNodeData extends Record<string, unknown> {
  container?: ArchitectureContainer
  definition?: ModuleDefinition
  title: string
  subtitle: string
  role: string
  childCount: number
  selected: boolean
  matched: boolean
  signalHighlighted: boolean
  legacy: boolean
  root: boolean
  boundary: boolean
}

interface BusEdgeData extends Record<string, unknown> {
  interface: SemanticInterface
  selected: boolean
  lane: number
  showLabel: boolean
  onSelect: (id: string) => void
}

const FrameNode = memo(({ data }: NodeProps<Node<ArchitectureNodeData>>) => (
  <div className={`architecture-frame ${data.root ? 'root-frame' : ''} ${data.legacy ? 'legacy-frame' : ''} ${data.selected ? 'selected' : ''}`}>
    <div className="frame-heading">
      <span>{data.title}</span>
      <small>{data.subtitle}</small>
      {data.legacy && <b>辅助路径</b>}
    </div>
    {!data.root && <>
      <Handle type="target" position={Position.Left} id="target" />
      <Handle type="source" position={Position.Right} id="source" />
    </>}
  </div>
))

FrameNode.displayName = 'FrameNode'

const ModuleNode = memo(({ data }: NodeProps<Node<ArchitectureNodeData>>) => {
  const inputCount = data.definition?.ports.filter((port) => port.direction === 'input').length ?? 0
  const outputCount = data.definition?.ports.filter((port) => port.direction === 'output').length ?? 0
  return (
    <div className={`architecture-module role-${data.role} ${data.selected ? 'selected' : ''} ${data.matched ? 'matched' : ''} ${data.signalHighlighted ? 'signal-highlighted' : ''} ${data.legacy ? 'legacy' : ''}`}>
      <Handle type="target" position={Position.Left} id="target" />
      <div className="architecture-module-topline">
        <span className="role-label">{data.role}</span>
        {data.container?.generated && <span className="template-label">TEMPLATE [*]</span>}
        {data.legacy && <span className="legacy-label">LEGACY</span>}
      </div>
      <strong>{data.title}</strong>
      <small>{data.subtitle}</small>
      <div className="architecture-module-stats">
        <span>IN {inputCount}</span><span>OUT {outputCount}</span><span>SUB {data.childCount}</span>
      </div>
      {data.childCount > 0 && <div className="open-hint">点击进入内部</div>}
      <Handle type="source" position={Position.Right} id="source" />
    </div>
  )
})

ModuleNode.displayName = 'ModuleNode'

const BoundaryNode = memo(({ data }: NodeProps<Node<ArchitectureNodeData>>) => (
  <div className={`scope-boundary-node ${data.signalHighlighted ? 'signal-highlighted' : ''}`}>
    <Handle type="target" position={Position.Left} id="target" />
    <span>SCOPE</span>
    <strong>Parent / External Ports</strong>
    <small>容器边界真实端口</small>
    <Handle type="source" position={Position.Right} id="source" />
  </div>
))

BoundaryNode.displayName = 'BoundaryNode'

function SemanticBusEdge({
  id,
  sourceX,
  sourceY,
  targetX,
  targetY,
  sourcePosition,
  targetPosition,
  markerEnd,
  markerStart,
  data,
}: EdgeProps<Edge<BusEdgeData>>) {
  const bus = data?.interface
  const lane = data?.lane ?? 0
  const [edgePath, labelX, labelY] = getSmoothStepPath({
    sourceX,
    sourceY,
    targetX,
    targetY,
    sourcePosition,
    targetPosition,
    offset: 22 + lane * 12,
    borderRadius: 8,
  })
  const title = bus
    ? `${bus.semanticName}\n${bus.signalCount} signals · ${bus.semanticStatus}\n${bus.sourceInstances.map((item) => item.name).join(', ')} → ${bus.destinationInstances.map((item) => item.name).join(', ')}`
    : ''
  return (
    <>
      <BaseEdge
        id={id}
        path={edgePath}
        markerEnd={markerEnd}
        markerStart={markerStart}
        interactionWidth={30}
        className={data?.selected ? 'semantic-edge selected' : 'semantic-edge'}
      />
      {bus && data?.showLabel && (
        <EdgeLabelRenderer>
          <button
            className={`semantic-edge-label category-${bus.category} ${data?.selected ? 'selected' : ''}`}
            style={{ transform: `translate(-50%, -50%) translate(${labelX}px,${labelY + lane * 17}px)` }}
            title={title}
            onClick={(event) => { event.stopPropagation(); data?.onSelect(bus.id) }}
          >
            <span>{bus.semanticName}</span>
            <b>{bus.signalCount}</b>
          </button>
        </EdgeLabelRenderer>
      )}
    </>
  )
}

const nodeTypes = { frame: FrameNode, module: ModuleNode, boundary: BoundaryNode }
const edgeTypes = { semantic: SemanticBusEdge }

interface Props {
  containers: ArchitectureContainer[]
  interfaces: SemanticInterface[]
  rawConnections: RawConnection[]
  modules: Map<string, ModuleDefinition>
  focusId: string
  mode: 'architecture' | 'containment' | 'connectivity' | 'detail'
  showLegacy: boolean
  categoryFilter: string
  signalQuery: string
  selectedNodeId: string | null
  selectedInterfaceId: string | null
  selectedRawConnectionId: string | null
  matchedIds: Set<string>
  onSelectNode: (id: string) => void
  onOpenContainer: (id: string) => void
  onSelectInterface: (id: string) => void
}

function topLayout(node: ArchitectureContainer, clusterId: string | null, index: number) {
  const positions: Record<string, { x: number; y: number; width: number; height: number }> = {
    u_program_load_system: { x: 60, y: 96, width: 310, height: 176 },
    u_program_distribute_system: { x: 410, y: 96, width: 310, height: 176 },
    u_fu_subsystems: { x: 50, y: 330, width: 1560, height: 430 },
  }
  if (positions[node.name]) return positions[node.name]
  if (node.parentId === clusterId) {
    const clusterPositions: Record<string, { x: number; y: number; width: number; height: number }> = {
      u_qctl_global_subsystem: { x: 35, y: 122, width: 260, height: 168 },
      u_mem_subsystem: { x: 330, y: 122, width: 260, height: 168 },
      u_sxm_subsystem: { x: 625, y: 122, width: 260, height: 168 },
      u_mxm_subsystem: { x: 920, y: 122, width: 260, height: 168 },
      u_vxm_subsystem: { x: 1215, y: 122, width: 260, height: 168 },
    }
    return clusterPositions[node.name] ?? { x: 35 + (index % 5) * 295, y: 122 + Math.floor(index / 5) * 190, width: 260, height: 168 }
  }
  return { x: 60 + (index % 4) * 350, y: 96 + Math.floor(index / 4) * 205, width: 310, height: 176 }
}

function internalLayout(node: ArchitectureContainer, index: number) {
  const name = node.name
  if (/frontend/.test(name)) {
    const row = name.includes('load') ? 0 : name.includes('dequant') ? 1 : name.includes('compute') ? 2 : index % 3
    return { x: 220, y: 88 + row * 172, width: 210, height: 132 }
  }
  if (/timed_queue|issue_queue/.test(name)) {
    const row = name.includes('load') ? 0 : name.includes('dequant') ? 1 : name.includes('compute') ? 2 : index % 3
    return { x: 490, y: 88 + row * 172, width: 210, height: 132 }
  }
  if (/coordinator/.test(name)) return { x: 755, y: 260, width: 205, height: 138 }
  if (/execution/.test(name)) return { x: 1005, y: 260, width: 205, height: 138 }
  if (/qctl/.test(name)) return { x: 220, y: 88, width: 210, height: 132 }
  return { x: 220 + (index % 3) * 265, y: 88 + Math.floor(index / 3) * 175, width: 215, height: 135 }
}

export default function ArchitectureGraph({
  containers,
  interfaces,
  rawConnections,
  modules,
  focusId,
  mode,
  showLegacy,
  categoryFilter,
  signalQuery,
  selectedNodeId,
  selectedInterfaceId,
  selectedRawConnectionId,
  matchedIds,
  onSelectNode,
  onOpenContainer,
  onSelectInterface,
}: Props) {
  const model = useMemo(() => {
    const containerMap = new Map(containers.map((container) => [container.id, container]))
    const focus = containerMap.get(focusId) ?? containers.find((container) => !container.parentId)!
    const directChildren = containers.filter((container) => container.parentId === focus.id && (showLegacy || container.primary))
    const cluster = focus.depth === 0 ? directChildren.find((container) => container.name === 'u_fu_subsystems') ?? null : null
    const clusterChildren = cluster ? containers.filter((container) => container.parentId === cluster.id && (showLegacy || container.primary)) : []
    const displayed = [focus, ...directChildren, ...clusterChildren]
    const displayedIds = new Set(displayed.map((container) => container.id))
    const relevantScopes = new Set([focus.id, ...(cluster ? [cluster.id] : [])])
    const query = signalQuery.trim().toLowerCase()
    const rawMap = new Map(rawConnections.map((raw) => [raw.id, raw]))
    const selectedRaw = selectedRawConnectionId ? rawMap.get(selectedRawConnectionId) : null
    const highlightedIds = new Set([
      ...(selectedRaw?.sourceEndpoints ?? []).map((endpoint) => endpoint.instanceId),
      ...(selectedRaw?.destinationEndpoints ?? []).map((endpoint) => endpoint.instanceId),
    ])

    const visibleInterfaces = interfaces.filter((item) => {
      if (!relevantScopes.has(item.scopeId)) return false
      if (mode === 'containment' || mode === 'detail') return false
      if (mode === 'architecture' && ['clock-reset', 'unclassified'].includes(item.category)) return false
      if (mode === 'architecture' && focus.depth === 0 && [...item.sourceInstances, ...item.destinationInstances].some((endpoint) => endpoint.boundary)) return false
      if (categoryFilter !== 'all' && item.category !== categoryFilter) return false
      if (query) {
        const signals = item.rawConnectionIds.map((id) => rawMap.get(id)).filter(Boolean) as RawConnection[]
        if (!`${item.semanticName} ${signals.map((raw) => `${raw.signalName} ${raw.connectionExpression}`).join(' ')}`.toLowerCase().includes(query)) return false
      }
      return true
    })
    const hasBoundary = visibleInterfaces.some((item) => [...item.sourceInstances, ...item.destinationInstances].some((endpoint) => endpoint.boundary))
    const nodeList: Node<ArchitectureNodeData>[] = []
    const rootFrame = focus.depth === 0
      ? { width: 1660, height: 820 }
      : { width: 1240, height: 710 }
    nodeList.push({
      id: focus.id,
      type: 'frame',
      position: { x: 0, y: 0 },
      draggable: false,
      selectable: true,
      style: rootFrame,
      data: {
        container: focus,
        definition: modules.get(focus.moduleName),
        title: focus.displayName,
        subtitle: `${focus.moduleName} · CONTAINER SCOPE`,
        role: focus.role,
        childCount: focus.childCount,
        selected: selectedNodeId === focus.id,
        matched: matchedIds.has(focus.id),
        signalHighlighted: highlightedIds.has(focus.id),
        legacy: !focus.primary,
        root: true,
        boundary: false,
      },
    })
    if (cluster) {
      const layout = topLayout(cluster, cluster.id, 0)
      nodeList.push({
        id: cluster.id,
        type: 'frame',
        parentId: focus.id,
        position: { x: layout.x, y: layout.y },
        draggable: false,
        style: { width: layout.width, height: layout.height },
        data: {
          container: cluster,
          definition: modules.get(cluster.moduleName),
          title: cluster.displayName,
          subtitle: cluster.moduleName,
          role: cluster.role,
          childCount: cluster.childCount,
          selected: selectedNodeId === cluster.id,
          matched: matchedIds.has(cluster.id),
          signalHighlighted: highlightedIds.has(cluster.id),
          legacy: !cluster.primary,
          root: false,
          boundary: false,
        },
      })
    }
    directChildren.filter((child) => child.id !== cluster?.id).forEach((child, index) => {
      const layout = focus.depth === 0 ? topLayout(child, cluster?.id ?? null, index) : internalLayout(child, index)
      nodeList.push({
        id: child.id,
        type: 'module',
        parentId: focus.id,
        position: { x: layout.x, y: layout.y },
        style: { width: layout.width, height: layout.height },
        data: {
          container: child,
          definition: modules.get(child.moduleName),
          title: child.displayName,
          subtitle: child.moduleName,
          role: child.role,
          childCount: child.childCount,
          selected: selectedNodeId === child.id,
          matched: matchedIds.has(child.id),
          signalHighlighted: highlightedIds.has(child.id),
          legacy: !child.primary,
          root: false,
          boundary: false,
        },
      })
    })
    clusterChildren.forEach((child, index) => {
      const layout = topLayout(child, cluster?.id ?? null, index)
      nodeList.push({
        id: child.id,
        type: 'module',
        parentId: cluster!.id,
        position: { x: layout.x, y: layout.y },
        style: { width: layout.width, height: layout.height },
        data: {
          container: child,
          definition: modules.get(child.moduleName),
          title: child.displayName,
          subtitle: child.moduleName,
          role: child.role,
          childCount: child.childCount,
          selected: selectedNodeId === child.id,
          matched: matchedIds.has(child.id),
          signalHighlighted: highlightedIds.has(child.id),
          legacy: !child.primary,
          root: false,
          boundary: false,
        },
      })
    })
    const boundaryId = `boundary:${focus.id}`
    if (hasBoundary && focus.depth > 0) {
      nodeList.push({
        id: boundaryId,
        type: 'boundary',
        parentId: focus.id,
        position: { x: 28, y: 278 },
        style: { width: 150, height: 100 },
        data: {
          title: 'Scope boundary', subtitle: focus.moduleName, role: 'boundary', childCount: 0,
          selected: false, matched: false, signalHighlighted: highlightedIds.has(boundaryId), legacy: false, root: false, boundary: true,
        },
      })
      displayedIds.add(boundaryId)
    }
    if (cluster && visibleInterfaces.some((item) => item.scopeId === cluster.id && [...item.sourceInstances, ...item.destinationInstances].some((endpoint) => endpoint.boundary))) {
      const clusterBoundaryId = `boundary:${cluster.id}`
      nodeList.push({
        id: clusterBoundaryId,
        type: 'boundary',
        parentId: cluster.id,
        position: { x: 28, y: 362 },
        style: { width: 170, height: 90 },
        data: {
          title: 'Cluster boundary', subtitle: cluster.moduleName, role: 'boundary', childCount: 0,
          selected: false, matched: false, signalHighlighted: highlightedIds.has(clusterBoundaryId), legacy: false, root: false, boundary: true,
        },
      })
      displayedIds.add(clusterBoundaryId)
    }

    const edgeList: Edge<BusEdgeData>[] = []
    const laneByPair = new Map<string, number>()
    visibleInterfaces.forEach((item) => {
      const sources = item.sourceInstances.map((endpoint) => endpoint.boundary ? `boundary:${item.scopeId}` : endpoint.id)
      const destinations = item.destinationInstances.map((endpoint) => endpoint.boundary ? `boundary:${item.scopeId}` : endpoint.id)
      let first = true
      for (const source of sources) {
        for (const target of destinations) {
          if (source === target || !displayedIds.has(source) || !displayedIds.has(target)) continue
          const pair = [source, target].sort().join('|')
          const lane = laneByPair.get(pair) ?? 0
          laneByPair.set(pair, lane + 1)
          edgeList.push({
            id: `${item.id}:${source}->${target}`,
            source,
            target,
            type: 'semantic',
            sourceHandle: 'source',
            targetHandle: 'target',
            markerEnd: { type: MarkerType.ArrowClosed, color: item.id === selectedInterfaceId ? '#c17823' : '#172b57', width: 12, height: 8 },
            markerStart: item.bidirectional ? { type: MarkerType.ArrowClosed, color: item.id === selectedInterfaceId ? '#c17823' : '#172b57', width: 10, height: 7 } : undefined,
            data: { interface: item, selected: item.id === selectedInterfaceId, lane, showLabel: first, onSelect: onSelectInterface },
            zIndex: item.id === selectedInterfaceId ? 20 : 5,
          })
          first = false
        }
      }
    })
    return { nodes: nodeList, edges: edgeList, focus }
  }, [containers, interfaces, rawConnections, modules, focusId, mode, showLegacy, categoryFilter, signalQuery, selectedNodeId, selectedInterfaceId, selectedRawConnectionId, matchedIds, onSelectInterface])

  return (
    <ReactFlow
      key={`${model.focus.id}:${mode}:${showLegacy}`}
      nodes={model.nodes}
      edges={model.edges}
      nodeTypes={nodeTypes}
      edgeTypes={edgeTypes}
      nodesConnectable={false}
      nodesDraggable={false}
      onNodeClick={(_, node) => {
        const data = node.data as ArchitectureNodeData
        if (!data.container) return
        onSelectNode(node.id)
        if (node.id !== model.focus.id && data.container.childCount > 0) onOpenContainer(node.id)
      }}
      onNodeDoubleClick={(_, node) => {
        const data = node.data as ArchitectureNodeData
        if (data.container?.childCount) onOpenContainer(node.id)
      }}
      onEdgeClick={(_, edge) => {
        const item = (edge.data as BusEdgeData | undefined)?.interface
        if (item) onSelectInterface(item.id)
      }}
      minZoom={0.18}
      maxZoom={2.1}
      fitView
      fitViewOptions={{ padding: 0.08, maxZoom: 1.05 }}
      proOptions={{ hideAttribution: true }}
      className="engineering-graph hierarchy-engineering-graph"
      colorMode="light"
    >
      <Background color="#cbd4e1" gap={26} size={1} />
      <MiniMap
        pannable
        zoomable
        nodeColor={(node) => (node.data as ArchitectureNodeData | undefined)?.legacy ? '#c9cbd0' : '#9db3d2'}
        maskColor="rgba(230, 235, 242, .78)"
      />
      <Controls showInteractive={false} />
    </ReactFlow>
  )
}
