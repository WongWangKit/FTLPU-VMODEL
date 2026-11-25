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
  type Edge,
  type EdgeProps,
  type Node,
  type NodeProps,
  type ReactFlowInstance,
  type Viewport,
} from '@xyflow/react'
import { layoutOrthogonalEdges, type EdgeRoutePlan, type GraphBox } from '../lib/graph-layout-engine'
import { buildHardwareQuickSpec } from '../lib/hardware-spec'
import { interfaceSemanticPresentation } from '../lib/interface-semantics'
import InteractiveInterfaceLabel from './InteractiveInterfaceLabel'
import type { ArchitectureDrillInterface, ArchitectureDrillNode, PhysicalFunctionalBlock, PhysicalInterface, RawConnection } from '../types'

const ENGINEERING_NAVY = '#172b57'

interface GraphNodeData extends Record<string, unknown> {
  node?: ArchitectureDrillNode
  externalBlock?: PhysicalFunctionalBlock
  externalLabel?: string
  boundaryLabel?: string
  groupLabel?: string
  groupNote?: string
  selected: boolean
  context: boolean
}

interface GraphEdgeData extends Record<string, unknown> {
  id: string
  name: string
  plane: 'data' | 'control' | 'status'
  signalCount: number
  status: string
  pathKind: string
  physical: boolean
  selected: boolean
  sourceName: string
  destinationName: string
  rawConnections: RawConnection[]
  onOpen: (id: string, physical: boolean) => void
  route?: EdgeRoutePlan
  symmetricLabel?: boolean
}

type VisualNodeCategory = 'compute' | 'control' | 'storage' | 'interface'

function visualNodeCategory(item: ArchitectureDrillNode): VisualNodeCategory {
  const identity = `${item.nodeType} ${item.displayName}`.toLowerCase()
  if (/(fifo|queue|buffer|storage|store|register|imem|instruction-memory|reservoir|elastic)/.test(identity)) return 'storage'
  if (/(interface|stream|port|boundary|ingress|egress)/.test(identity)) return 'interface'
  if (/(control|router|dispatch|scheduler|decoder|select|coordinator|frontend|reassembly|distributor|source|adapter|retirement|branch|fault|status)/.test(identity)) return 'control'
  if (/(execution|compute|array|tile|matrix|vector|builder|transpose|permutation|mem|mxm|sxm|vxm)/.test(identity)) return 'compute'
  return 'control'
}

interface Props {
  current: ArchitectureDrillNode
  children: ArchitectureDrillNode[]
  allNodes: Map<string, ArchitectureDrillNode>
  localInterfaces: ArchitectureDrillInterface[]
  physicalInterfaces: PhysicalInterface[]
  rawConnections: RawConnection[]
  blocks: Map<string, PhysicalFunctionalBlock>
  selectedNodeId: string | null
  selectedInterfaceId: string | null
  selectedPhysicalInterfaceId: string | null
  savedViewport?: Viewport
  onReady: (instance: ReactFlowInstance<Node<GraphNodeData>, Edge<GraphEdgeData>>) => void
  onViewportChange: (viewport: Viewport) => void
  onOpenNode: (node: ArchitectureDrillNode) => void
  onOpenInterface: (id: string, physical: boolean) => void
}

function GraphNode({ data }: NodeProps<Node<GraphNodeData>>) {
  if (data.groupLabel) return <div className="connectivity-group-frame" data-architecture-container={data.groupLabel}>
    <div><strong>{data.groupLabel}</strong><span>ARCHITECTURE GROUPING</span></div>
    {data.groupNote && <p>{data.groupNote}</p>}
  </div>
  if (data.externalBlock || data.externalLabel) return <div className="connectivity-node external-node category-interface" data-node-id={data.externalBlock?.id ?? data.externalLabel} title={data.externalBlock ? `${data.externalBlock.displayName}\n${data.externalBlock.function}` : data.externalLabel}>
    <AllSideHandles />
    <strong>{data.externalBlock?.displayName ?? data.externalLabel}</strong>
  </div>
  if (data.boundaryLabel) return <div className="connectivity-node boundary-node category-interface" data-node-id={data.boundaryLabel}>
    <AllSideHandles />
    <strong>{data.boundaryLabel}</strong>
  </div>
  const item = data.node!
  if (item.nodeType === 'program-relay-fabric') {
    const relayCount = Number(item.parameterRefs.find((entry) => /RELAY_COUNT/.test(entry.name))?.value ?? 7)
    const stages = Array.from({ length: relayCount }, (_, index) => ({ index, bankCount: index === relayCount - 1 ? 8 : 16 }))
    return <div className={`connectivity-node architecture-node program-relay-fabric-node category-control ${data.selected ? 'selected' : ''}`} data-node-id={item.id} data-node-type={item.nodeType} data-evidence-status={item.confidenceStatus} tabIndex={0} aria-label={`${item.displayName}。东、西半球各 ${relayCount} 级 Relay，共 14 个独立 MEM Local Program Port`}>
      <AllSideHandles />
      <header><strong>PROGRAM LOAD RELAY FABRIC</strong><span>2 × 7 RTL RELAYS · 14 INDEPENDENT LOCAL PORTS</span></header>
      {(['W', 'E'] as const).map((side) => <div className="functional-program-relay-row" key={side}><b>{side}</b>{stages.map((stage) => <span key={`${side}-${stage.index}`}><strong>{side}{stage.index}</strong><small>{stage.bankCount} Banks · Local Port</small></span>)}</div>)}
      <footer>14 Distribution handshakes verified · 7 physical iMEM writes verified / Hemisphere · no 7-to-1 round-robin</footer>
    </div>
  }
  if (item.nodeType === 'qctl-relay-fabric') {
    const stages = Array.from({ length: 7 }, (_, index) => index)
    return <div className={`connectivity-node architecture-node qctl-relay-fabric-node category-storage ${data.selected ? 'selected' : ''}`} data-node-id={item.id} data-node-type={item.nodeType} data-evidence-status={item.confidenceStatus} tabIndex={0} aria-label={`${item.displayName}。East 与 West 各七级独立 Relay Store，不是广播总线`}>
      <AllSideHandles />
      <header><strong>QCTL DISTRIBUTED RELAY STORE</strong><span>2 × 7 INDEPENDENT RTL RELAYS · NO BROADCAST BUS</span></header>
      {(['EAST', 'WEST'] as const).map((side) => <div className="qctl-functional-relay-row" key={side}><b>{side}</b>{stages.map((stage) => <span key={`${side}-${stage}`}><strong>R{stage}</strong><small>64 Records</small></span>)}</div>)}
      <footer>Load Manager routes by Queue ID · FU-local Endpoints read their owning regional Store directly</footer>
    </div>
  }
  const category = visualNodeCategory(item)
  const spec = buildHardwareQuickSpec(item)
  return <div className={`connectivity-node architecture-node node-${item.nodeType} category-${category} ${item.confidenceStatus === 'architecture-inferred' || item.confidenceStatus === 'needs-review' ? 'evidence-secondary' : ''} ${data.selected ? 'selected' : ''} ${data.context ? 'context-node' : ''}`} data-node-id={item.id} data-node-type={item.nodeType} data-node-category={category} data-evidence-status={item.confidenceStatus} tabIndex={0} aria-label={`${item.displayName}。${spec.primaryLabel}：${spec.primaryValue}`}>
    <AllSideHandles />
    <div className="connectivity-node-copy"><strong>{item.displayName}</strong></div>{item.childIds.length > 0 && <em aria-label="可继续下钻">›</em>}
    <div className={`hardware-spec-tooltip spec-${spec.kind}`} role="tooltip">
      <span>{spec.eyebrow}</span>
      <strong>{item.displayName}</strong>
      <div><small>{spec.primaryLabel}</small><b>{spec.primaryValue}</b></div>
      {spec.secondary.map((fact) => <div className="spec-secondary" key={fact.label}><small>{fact.label}</small><b>{fact.value}</b></div>)}
      {spec.needsReview && <i>Needs Review · 未从当前快照静态求值</i>}
    </div>
  </div>
}

function AllSideHandles() {
  return <>{(['Left', 'Right', 'Top', 'Bottom'] as const).flatMap((side) => {
    const position = Position[side]
    const id = side.toLowerCase()
    return [<Handle key={`${id}-target`} type="target" position={position} id={`${id}-target`} />, <Handle key={`${id}-source`} type="source" position={position} id={`${id}-source`} />]
  })}</>
}

const MemoGraphNode = memo(GraphNode)

function GraphEdge({ id, sourceX, sourceY, targetX, targetY, markerEnd, data }: EdgeProps<Edge<GraphEdgeData>>) {
  const route = data!.route
  const path = route?.path ?? `M ${sourceX} ${sourceY} L ${targetX} ${sourceY} L ${targetX} ${targetY}`
  const labelX = route?.labelX ?? (sourceX + targetX) / 2
  const labelY = route?.labelY ?? (sourceY + targetY) / 2
  const hasLeader = route && (Math.abs(route.labelAnchorX - labelX) > 1 || Math.abs(route.labelAnchorY - labelY) > 1)
  return <>
    <BaseEdge id={id} path={path} markerEnd={markerEnd} interactionWidth={30} className={`connectivity-edge directed-edge plane-${data!.plane} line-${route?.lineStyle ?? 'solid'} ${data!.selected ? 'selected' : ''} ${data!.physical ? 'physical-boundary-edge' : ''}`} />
    {hasLeader && <BaseEdge id={`${id}-label-leader`} path={`M ${route.labelAnchorX} ${route.labelAnchorY} L ${labelX} ${labelY}`} interactionWidth={0} className={`interface-label-leader plane-${data!.plane}`} />}
    <EdgeLabelRenderer><InteractiveInterfaceLabel
      className={`connectivity-edge-label interface-block plane-${data!.plane} ${data!.symmetricLabel ? 'symmetric-interface' : ''} ${data!.selected ? 'selected' : ''}`}
      dataAttributes={{ 'data-edge-id': data!.id, 'data-routing-type': route?.routingType, 'data-route-lane': route?.routingLane, 'data-line-style': route?.lineStyle }}
      style={{ width: route?.labelWidth, minHeight: route?.labelHeight, height: data!.symmetricLabel ? route?.labelHeight : undefined, transform: `translate(-50%, -50%) translate(${labelX}px,${labelY}px)` }}
      ariaLabel={`${data!.name}，悬浮预览，点击固定`}
      semanticName={data!.name}
      sourceName={data!.sourceName}
      destinationName={data!.destinationName}
      rawConnections={data!.rawConnections}
      status={`${data!.status} · ${data!.pathKind}`}
      onOpenDetail={() => data!.onOpen(data!.id, data!.physical)}
    ><strong>{data!.name}</strong>{data!.pathKind === 'processed-path' && <b>PROCESSED</b>}</InteractiveInterfaceLabel></EdgeLabelRenderer>
  </>
}

const nodeTypes = { architecture: MemoGraphNode, external: MemoGraphNode, boundary: MemoGraphNode, group: MemoGraphNode }
const edgeTypes = { architecture: GraphEdge }

function semanticTextUnits(value: string) {
  return [...value].reduce((total, character) => total + (/[^\u0000-\u00ff]/.test(character) ? 1.8 : 1), 0)
}

function labelDrivenLayerGap(interfaces: ArchitectureDrillInterface[], sourceIds: Set<string>) {
  const longest = Math.max(0, ...interfaces.filter((item) => sourceIds.has(item.sourceNodeId)).map((item) => semanticTextUnits(item.name)))
  return Math.min(410, 320 + Math.max(0, longest - 14) * 2.5)
}

function internalLayout(children: ArchitectureDrillNode[], interfaces: ArchitectureDrillInterface[], layout: string, vertical: boolean) {
  const positions = new Map<string, { x: number; y: number }>()
  if (/(array|queue-map|grid)/.test(layout) || children.length > 20) {
    const columns = children.length > 60 ? 10 : children.length > 24 ? 8 : Math.min(5, Math.max(2, Math.ceil(Math.sqrt(children.length))))
    children.forEach((node, index) => positions.set(node.id, { x: (index % columns) * 380, y: Math.floor(index / columns) * 198 }))
    return positions
  }
  const childIds = new Set(children.map((node) => node.id))
  const adjacency = new Map(children.map((node) => [node.id, [] as string[]]))
  const indegree = new Map(children.map((node) => [node.id, 0]))
  for (const edge of interfaces) {
    if (!childIds.has(edge.sourceNodeId) || !childIds.has(edge.destinationNodeId) || edge.sourceNodeId === edge.destinationNodeId) continue
    if (adjacency.get(edge.sourceNodeId)!.includes(edge.destinationNodeId)) continue
    adjacency.get(edge.sourceNodeId)!.push(edge.destinationNodeId)
    indegree.set(edge.destinationNodeId, (indegree.get(edge.destinationNodeId) ?? 0) + 1)
  }
  const rank = new Map(children.map((node) => [node.id, 0]))
  const queue = children.filter((node) => indegree.get(node.id) === 0).map((node) => node.id)
  const visited = new Set<string>()
  while (queue.length) {
    const id = queue.shift()!
    visited.add(id)
    for (const target of adjacency.get(id) ?? []) {
      rank.set(target, Math.max(rank.get(target) ?? 0, (rank.get(id) ?? 0) + 1))
      indegree.set(target, (indegree.get(target) ?? 1) - 1)
      if (indegree.get(target) === 0) queue.push(target)
    }
  }
  const remaining = children.filter((node) => !visited.has(node.id))
  const cycleRank = Math.max(0, ...rank.values()) + (visited.size ? 1 : 0)
  remaining.forEach((node, index) => rank.set(node.id, cycleRank + Math.floor(index / 3)))
  if (interfaces.length === 0) {
    const columns = Math.min(4, Math.max(2, Math.ceil(Math.sqrt(children.length))))
    children.forEach((node, index) => positions.set(node.id, { x: (index % columns) * 350, y: Math.floor(index / columns) * 198 }))
    return positions
  }
  const rows = new Map<number, ArchitectureDrillNode[]>()
  for (const node of children) rows.set(rank.get(node.id) ?? 0, [...(rows.get(rank.get(node.id) ?? 0) ?? []), node])
  const orderedRows = [...rows.entries()].sort(([a], [b]) => a - b)
  if (/(branch|merge)/.test(layout)) {
    const branchSpacing = Math.min(680, Math.max(560, 500 + Math.max(0, ...interfaces.map((item) => semanticTextUnits(item.name))) * 3))
    const maxSpan = Math.max(0, ...orderedRows.map(([, nodes]) => (nodes.length - 1) * branchSpacing))
    let layerY = 0
    orderedRows.forEach(([, nodes], layerIndex) => {
      const span = (nodes.length - 1) * branchSpacing
      nodes.forEach((node, index) => positions.set(node.id, { x: (maxSpan - span) / 2 + index * branchSpacing, y: layerY }))
      if (layerIndex < orderedRows.length - 1) layerY += labelDrivenLayerGap(interfaces, new Set(nodes.map((node) => node.id)))
    })
    return positions
  }
  if (vertical && children.length > 6) {
    orderedRows.flatMap(([, nodes]) => nodes).forEach((node, index) => {
      const row = Math.floor(index / 3)
      const slot = index % 3
      const column = row % 2 === 0 ? slot : 2 - slot
      positions.set(node.id, { x: column * 650, y: row * 350 })
    })
    return positions
  }
  let horizontalX = 0
  orderedRows.forEach(([column, nodes], layerIndex) => {
    nodes.forEach((node, index) => positions.set(node.id, vertical ? { x: index * 540, y: column * 320 } : { x: horizontalX, y: index * 270 }))
    if (!vertical && layerIndex < orderedRows.length - 1) {
      const longest = Math.max(0, ...interfaces.filter((item) => nodes.some((node) => node.id === item.sourceNodeId)).map((item) => semanticTextUnits(item.name)))
      horizontalX += Math.min(800, 650 + Math.max(0, longest - 18) * 5.5)
    }
  })
  return positions
}

const programLoadGroupLayout: Record<string, { x: number; y: number; width: number; height: number; label: string; note: string }> = {
  command: { x: 40, y: 40, width: 720, height: 920, label: 'COMMAND & DMA', note: 'Descriptor control and the explicit Instruction DMA read engine' },
  reassembly: { x: 820, y: 40, width: 850, height: 920, label: 'INSTRUCTION REASSEMBLY', note: 'Response bytes and image context become buffered Program Words' },
  handoff: { x: 1730, y: 40, width: 430, height: 920, label: 'RTL HANDOFF', note: 'Word FIFO / PRIME select → distributor input elastic stage' },
  distributor: { x: 2220, y: 40, width: 1040, height: 1120, label: 'PROGRAM LOAD DISTRIBUTOR + FU BOUNDARIES', note: 'Scope expansion, integrated Relay chains, real FU boundaries and ordered retirement' },
}

const instructionDmaGroupLayout: Record<string, { x: number; y: number; width: number; height: number; label: string; note: string }> = {
  request: { x: 40, y: 40, width: 1735, height: 340, label: 'PROGRAM READ REQUEST PATH', note: 'Command acceptance reserves an ordered ID before the generic external request handoff' },
  response: { x: 40, y: 420, width: 1735, height: 330, label: 'PROGRAM RESPONSE PATH', note: 'Generic response beats are checked, buffered and returned to Program Load reassembly' },
  status: { x: 700, y: 790, width: 1075, height: 250, label: 'ORDERING / FAULT STATUS', note: 'Response ID mismatch or response error becomes terminal until reset' },
}

function programLoadNodePosition(item: ArchitectureDrillNode) {
  const id = item.id
  if (id.endsWith(':write')) return { x: 90, y: 170 }
  if (id.endsWith(':array')) return { x: 400, y: 170 }
  if (id.endsWith(':sequencer')) return { x: 90, y: 540 }
  if (id.endsWith(':instruction-dma')) return { x: 400, y: 540 }
  if (id.endsWith(':response')) return { x: 870, y: 150 }
  if (id.endsWith(':config-fifo')) return { x: 1270, y: 150 }
  if (id.endsWith(':reservoir')) return { x: 870, y: 430 }
  if (id.endsWith(':word-builder')) return { x: 1270, y: 430 }
  if (id.endsWith(':word-fifo')) return { x: 1070, y: 735 }
  if (id.endsWith(':prime-fifo')) return { x: 1790, y: 190 }
  if (id.endsWith(':handoff-mux')) return { x: 1790, y: 480 }
  if (id.endsWith(':elastic')) return { x: 1790, y: 735 }
  if (id.endsWith(':decode')) return { x: 2470, y: 180 }
  if (id.endsWith(':west')) return { x: 2270, y: 490 }
  if (id.endsWith(':east')) return { x: 2670, y: 490 }
  if (id.endsWith(':relay-fabric')) return { x: 2270, y: 690 }
  if (id.endsWith(':program-reset')) return { x: 2270, y: 900 }
  if (id.endsWith(':retire')) return { x: 2770, y: 900 }
  const group = programLoadGroupLayout[item.architectureContainer ?? 'command'] ?? programLoadGroupLayout.command
  return { x: group.x + 70, y: group.y + 150 }
}

function instructionDmaNodePosition(item: ArchitectureDrillNode) {
  const id = item.id
  if (id.endsWith(':command')) return { x: 80, y: 150 }
  if (id.endsWith(':outstanding')) return { x: 750, y: 150 }
  if (id.endsWith(':request')) return { x: 1420, y: 150 }
  if (id.endsWith(':response')) return { x: 1420, y: 510 }
  if (id.endsWith(':response-fifo')) return { x: 750, y: 510 }
  if (id.endsWith(':output')) return { x: 80, y: 510 }
  if (id.endsWith(':checker')) return { x: 1420, y: 850 }
  if (id.endsWith(':fault')) return { x: 750, y: 850 }
  return { x: 80, y: 150 }
}

function memOverviewNodePosition(item: ArchitectureDrillNode) {
  if (item.id.endsWith(':execution')) return { x: 620, y: 40 }
  if (item.id.endsWith(':streams')) return { x: 80, y: 40 }
  if (item.id.endsWith(':native-adapter')) return { x: 620, y: 330 }
  if (item.id.endsWith(':local-issue-path')) return { x: 620, y: 650 }
  if (item.id.endsWith(':legacy-compatibility')) return { x: 1160, y: 650 }
  return { x: 80, y: 330 }
}

function memLocalIssueNodePosition(item: ArchitectureDrillNode) {
  if (item.id.endsWith(':issue-select')) return { x: 500, y: 30 }
  if (item.id.endsWith(':timed-queue')) return { x: 500, y: 300 }
  if (item.id.endsWith(':macro')) return { x: 500, y: 570 }
  if (item.id.endsWith(':frontend')) return { x: 500, y: 840 }
  return { x: 40, y: 570 }
}

function southNorthBankNodePosition(item: ArchitectureDrillNode) {
  if (item.id.endsWith(':tiles')) return { x: 420, y: 60 }
  if (item.id.endsWith(':control-column')) return { x: 420, y: 420 }
  return { x: 40, y: 420 }
}

const qctlOverviewGroupLayout: Record<string, { x: number; y: number; width: number; height: number; label: string; note: string }> = {
  distribution: { x: 20, y: 20, width: 900, height: 490, label: 'QCTL SOURCES + DISTRIBUTED RELAY', note: 'Load Manager → East / West Relay Stores. Event TAG uses an independent runtime path.' },
  runtime: { x: 20, y: 550, width: 900, height: 460, label: 'FU-LOCAL QCTL CONTROL', note: 'Store Head → Endpoint → Five-State Controller → Scheduler Counter.' },
}

function qctlOverviewNodeLayout(item: ArchitectureDrillNode) {
  if (item.id.endsWith(':events')) return { x: 55, y: 125, width: 220, height: 82 }
  if (item.id.endsWith(':load-manager')) return { x: 665, y: 125, width: 220, height: 82 }
  if (item.id.endsWith(':relay-fabric')) return { x: 115, y: 245, width: 710, height: 236 }
  if (item.id.endsWith(':readers')) return { x: 330, y: 650, width: 280, height: 76 }
  if (item.id.endsWith(':controllers')) return { x: 330, y: 780, width: 280, height: 76 }
  if (item.id.endsWith(':counters')) return { x: 330, y: 910, width: 280, height: 86 }
  if (item.id.endsWith(':barrier')) return { x: 55, y: 780, width: 220, height: 76 }
  if (item.id.endsWith(':packet')) return { x: 665, y: 780, width: 220, height: 76 }
  if (item.id.endsWith(':endpoints')) return { x: 665, y: 910, width: 220, height: 86 }
  return { x: 330, y: 650, width: 280, height: 76 }
}

export default function FunctionalConnectivityGraph({ current, children, allNodes, localInterfaces, physicalInterfaces, rawConnections, blocks, selectedNodeId, selectedInterfaceId, selectedPhysicalInterfaceId, savedViewport, onReady, onViewportChange, onOpenNode, onOpenInterface }: Props) {
  const model = useMemo(() => {
    const incoming = physicalInterfaces.filter((item) => item.destinationBlockId === current.blockId)
    const outgoing = physicalInterfaces.filter((item) => item.sourceBlockId === current.blockId)
    const memRoot = !current.parentId && /:mem$/.test(current.blockId)
    const vertical = !current.parentId && memRoot
    const programLoadOverview = current.layout === 'program-load-overview'
    const instructionDmaOverview = current.layout === 'instruction-dma-overview'
    const memOverview = current.layout === 'mem-overview-south-north'
    const memLocalIssueOverview = current.layout === 'mem-local-issue-south-north'
    const southNorthBank = current.layout === 'south-north-bank'
    const qctlOverview = current.layout === 'qctl-overview'
    const positions = programLoadOverview
      ? new Map(children.map((item) => [item.id, programLoadNodePosition(item)]))
      : instructionDmaOverview
        ? new Map(children.map((item) => [item.id, instructionDmaNodePosition(item)]))
        : memOverview
          ? new Map(children.map((item) => [item.id, memOverviewNodePosition(item)]))
          : memLocalIssueOverview
            ? new Map(children.map((item) => [item.id, memLocalIssueNodePosition(item)]))
            : southNorthBank
              ? new Map(children.map((item) => [item.id, southNorthBankNodePosition(item)]))
              : qctlOverview
                ? new Map(children.map((item) => [item.id, qctlOverviewNodeLayout(item)]))
      : internalLayout(children, localInterfaces, current.layout, vertical)
    // L1 already owns cross-block physical connectivity.  When a functional
    // scope has real internal interfaces, repeating every external bus here
    // overwhelms the internal graph.  Boundary edges remain available for a
    // root that has no internal semantic edges at all.
    const showExternalBoundary = !current.parentId && localInterfaces.length === 0
    const hasIncoming = showExternalBoundary && incoming.length > 0
    const hasOutgoing = showExternalBoundary && outgoing.length > 0
    const customAbsoluteLayout = programLoadOverview || instructionDmaOverview || memOverview || memLocalIssueOverview || southNorthBank || qctlOverview
    const childOffset = customAbsoluteLayout ? 0 : !vertical && hasIncoming ? 420 : 80
    const childOffsetY = customAbsoluteLayout ? 0 : vertical && hasIncoming ? 250 : 100
    const nodeWidth = 315
    const nodeHeight = 136
    const nodes: Node<GraphNodeData>[] = children.map((item) => {
      const relayFabric = item.nodeType === 'program-relay-fabric'
      const qctlLayout = qctlOverview ? qctlOverviewNodeLayout(item) : undefined
      return { id: item.id, type: 'architecture', position: { x: childOffset + (positions.get(item.id)?.x ?? 0), y: childOffsetY + (positions.get(item.id)?.y ?? 0) }, style: { width: qctlLayout?.width ?? (relayFabric ? 715 : nodeWidth), height: qctlLayout?.height ?? (relayFabric ? 178 : nodeHeight), zIndex: 5 }, data: { node: item, selected: selectedNodeId === item.id, context: false } }
    })
    if (programLoadOverview) for (const [key, group] of Object.entries(programLoadGroupLayout)) nodes.unshift({ id: `${current.id}:group:${key}`, type: 'group', position: { x: group.x, y: group.y }, style: { width: group.width, height: group.height, zIndex: -4 }, draggable: false, selectable: false, data: { groupLabel: group.label, groupNote: group.note, selected: false, context: false } })
    if (instructionDmaOverview) for (const [key, group] of Object.entries(instructionDmaGroupLayout)) nodes.unshift({ id: `${current.id}:group:${key}`, type: 'group', position: { x: group.x, y: group.y }, style: { width: group.width, height: group.height, zIndex: -4 }, draggable: false, selectable: false, data: { groupLabel: group.label, groupNote: group.note, selected: false, context: false } })
    if (qctlOverview) for (const [key, group] of Object.entries(qctlOverviewGroupLayout)) nodes.unshift({ id: `${current.id}:group:${key}`, type: 'group', position: { x: group.x, y: group.y }, style: { width: group.width, height: group.height, zIndex: -4 }, draggable: false, selectable: false, data: { groupLabel: group.label, groupNote: group.note, selected: false, context: false } })
    const displayIds = new Set(nodes.map((node) => node.id))
    let maxX = Math.max(childOffset + nodeWidth, ...nodes.map((node) => node.position.x + nodeWidth))
    let maxY = Math.max(childOffsetY + nodeHeight, ...nodes.map((node) => node.position.y + nodeHeight))
    let contextY = 60
    for (const item of localInterfaces) for (const endpointId of [item.sourceNodeId, item.destinationNodeId]) {
      if (displayIds.has(endpointId) || endpointId === current.id) continue
      const endpoint = allNodes.get(endpointId)
      if (!endpoint) continue
      nodes.push({ id: endpoint.id, type: 'architecture', position: { x: childOffset, y: contextY }, style: { width: nodeWidth, height: nodeHeight }, data: { node: endpoint, selected: selectedNodeId === endpoint.id, context: true } })
      displayIds.add(endpoint.id); contextY += 170
    }
    if (hasIncoming) nodes.push({ id: `${current.id}:input-boundary`, type: 'boundary', position: vertical ? { x: Math.max(80, maxX / 2 - 122), y: 55 } : { x: 70, y: 100 }, style: { width: 245, height: 112 }, data: { boundaryLabel: `${current.displayName} Input`, selected: false, context: false } })
    if (hasOutgoing) nodes.push({ id: `${current.id}:output-boundary`, type: 'boundary', position: vertical ? { x: Math.max(80, maxX / 2 - 122), y: maxY + 150 } : { x: maxX + 210, y: 100 }, style: { width: 245, height: 112 }, data: { boundaryLabel: `${current.displayName} Output`, selected: false, context: false } })
    if (hasOutgoing && !vertical) maxX += 455
    const edges: Edge<GraphEdgeData>[] = []
    const rawMap = new Map(rawConnections.map((raw) => [raw.id, raw]))
    const edgeData = (item: ArchitectureDrillInterface | PhysicalInterface, physical: boolean): GraphEdgeData => ({
      id: item.id,
      name: interfaceSemanticPresentation(item.id, item.name).displayName,
      plane: item.plane,
      signalCount: item.signalCount,
      status: physical ? (item as PhysicalInterface).evidenceStatus : (item as ArchitectureDrillInterface).confidenceStatus,
      pathKind: physical ? (item as PhysicalInterface).pathKind : 'semantic-interface',
      physical,
      selected: physical ? selectedPhysicalInterfaceId === item.id : selectedInterfaceId === item.id,
      sourceName: physical
        ? blocks.get((item as PhysicalInterface).sourceBlockId)?.displayName ?? (item as PhysicalInterface).sourceBlockId
        : allNodes.get((item as ArchitectureDrillInterface).sourceNodeId)?.displayName ?? (item as ArchitectureDrillInterface).sourceNodeId,
      destinationName: physical
        ? blocks.get((item as PhysicalInterface).destinationBlockId)?.displayName ?? (item as PhysicalInterface).destinationBlockId
        : allNodes.get((item as ArchitectureDrillInterface).destinationNodeId)?.displayName ?? (item as ArchitectureDrillInterface).destinationNodeId,
      rawConnections: item.rawConnectionIds.map((id) => rawMap.get(id)).filter(Boolean) as RawConnection[],
      onOpen: onOpenInterface,
    })
    for (const item of localInterfaces) {
      const source = displayIds.has(item.sourceNodeId) ? item.sourceNodeId : `${current.id}:input-boundary`
      const target = displayIds.has(item.destinationNodeId) ? item.destinationNodeId : `${current.id}:output-boundary`
      if (!nodes.some((node) => node.id === source) || !nodes.some((node) => node.id === target)) continue
      edges.push({ id: item.id, source, target, type: 'architecture', markerEnd: { type: MarkerType.ArrowClosed, width: 12, height: 8, color: ENGINEERING_NAVY }, data: edgeData(item, false), zIndex: selectedInterfaceId === item.id ? 5 : 2 })
    }
    const incomingBlocks = [...new Set(incoming.map((item) => item.sourceBlockId))]
    const outgoingBlocks = [...new Set(outgoing.map((item) => item.destinationBlockId))]
    if (hasIncoming) incoming.forEach((item) => {
      const groupIndex = incomingBlocks.indexOf(item.sourceBlockId)
      const externalId = `external:incoming:${item.sourceBlockId}`
      const block = blocks.get(item.sourceBlockId)
      const label = block?.displayName ?? item.sourceBlockId.split(':').slice(1).reverse().map((part) => part.toUpperCase()).join(' · ')
      if (!nodes.some((node) => node.id === externalId)) nodes.push({ id: externalId, type: 'external', position: vertical ? { x: (groupIndex % 4) * 255, y: -120 - Math.floor(groupIndex / 4) * 130 } : { x: -250, y: groupIndex * 145 }, style: { width: 235, height: 104 }, data: { externalBlock: block, externalLabel: label, selected: false, context: false } })
      edges.push({ id: item.id, source: externalId, target: `${current.id}:input-boundary`, type: 'architecture', markerEnd: { type: MarkerType.ArrowClosed, width: 12, height: 8, color: ENGINEERING_NAVY }, data: edgeData(item, true), zIndex: selectedPhysicalInterfaceId === item.id ? 5 : 1 })
    })
    if (hasOutgoing) outgoing.forEach((item) => {
      const groupIndex = outgoingBlocks.indexOf(item.destinationBlockId)
      const externalId = `external:outgoing:${item.destinationBlockId}`
      const block = blocks.get(item.destinationBlockId)
      const label = block?.displayName ?? item.destinationBlockId.split(':').slice(1).reverse().map((part) => part.toUpperCase()).join(' · ')
      if (!nodes.some((node) => node.id === externalId)) nodes.push({ id: externalId, type: 'external', position: vertical ? { x: (groupIndex % 4) * 255, y: maxY + 380 + Math.floor(groupIndex / 4) * 130 } : { x: maxX + 260, y: groupIndex * 145 }, style: { width: 235, height: 104 }, data: { externalBlock: block, externalLabel: label, selected: false, context: false } })
      edges.push({ id: item.id, source: `${current.id}:output-boundary`, target: externalId, type: 'architecture', markerEnd: { type: MarkerType.ArrowClosed, width: 12, height: 8, color: ENGINEERING_NAVY }, data: edgeData(item, true), zIndex: selectedPhysicalInterfaceId === item.id ? 5 : 1 })
    })
    const boxes: GraphBox[] = nodes.filter((node) => node.type !== 'group').map((node) => ({ id: node.id, x: node.position.x, y: node.position.y, width: Number(node.style?.width ?? nodeWidth), height: Number(node.style?.height ?? nodeHeight) }))
    const topDownLayout = qctlOverview || /(branch|merge|instruction-dma-overview|south-north)/.test(current.layout)
    const nodeById = new Map(nodes.map((node) => [node.id, node]))
    const plans = layoutOrthogonalEdges(boxes, edges.map((edge, edgeIndex) => {
      const source = nodeById.get(edge.source)
      const target = nodeById.get(edge.target)
      const flowsDown = source && target && target.position.y > source.position.y + 20
      const flowsUp = source && target && target.position.y + 20 < source.position.y
      const westCompletion = /West Branch Complete/.test(edge.data?.name ?? '')
      const eastCompletion = /East Branch Complete/.test(edge.data?.name ?? '')
      return {
        id: edge.id,
        sourceId: edge.source,
        targetId: edge.target,
        semanticName: edge.data!.name,
        sourceSide: topDownLayout && flowsDown ? 'bottom' as const : topDownLayout && flowsUp ? 'top' as const : undefined,
        targetSide: westCompletion ? 'left' as const : eastCompletion ? 'right' as const : topDownLayout && flowsDown ? 'top' as const : topDownLayout && flowsUp ? 'bottom' as const : undefined,
        plane: edge.data!.plane,
        lineStyle: edge.data!.plane === 'status' || edge.data!.physical || edge.data!.pathKind === 'processed-path' || edge.data!.status === 'needs-review' ? 'dashed' as const : 'solid' as const,
        routingLane: edgeIndex % 6,
      }
    }), { obstaclePadding: 30, channelSpacing: 34, labelClearance: 18, labelSpacing: 14, maxLabelWidth: 244, laneSearchCount: 5, canvasPadding: 280 })
    if (qctlOverview) {
      const manualRoutes = new Map<string, { sourceSide: 'left' | 'right' | 'top' | 'bottom'; targetSide: 'left' | 'right' | 'top' | 'bottom'; points: Array<{ x: number; y: number }>; label: { x: number; y: number } }>([
        [`${current.id}:interface:load-relay`, { sourceSide: 'bottom', targetSide: 'top', points: [{ x: 775, y: 207 }, { x: 775, y: 226 }, { x: 470, y: 226 }, { x: 470, y: 245 }], label: { x: 625, y: 226 } }],
        [`${current.id}:interface:relay-reader`, { sourceSide: 'bottom', targetSide: 'top', points: [{ x: 470, y: 481 }, { x: 470, y: 650 }], label: { x: 470, y: 530 } }],
        [`${current.id}:interface:reader-controller`, { sourceSide: 'bottom', targetSide: 'top', points: [{ x: 470, y: 726 }, { x: 470, y: 780 }], label: { x: 470, y: 753 } }],
        [`${current.id}:interface:controller-counter`, { sourceSide: 'bottom', targetSide: 'top', points: [{ x: 470, y: 856 }, { x: 470, y: 910 }], label: { x: 470, y: 883 } }],
        [`${current.id}:interface:barrier-controller`, { sourceSide: 'right', targetSide: 'left', points: [{ x: 275, y: 818 }, { x: 330, y: 818 }], label: { x: 303, y: 753 } }],
        [`${current.id}:interface:event-controller`, { sourceSide: 'left', targetSide: 'top', points: [{ x: 55, y: 166 }, { x: 38, y: 166 }, { x: 38, y: 753 }, { x: 470, y: 753 }, { x: 470, y: 780 }], label: { x: 170, y: 735 } }],
        [`${current.id}:interface:controller-packet`, { sourceSide: 'right', targetSide: 'left', points: [{ x: 610, y: 818 }, { x: 665, y: 818 }], label: { x: 638, y: 753 } }],
      ])
      for (const [edgeId, route] of manualRoutes) {
        const plan = plans.get(edgeId)
        if (!plan) continue
        plan.sourceSide = route.sourceSide
        plan.targetSide = route.targetSide
        plan.points = route.points
        plan.waypoints = route.points.slice(1, -1)
        plan.path = route.points.map((point, index) => `${index === 0 ? 'M' : 'L'} ${point.x} ${point.y}`).join(' ')
        plan.labelX = route.label.x
        plan.labelY = route.label.y
        plan.labelAnchorX = route.label.x
        plan.labelAnchorY = route.label.y
        plan.labelOffset = { x: 0, y: 0 }
        plan.labelWidth = /(?:barrier-controller|event-controller|controller-packet)$/.test(edgeId) ? 118 : 164
        plan.labelHeight = 36
        plan.lineStyle = 'solid'
      }
    }
    for (const edge of edges) {
      const plan = plans.get(edge.id)
      if (!plan) continue
      edge.sourceHandle = `${plan.sourceSide}-source`
      edge.targetHandle = `${plan.targetSide}-target`
      edge.data!.route = plan
    }
    // Mirror interface blocks for true sibling branches/merges.  The directed
    // graph still owns the topology; this only aligns paired West/East labels.
    const alignPairs = (group: Edge<GraphEdgeData>[]) => {
      if (group.length !== 2) return
      const routes = group.map((edge) => edge.data?.route).filter(Boolean) as EdgeRoutePlan[]
      if (routes.length !== 2) return
      const alignedY = (routes[0].labelY + routes[1].labelY) / 2
      const sharedWidth = Math.max(180, ...routes.map((route) => route.labelWidth))
      const sharedHeight = Math.max(68, ...routes.map((route) => route.labelHeight))
      for (const [index, route] of routes.entries()) {
        group[index].data!.symmetricLabel = true
        route.labelY = alignedY
        route.labelWidth = sharedWidth
        route.labelHeight = sharedHeight
        route.labelOffset = { x: route.labelX - route.labelAnchorX, y: alignedY - route.labelAnchorY }
      }
    }
    const westEast = edges.filter((edge) => /(?:West|East) Branch Handshake/.test(edge.data?.name ?? ''))
    const completion = edges.filter((edge) => /(?:West|East) Branch Complete/.test(edge.data?.name ?? ''))
    alignPairs(westEast)
    alignPairs(completion)
    return { nodes, edges }
  }, [current, children, allNodes, localInterfaces, physicalInterfaces, rawConnections, blocks, selectedNodeId, selectedInterfaceId, selectedPhysicalInterfaceId, onOpenInterface])

  return <ReactFlow
    key={current.id}
    nodes={model.nodes}
    edges={model.edges}
    nodeTypes={nodeTypes}
    edgeTypes={edgeTypes}
    nodesDraggable={false}
    nodesConnectable={false}
    elementsSelectable
    zoomOnScroll={false}
    panOnScroll
    minZoom={.28}
    maxZoom={1.7}
    fitView={current.layout === 'qctl-overview' || !savedViewport}
    defaultViewport={savedViewport ?? { x: 30, y: 30, zoom: .9 }}
    fitViewOptions={current.layout === 'qctl-overview' ? { padding: .08, maxZoom: 1.05 } : { padding: .22, maxZoom: .92 }}
    onInit={onReady}
    onMoveEnd={(_, viewport) => onViewportChange(viewport)}
    onNodeClick={(_, node) => { const item = (node.data as GraphNodeData).node; if (item) onOpenNode(item) }}
    onEdgeClick={(_, edge) => { const data = edge.data as GraphEdgeData; onOpenInterface(data.id, data.physical) }}
    proOptions={{ hideAttribution: true }}
    className={`engineering-graph functional-engineering-graph ${current.layout === 'qctl-overview' ? 'qctl-functional-overview' : ''}`}
    colorMode="light"
  >
    <Background color="#cbd4e1" gap={26} size={1} />
    <MiniMap pannable zoomable nodeColor={(node) => node.type === 'architecture' ? '#9db3d2' : '#c4cfdd'} maskColor="rgba(230, 235, 242, .78)" />
    <Controls showInteractive={false} />
  </ReactFlow>
}
