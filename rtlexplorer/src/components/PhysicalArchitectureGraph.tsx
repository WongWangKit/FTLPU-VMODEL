import { memo, useEffect, useMemo, useRef, useState } from 'react'
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
} from '@xyflow/react'
import { layoutOrthogonalEdges, type EdgeRoutePlan, type GraphBox } from '../lib/graph-layout-engine'
import { interfaceSemanticPresentation } from '../lib/interface-semantics'
import FrontendStagePopover from './FrontendStagePopover'
import InteractiveInterfaceLabel from './InteractiveInterfaceLabel'
import type { ArchitectureDrillInterface, ArchitectureDrillNode, ConfigurationFrontend, ConfigurationFrontendStage, PhysicalFunctionalBlock, PhysicalInterface, PhysicalRegion, RawConnection } from '../types'

const ENGINEERING_NAVY = '#172b57'

interface PhysicalNodeData extends Record<string, unknown> {
  block?: PhysicalFunctionalBlock
  region?: PhysicalRegion
  programNode?: ArchitectureDrillNode
  programGroup?: { id: string; label: string; note: string; role: 'layer' | 'section' }
  frontend?: ConfigurationFrontend
  interfaceItem?: PhysicalInterface
  interfaceSourceName?: string
  interfaceDestinationName?: string
  interfaceRawConnections?: RawConnection[]
  onOpenInterface?: (id: string) => void
  topologyNode?: {
    label: string
    tone: 'module' | 'buffer' | 'boot' | 'relay' | 'interface' | 'note'
    note: string
    insetLabel?: string
    insetPlacement?: 'center' | 'lower-left'
    caption?: string
    storageSpec?: {
      title: string
      width: string
      depth: string
      contents: string
      implementation: string
      status: 'rtl-confirmed' | 'needs-review' | 'architecture-only'
      extraFacts?: Array<{ label: string; value: string }>
    }
    disableDrilldown?: boolean
  }
  ownerBlock?: PhysicalFunctionalBlock
  selected: boolean
  rawHighlighted: boolean
}

interface PhysicalEdgeData extends Record<string, unknown> {
  interface: PhysicalInterface
  selected: boolean
  showLabel: boolean
  labelName: string
  labelSignalCount: number
  pairKey?: string
  sourceName: string
  destinationName: string
  rawConnections: RawConnection[]
  status: string
  onSelect: (id: string) => void
  route?: EdgeRoutePlan
}

interface ProgramLoadEdgeData extends Record<string, unknown> {
  interface: ArchitectureDrillInterface
  labelName: string
  selected: boolean
  onSelect: (id: string) => void
  route?: EdgeRoutePlan
}

interface FrontendControlEdgeData extends Record<string, unknown> {
  frontendId: ConfigurationFrontend['id']
}

interface ReferenceEdgeData extends Record<string, unknown> {
  relation: 'program' | 'qctl' | 'frontend' | 'relay' | 'interface'
}

type PhysicalGraphEdge = Edge<PhysicalEdgeData> | Edge<ProgramLoadEdgeData> | Edge<FrontendControlEdgeData> | Edge<ReferenceEdgeData>

const RegionFrame = memo(({ data }: NodeProps<Node<PhysicalNodeData>>) => (
  <div className={`physical-region-frame region-${data.region?.id}`}>
    <div>
      <span>{data.region?.name}</span>
      <small className={`status-pill status-${data.region?.placementStatus}`}>{data.region?.placementStatus}</small>
    </div>
    <p>{data.region?.id === 'control' ? 'CONTROL PLANE' : 'FUNCTIONAL TOPOLOGY REGION'}</p>
  </div>
))
RegionFrame.displayName = 'RegionFrame'

function DataHandles() {
  return <>
    <Handle type="source" position={Position.Left} id="left-source" className="physical-handle generic left" />
    <Handle type="target" position={Position.Left} id="left-target" className="physical-handle generic left" />
    <Handle type="source" position={Position.Right} id="right-source" className="physical-handle generic right" />
    <Handle type="target" position={Position.Right} id="right-target" className="physical-handle generic right" />
    <Handle type="source" position={Position.Top} id="top-source" className="physical-handle generic top" />
    <Handle type="target" position={Position.Top} id="top-target" className="physical-handle generic top" />
    <Handle type="source" position={Position.Bottom} id="bottom-source" className="physical-handle generic bottom" />
    <Handle type="target" position={Position.Bottom} id="bottom-target" className="physical-handle generic bottom" />
    <Handle type="source" position={Position.Left} id="source-left-east" className="physical-handle data-east upper left" />
    <Handle type="target" position={Position.Left} id="target-left-east" className="physical-handle data-east upper left" />
    <Handle type="source" position={Position.Right} id="source-right-east" className="physical-handle data-east upper right" />
    <Handle type="target" position={Position.Right} id="target-right-east" className="physical-handle data-east upper right" />
    <Handle type="source" position={Position.Left} id="source-left-west" className="physical-handle data-west lower left" />
    <Handle type="target" position={Position.Left} id="target-left-west" className="physical-handle data-west lower left" />
    <Handle type="source" position={Position.Right} id="source-right-west" className="physical-handle data-west lower right" />
    <Handle type="target" position={Position.Right} id="target-right-west" className="physical-handle data-west lower right" />
    <Handle type="target" position={Position.Bottom} id="target-control" className="physical-handle control bottom" />
    <Handle type="source" position={Position.Top} id="source-control" className="physical-handle control top" />
    <Handle type="source" position={Position.Right} id="source-right-control" className="physical-handle control right" />
    <Handle type="target" position={Position.Left} id="target-left-control" className="physical-handle control left" />
    <Handle type="source" position={Position.Bottom} id="source-bottom-control" className="physical-handle control bottom" />
    <Handle type="target" position={Position.Top} id="target-top-control" className="physical-handle control top" />
  </>
}

const FunctionalNode = memo(({ data }: NodeProps<Node<PhysicalNodeData>>) => {
  const item = data.block!
  if (item.kind === 'program-load-pipeline') return (
    <div className={`physical-block physical-program-load-overview kind-${item.kind} ${data.selected ? 'selected' : ''} ${data.rawHighlighted ? 'raw-highlighted' : ''}`} data-node-kind={item.kind} data-evidence-status={item.placementStatus} title={`${item.displayName}\n${item.function}\n${item.placementStatus}`}>
      <DataHandles />
      <div className="program-load-overview-title"><span>LPU_TOP DIRECT SUBSYSTEMS · RTL-CONFIRMED</span><strong>PROGRAM LOAD → PROGRAM DISTRIBUTION → FU CLUSTER</strong></div>
      <div className="program-load-overview-groups">
        <section className="program-load-command"><header>COMMAND &amp; DMA</header><div className="program-load-mini-graph">
          <div className="program-load-command-flow">
            <div className="program-load-command-row"><b>Host Command Write</b><i data-program-edge="descriptor-write">→</i><b>Descriptor Array · 32</b></div>
            <div className="program-load-command-drop"><span data-program-edge="descriptor-fetch">Descriptor Fetch / Command PC</span><i>↓</i></div>
            <div className="program-load-command-row"><b>Command PC / Sequencer</b><i data-program-edge="dma-command">→</i><b>Instruction DMA / Program Read Engine</b></div>
          </div>
          <div className="program-load-boundary-link" title="The RTL exposes a generic command/response contract. No AXI or C2C adapter is instantiated."><span data-program-edge="external-read">Program Read Request →</span><b>GENERIC DMA BOUNDARY</b><span className="program-load-return-lane">← Program Response Beats</span><small>AXI / C2C adapter not modeled</small></div>
          <small className="program-load-needs-review">BOUNDARY NEEDS REVIEW · lpu_top currently derives EAST/WEST Scope from Destination[12]; top-level BOTH input is not exposed.</small>
        </div></section>
        <div className="program-load-crossing command-to-reassembly" aria-label="Command and DMA to Instruction Reassembly interfaces">
          <span className="program-load-crossing-control" data-program-edge="image-context" title="Independent Scope[1:0], Destination[11:0], format, local iMEM base and image metadata">IMAGE CONTEXT + ROUTE METADATA <b>→</b></span>
          <span className="program-load-crossing-data" data-program-edge="dma-response" title="Buffered DMA response: 256-bit data, 32-bit keep, last, 8-bit ID and error">BUFFERED PROGRAM RESPONSE <b>→</b></span>
        </div>
        <section className="program-load-reassembly"><header>INSTRUCTION REASSEMBLY</header><div className="program-load-mini-graph">
          <div className="program-load-reassembly-inputs"><b>External Program Response Boundary</b><b>Image Context FIFO · 16</b></div>
          <div className="program-load-reassembly-lanes"><i data-program-edge="response-bytes">DATA / KEEP ↓</i><i data-program-edge="context-builder">ROUTE METADATA ↓</i></div>
          <div className="program-load-reassembly-build"><b>64-byte Reassembly Reservoir</b><i data-program-edge="program-word">→</i><b>96 / 128-bit Program Word Builder</b></div>
          <div className="program-load-reassembly-enqueue"><i data-program-edge="word-enqueue">↓</i><span>REASSEMBLED PROGRAM WORD + ROUTE METADATA</span></div>
          <b className="program-load-word-fifo">Reassembled Word FIFO · 8</b>
        </div></section>
        <div className="program-load-crossing reassembly-to-handoff" aria-label="Instruction Reassembly to RTL Handoff interface">
          <span className="program-load-crossing-data" data-program-edge="word-dequeue" title="165-bit stored record: 128-bit word, 4-bit strobe, 2-bit Scope, 13-bit Destination, 17-bit local iMEM address and last">REASSEMBLED WORD + ROUTE METADATA <b>→</b></span>
          <span className="program-load-crossing-return">← DEQUEUE READY</span>
        </div>
        <section className="program-load-handoff"><header>RTL HANDOFF</header><div className="program-load-mini-graph program-load-merge">
          <div className="program-load-merge-source"><b>WRITE Record</b><i data-program-edge="word-dequeue">↘ WRITE</i></div>
          <div className="program-load-merge-source"><b>Deferred PRIME Command FIFO</b><i data-program-edge="prime-select">↙ PRIME</i></div>
          <b className="program-load-merge-target">WRITE / PRIME Handoff Mux</b><i data-program-edge="distributor-input">↓</i><b>Distributor Input Elastic Stage · 2</b>
        </div></section>
        <div className="program-load-crossing handoff-to-distributor" aria-label="RTL Handoff to Program Load Distributor interface">
          <span className="program-load-crossing-control" data-program-edge="distributor-input" title="1-bit Control, 128-bit data, 4-bit strobe, Scope[1:0], Destination[11:0], 17-bit iMEM address and last">PROGRAM LOAD RECORD · 165 BIT <b>→</b></span>
          <span className="program-load-crossing-return">← INPUT READY</span>
        </div>
        <section className="program-load-distributor"><header>PROGRAM DISTRIBUTION SYSTEM</header><div className="program-load-mini-graph program-load-fork">
          <b>Scope Expansion + Destination Decode</b><i data-program-edge="hemisphere-decode">↓</i><div className="program-load-branches"><b>West Program Branch</b><b>East Program Branch</b></div>
          <div className="program-load-branch-forward"><span>West Record → W0–W6 → FU Frontend</span><span>East Record → E0–E6 → FU Frontend</span></div>
          <div className="program-load-return"><i data-program-edge="west-completion">↘ completion</i><i data-program-edge="east-completion">completion ↙</i></div><b>Dual-branch Retirement</b>
        </div></section>
      </div>
    </div>
  )
  return (
    <div className={`physical-block kind-${item.kind} ${data.selected ? 'selected' : ''} ${data.rawHighlighted ? 'raw-highlighted' : ''} ${!item.enabledByDefault ? 'inactive' : ''}`} data-node-kind={item.kind} data-evidence-status={item.placementStatus} title={`${item.displayName}\n${item.function}\n${item.rtlMappings.map((mapping) => mapping.moduleName).filter(Boolean).join(', ')}\n${item.placementStatus}\n${item.instanceCount} instance${item.instanceCount === 1 ? '' : 's'}`}>
      <DataHandles />
      <strong>{item.shortName}</strong>
    </div>
  )
})
FunctionalNode.displayName = 'FunctionalNode'

const PhysicalFrontendMarker = memo(({ data }: NodeProps<Node<PhysicalNodeData>>) => {
  const frontend = data.frontend!
  return <div className="physical-frontend-marker" data-status={frontend.status} title={`Open ${frontend.label} architecture`}>
    <Handle type="target" position={Position.Top} id="top-target" className="physical-frontend-handle top" />
    <strong>{frontend.fu.toUpperCase()} FRONTEND</strong>
    <span aria-hidden="true">＋</span>
    <Handle type="source" position={Position.Bottom} id="bottom-source" className="physical-frontend-handle bottom" />
  </div>
})
PhysicalFrontendMarker.displayName = 'PhysicalFrontendMarker'

const ReferenceTopologyNode = memo(({ data }: NodeProps<Node<PhysicalNodeData>>) => {
  const item = data.topologyNode!
  const interfaceItem = data.interfaceItem
  return <div
    className={`physical-reference-node tone-${item.tone} ${data.selected ? 'selected' : ''}`}
    data-topology-label={item.label}
    data-inset-placement={item.insetPlacement ?? 'center'}
    data-storage={item.storageSpec ? 'true' : 'false'}
    tabIndex={item.storageSpec ? 0 : undefined}
    title={interfaceItem || item.storageSpec ? undefined : `${item.label}\n${item.note}`}
  >
    {item.tone !== 'note' && <DataHandles />}
    {interfaceItem ? <InteractiveInterfaceLabel
      className="physical-reference-interface-popover"
      ariaLabel={`${item.label.replace('\n', ' ')}，悬浮预览，点击固定`}
      semanticName={item.label.replace('\n', ' ')}
      sourceName={data.interfaceSourceName ?? interfaceItem.sourceBlockId}
      destinationName={data.interfaceDestinationName ?? interfaceItem.destinationBlockId}
      rawConnections={data.interfaceRawConnections ?? []}
      status={`${interfaceItem.evidenceStatus} · ${interfaceItem.pathKind}`}
      onOpenDetail={() => data.onOpenInterface?.(interfaceItem.id)}
    ><strong>{item.label}</strong></InteractiveInterfaceLabel> : <strong>{item.label}</strong>}
    {item.insetLabel && <span className="physical-reference-node-inset">{item.insetLabel}</span>}
    {item.caption && <small>{item.caption}</small>}
    {item.storageSpec && <aside className="physical-storage-popover" role="tooltip">
      <span className="physical-storage-popover-eyebrow">STORAGE PARAMETERS</span>
      <strong>{item.storageSpec.title}</strong>
      <dl>
        <div><dt>WIDTH</dt><dd>{item.storageSpec.width}</dd></div>
        <div><dt>DEPTH</dt><dd>{item.storageSpec.depth}</dd></div>
        <div><dt>CONTENTS</dt><dd>{item.storageSpec.contents}</dd></div>
        {item.storageSpec.extraFacts?.map((fact) => <div key={fact.label}><dt>{fact.label}</dt><dd>{fact.value}</dd></div>)}
      </dl>
      <p>{item.storageSpec.implementation}</p>
      <small data-status={item.storageSpec.status}>{item.storageSpec.status} · current RTL</small>
    </aside>}
  </div>
})
ReferenceTopologyNode.displayName = 'ReferenceTopologyNode'

interface FrontendLevelNodeData extends Record<string, unknown> {
  label: string
  status: string
  count?: number | null
  stage?: ConfigurationFrontend['variants'][number]['stages'][number]
  variantName?: string
  onOpenPipeline?: () => void
}

const FrontendVariantFrame = memo(({ data }: NodeProps<Node<FrontendLevelNodeData>>) => <section className="frontend-level-variant" data-status={data.status}>
  <header><strong>{data.label}</strong>{data.count != null && <span>×{data.count} / FU</span>}</header>
</section>)
FrontendVariantFrame.displayName = 'FrontendVariantFrame'

const FrontendStageNode = memo(({ data }: NodeProps<Node<FrontendLevelNodeData>>) => <div className="frontend-level-stage" data-status={data.status}>
  <Handle type="target" position={Position.Left} id="left-target" />
  <FrontendStagePopover stage={data.stage!} variantName={data.variantName!} instanceCount={data.count ?? null} onOpenPipeline={data.onOpenPipeline} />
  <Handle type="source" position={Position.Right} id="right-source" />
</div>)
FrontendStageNode.displayName = 'FrontendStageNode'

const frontendLevelNodeTypes = { frontendVariant: FrontendVariantFrame, frontendStage: FrontendStageNode }

interface FrontendPipelineNodeData extends Record<string, unknown> {
  label: string
  description: string
  boundary: string
  indexLabel: string
  endpoint?: 'input' | 'output'
  kind: 'decoder' | 'scheduler'
  stateMachine?: boolean
  tone?: 'main' | 'idle' | 'dictionary' | 'escape' | 'done' | 'fault' | 'fault-summary'
  annotation?: boolean
}

const FrontendPipelineStepNode = memo(({ data }: NodeProps<Node<FrontendPipelineNodeData>>) => <article
  className="frontend-pipeline-step"
  data-endpoint={data.endpoint ?? ''}
  data-pipeline-kind={data.kind}
  data-state-machine={data.stateMachine ? 'true' : 'false'}
  data-tone={data.tone ?? 'main'}
  data-annotation={data.annotation ? 'true' : 'false'}
>
  <Handle type="target" position={Position.Left} id="left-target" />
  {data.stateMachine && <Handle type="source" position={Position.Left} id="left-source" />}
  {data.stateMachine && <>
    <Handle type="target" position={Position.Top} id="top-target" style={{ left: '34%' }} />
    <Handle type="target" position={Position.Top} id="top-target-center" style={{ left: '50%' }} />
    <Handle type="source" position={Position.Top} id="top-source" style={{ left: '66%' }} />
    <Handle type="target" position={Position.Bottom} id="bottom-target" style={{ left: '50%' }} />
    <Handle type="source" position={Position.Bottom} id="bottom-source-center" style={{ left: '50%' }} />
    <Handle type="source" position={Position.Bottom} id="bottom-source-left" style={{ left: '34%' }} />
    <Handle type="source" position={Position.Bottom} id="bottom-source-right" style={{ left: '66%' }} />
    <Handle type="target" position={Position.Right} id="right-target" />
  </>}
  {!data.stateMachine && <span>{data.indexLabel}</span>}
  <strong>{data.label}</strong>
  <p>{data.description}</p>
  {!data.stateMachine && <small>{data.boundary}</small>}
  <Handle type="source" position={Position.Right} id="right-source" />
</article>)
FrontendPipelineStepNode.displayName = 'FrontendPipelineStepNode'

const frontendPipelineNodeTypes = { frontendVariant: FrontendVariantFrame, frontendPipelineStep: FrontendPipelineStepNode }

function FrontendPipelineLevel({ frontend, variantName, stage, onBack }: { frontend: ConfigurationFrontend; variantName: string; stage: ConfigurationFrontendStage; onBack: () => void }) {
  const pipeline = stage.pipeline!
  const stateMachineFocus = pipeline.visualization === 'state-machine'
  const graph = useMemo(() => {
    if (pipeline.visualization === 'state-machine') {
      const frameId = `frontend-pipeline:${frontend.id}:${stage.id}`
      const frameWidth = 2620
      const frameHeight = 1350
      const nodes: Node<FrontendLevelNodeData | FrontendPipelineNodeData>[] = [{
        id: frameId,
        type: 'frontendVariant',
        position: { x: 50, y: 45 },
        style: { width: frameWidth, height: frameHeight, zIndex: -1 },
        draggable: false,
        selectable: false,
        data: { label: pipeline.stateBadge ?? 'RTL 状态转移', status: stage.status },
      }]
      for (const step of pipeline.steps) {
        const position = step.position ?? { x: 70, y: 100 }
        nodes.push({
          id: `${frameId}:${step.id}`,
          type: 'frontendPipelineStep',
          parentId: frameId,
          position: { x: position.x, y: position.y },
          style: { width: position.width ?? 230, height: position.height ?? 112, zIndex: step.annotation ? 1 : 3 },
          draggable: false,
          selectable: false,
          data: {
            label: step.name,
            description: step.description,
            boundary: step.boundary,
            indexLabel: '',
            kind: pipeline.kind,
            stateMachine: true,
            tone: step.tone,
            annotation: step.annotation,
          },
        })
      }
      const transitionNavy = '#102b59'
      const edges: Edge[] = (pipeline.transitions ?? []).map((transition) => {
        const tone = transition.tone ?? 'main'
        const color = transitionNavy
        return {
          id: `${frameId}:transition:${transition.id}`,
          source: `${frameId}:${transition.source}`,
          target: `${frameId}:${transition.target}`,
          sourceHandle: transition.sourceHandle ?? 'right-source',
          targetHandle: transition.targetHandle ?? 'left-target',
          type: 'smoothstep',
          pathOptions: { offset: transition.offset ?? 34, borderRadius: 8 },
          label: transition.label,
          labelShowBg: true,
          labelBgPadding: [8, 4],
          labelBgBorderRadius: 3,
          labelBgStyle: { fill: '#fffdf8', fillOpacity: 0.96, stroke: color, strokeWidth: 1 },
          labelStyle: { fill: color, fontFamily: 'Microsoft YaHei, sans-serif', fontSize: 16, fontWeight: 900 },
          className: `decoder-state-transition tone-${tone}`,
          style: { stroke: color, strokeWidth: 3, strokeDasharray: tone === 'fault' ? '9 6' : undefined },
          markerEnd: { type: MarkerType.ArrowClosed, color, width: 16, height: 12 },
          zIndex: tone === 'loop' || tone === 'fault' ? 1 : 2,
        }
      })
      return { nodes, edges }
    }
    const cardWidth = 250
    const cardGap = 86
    const frameLeft = 60
    const frameTop = 55
    const cards = [
      { id: 'input', label: 'Pipeline Input', description: pipeline.inputLabel, boundary: 'UPSTREAM READY / VALID', indexLabel: 'IN', endpoint: 'input' as const },
      ...pipeline.steps.map((step, index) => ({ ...step, label: step.name, indexLabel: String(index + 1).padStart(2, '0') })),
      { id: 'output', label: 'Pipeline Output', description: pipeline.outputLabel, boundary: 'DOWNSTREAM READY / VALID', indexLabel: 'OUT', endpoint: 'output' as const },
    ]
    const frameId = `frontend-pipeline:${frontend.id}:${stage.id}`
    const frameWidth = 100 + cards.length * cardWidth + Math.max(0, cards.length - 1) * cardGap
    const nodes: Node<FrontendLevelNodeData | FrontendPipelineNodeData>[] = [{
      id: frameId,
      type: 'frontendVariant',
      position: { x: frameLeft, y: frameTop },
      style: { width: frameWidth, height: 310, zIndex: -1 },
      draggable: false,
      selectable: false,
      data: { label: `${stage.name} · ${variantName}`, status: stage.status },
    }]
    const edges: Edge[] = []
    for (const [cardIndex, card] of cards.entries()) {
      const cardId = `${frameId}:${card.id}`
      nodes.push({
        id: cardId,
        type: 'frontendPipelineStep',
        parentId: frameId,
        position: { x: 42 + cardIndex * (cardWidth + cardGap), y: 82 },
        style: { width: cardWidth, height: 195, zIndex: 2 },
        draggable: false,
        selectable: false,
        data: { label: card.label, description: card.description, boundary: card.boundary, indexLabel: card.indexLabel, endpoint: 'endpoint' in card ? card.endpoint : undefined, kind: pipeline.kind },
      })
      if (cardIndex > 0) edges.push({
        id: `${frameId}:flow:${cardIndex - 1}:${cardIndex}`,
        source: `${frameId}:${cards[cardIndex - 1].id}`,
        target: cardId,
        sourceHandle: 'right-source',
        targetHandle: 'left-target',
        type: 'straight',
        className: 'frontend-level-edge frontend-pipeline-level-edge',
        style: { stroke: '#a46518', strokeWidth: 5 },
        markerEnd: { type: MarkerType.ArrowClosed, color: '#a46518', width: 18, height: 13 },
      })
    }
    return { nodes, edges }
  }, [frontend.id, pipeline, stage.id, stage.name, stage.status, variantName])

  return <section className="physical-frontend-pipeline-level" data-frontend-level={frontend.id} data-pipeline-kind={pipeline.kind} data-status={stage.status} data-state-machine-focus={stateMachineFocus ? 'true' : 'false'}>
    {stateMachineFocus
      ? <header className="decoder-state-machine-heading"><button type="button" onClick={onBack}>← L2 {frontend.label}</button><h2>{pipeline.title}</h2></header>
      : <>
        <header>
          <button type="button" onClick={onBack}>← L2 {frontend.label}</button>
          <div><span>{pipeline.kind === 'decoder' ? 'MACRO → CONTEXT' : 'CONTEXT → BASE INSTRUCTION'}</span><h2>{stage.name}</h2></div>
          <strong>{`${pipeline.kind.toUpperCase()} PIPELINE`}</strong>
        </header>
        <div className="frontend-pipeline-level-summary">
          <p>{pipeline.summary}</p>
          <span>{pipeline.timingNote}</span>
        </div>
      </>}
    <div className="physical-frontend-pipeline-level-canvas">
      <ReactFlow nodes={graph.nodes} edges={graph.edges} nodeTypes={frontendPipelineNodeTypes} nodesDraggable={false} nodesConnectable={false} elementsSelectable={false} minZoom={0.25} maxZoom={2.2} fitView fitViewOptions={{ padding: 0.1, maxZoom: 1.05 }} proOptions={{ hideAttribution: true }} colorMode="light">
        <Background color="#cbd4e1" gap={28} size={1} />
        <Controls showInteractive={false} />
      </ReactFlow>
    </div>
  </section>
}

function FrontendArchitectureLevel({ frontend, onBack, onFocusModeChange }: { frontend: ConfigurationFrontend; onBack: () => void; onFocusModeChange?: (active: boolean) => void }) {
  const [activePipeline, setActivePipeline] = useState<{ variantName: string; stage: ConfigurationFrontendStage } | null>(null)
  const stateMachineFocus = activePipeline?.stage.pipeline?.visualization === 'state-machine'
  useEffect(() => {
    onFocusModeChange?.(stateMachineFocus)
    return () => onFocusModeChange?.(false)
  }, [onFocusModeChange, stateMachineFocus])
  const graph = useMemo(() => {
    const stageWidth = 220
    const stageGap = 78
    const frameLeft = 70
    const frameTop = 60
    const rowGap = 245
    const nodes: Node<FrontendLevelNodeData>[] = []
    const edges: Edge[] = []
    for (const [variantIndex, variant] of frontend.variants.entries()) {
      const frameId = `frontend-level:${frontend.id}:${variant.id}`
      const frameWidth = Math.max(720, 100 + variant.stages.length * stageWidth + Math.max(0, variant.stages.length - 1) * stageGap)
      nodes.push({
        id: frameId,
        type: 'frontendVariant',
        position: { x: frameLeft, y: frameTop + variantIndex * rowGap },
        style: { width: frameWidth, height: 190, zIndex: -1 },
        draggable: false,
        selectable: false,
        data: { label: variant.name, status: variant.status, count: variant.count },
      })
      for (const [stageIndex, stage] of variant.stages.entries()) {
        const stageId = `${frameId}:${stage.id}`
        nodes.push({
          id: stageId,
          type: 'frontendStage',
          parentId: frameId,
          position: { x: 42 + stageIndex * (stageWidth + stageGap), y: 68 },
          style: { width: stageWidth, height: 92, zIndex: 2 },
          draggable: false,
          data: { label: stage.name, status: stage.status, stage, variantName: variant.name, count: variant.count, onOpenPipeline: stage.pipeline ? () => setActivePipeline({ variantName: variant.name, stage }) : undefined },
        })
        if (stageIndex > 0) {
          edges.push({
            id: `${frameId}:flow:${stageIndex - 1}:${stageIndex}`,
            source: `${frameId}:${variant.stages[stageIndex - 1].id}`,
            target: stageId,
            sourceHandle: 'right-source',
            targetHandle: 'left-target',
            type: 'straight',
            className: 'frontend-level-edge',
            style: { stroke: '#a46518', strokeWidth: 4 },
            markerEnd: { type: MarkerType.ArrowClosed, color: '#a46518', width: 16, height: 12 },
          })
        }
      }
    }
    return { nodes, edges }
  }, [frontend])

  if (activePipeline) return <FrontendPipelineLevel frontend={frontend} variantName={activePipeline.variantName} stage={activePipeline.stage} onBack={() => setActivePipeline(null)} />

  return <section className="physical-frontend-level" data-frontend-level={frontend.id} data-status={frontend.status}>
    <header>
      <button type="button" onClick={onBack}>← L1 Physical Architecture</button>
      <div><span>FRONTEND ARCHITECTURE</span><h2>{frontend.label}</h2></div>
      <strong>{frontend.status === 'rtl-confirmed' ? 'INTEGRATED' : 'INTEGRATION WIP'}</strong>
    </header>
    <div className="physical-frontend-level-canvas">
      <ReactFlow nodes={graph.nodes} edges={graph.edges} nodeTypes={frontendLevelNodeTypes} nodesDraggable={false} nodesConnectable={false} elementsSelectable={false} onNodeClick={() => undefined} minZoom={0.3} maxZoom={2.2} fitView fitViewOptions={{ padding: 0.12, maxZoom: 1.05 }} proOptions={{ hideAttribution: true }} colorMode="light">
        <Background color="#cbd4e1" gap={28} size={1} />
        <Controls showInteractive={false} />
      </ReactFlow>
    </div>
  </section>
}

const PromotedProgramGroup = memo(({ data }: NodeProps<Node<PhysicalNodeData>>) => {
  const group = data.programGroup!
  return <div className={`physical-program-group group-${group.id} group-role-${group.role}`} data-program-group={group.id} title={group.note}>
    <header><strong>{group.label}</strong><span>{group.role === 'layer' ? 'RTL OWNERSHIP LAYER' : 'CONTROLLER INTERNAL STAGE'}</span></header>
  </div>
})
PromotedProgramGroup.displayName = 'PromotedProgramGroup'

function promotedProgramCategory(item: ArchitectureDrillNode) {
  const identity = `${item.nodeType} ${item.displayName}`.toLowerCase()
  if (/(fifo|queue|buffer|reservoir|elastic|array)/.test(identity)) return 'storage'
  if (/(boundary|interface|response)/.test(identity)) return 'interface'
  if (/(builder)/.test(identity)) return 'compute'
  return 'control'
}

const PromotedProgramNode = memo(({ data }: NodeProps<Node<PhysicalNodeData>>) => {
  const item = data.programNode!
  const category = promotedProgramCategory(item)
  if (item.nodeType === 'program-relay-fabric') {
    return <div className={`physical-program-stage physical-program-relay-fabric ${data.selected ? 'selected' : ''}`} data-program-node={item.id} data-evidence-status={item.confidenceStatus} title={`${item.displayName}\n${item.description}\n${item.confidenceStatus}`}>
      <DataHandles />
      <header><strong>RELAY CHAIN · WEST / EAST</strong><span>2 × 7 REGISTERED STAGES</span></header>
      <div className="physical-program-relay-row"><b>WEST</b><span>W0 → W1 → W2 → W3 → W4 → W5 → W6</span></div>
      <div className="physical-program-relay-row"><b>EAST</b><span>E0 → E1 → E2 → E3 → E4 → E5 → E6</span></div>
      <footer>14 MEM local ports · R6 outer MXM/SXM path · VXM bypasses Relay</footer>
    </div>
  }
  return <div className={`physical-program-stage category-${category} ${data.selected ? 'selected' : ''} ${data.rawHighlighted ? 'raw-highlighted' : ''}`} data-program-node={item.id} data-program-container={item.architectureContainer ?? ''} data-evidence-status={item.confidenceStatus} title={`${item.displayName}\n${item.description}\n${item.confidenceStatus}`}>
    <DataHandles />
    <strong>{item.displayName}</strong>
  </div>
})
PromotedProgramNode.displayName = 'PromotedProgramNode'

function ProgramLoadEdge({ id, sourceX, sourceY, targetX, targetY, markerEnd, data }: EdgeProps<Edge<ProgramLoadEdgeData>>) {
  const route = data?.route
  const path = route?.path ?? `M ${sourceX} ${sourceY} L ${targetX} ${sourceY} L ${targetX} ${targetY}`
  const labelX = route?.labelX ?? (sourceX + targetX) / 2
  const labelY = route?.labelY ?? (sourceY + targetY) / 2
  return <>
    <BaseEdge id={id} path={path} markerEnd={markerEnd} interactionWidth={24} className={`physical-program-edge plane-${data!.interface.plane} line-${route?.lineStyle ?? 'solid'} ${data?.selected ? 'selected' : ''}`} />
    <EdgeLabelRenderer><button
      type="button"
      className={`physical-program-edge-label plane-${data!.interface.plane}`}
      data-program-interface={data!.interface.id}
      data-route-lane={route?.routingLane}
      style={{ width: route?.labelWidth, transform: `translate(-50%, -50%) translate(${labelX}px,${labelY}px)` }}
      onClick={(event) => { event.stopPropagation(); data!.onSelect(data!.interface.id) }}
    >{data!.labelName}</button></EdgeLabelRenderer>
  </>
}

function PhysicalBusEdge({ id, sourceX, sourceY, targetX, targetY, markerEnd, data }: EdgeProps<Edge<PhysicalEdgeData>>) {
  const item = data!.interface
  const region = item.id.includes(':west:') ? 'W' : item.id.includes(':east:') ? 'E' : 'C'
  const direction = item.direction === 'east-stream' ? 'E' : item.direction === 'west-stream' ? 'W' : item.direction === 'program-load' ? 'LOAD' : 'ISSUE'
  const route = data?.route
  const path = route?.path ?? `M ${sourceX} ${sourceY} L ${targetX} ${sourceY} L ${targetX} ${targetY}`
  const labelX = route?.labelX ?? (sourceX + targetX) / 2
  const labelY = route?.labelY ?? (sourceY + targetY) / 2
  const hasLeader = route && (Math.abs(route.labelAnchorX - labelX) > 1 || Math.abs(route.labelAnchorY - labelY) > 1)
  return <>
    <BaseEdge id={id} path={path} markerEnd={markerEnd} interactionWidth={28} className={`physical-bus directed-edge plane-${item.plane} direction-${item.direction} path-${item.pathKind} line-${route?.lineStyle ?? 'solid'} ${data?.selected ? 'selected' : ''}`} />
    {hasLeader && <BaseEdge id={`${id}-label-leader`} path={`M ${route.labelAnchorX} ${route.labelAnchorY} L ${labelX} ${labelY}`} interactionWidth={0} className={`interface-label-leader plane-${item.plane}`} />}
    {data?.showLabel && <EdgeLabelRenderer>
      <InteractiveInterfaceLabel
        className={`physical-bus-label interface-block plane-${item.plane} direction-${item.direction} ${data.pairKey ? 'bidirectional-interface' : ''} ${data.selected ? 'selected' : ''}`}
        dataAttributes={{ 'data-edge-id': item.id, 'data-interface-pair': data.pairKey, 'data-route-lane': route?.routingLane, 'data-line-style': route?.lineStyle }}
        style={{ width: route?.labelWidth, minHeight: route?.labelHeight, transform: `translate(-50%, -50%) translate(${labelX}px,${labelY}px)` }}
        ariaLabel={`${item.name}，悬浮预览，点击固定`}
        semanticName={data.labelName}
        sourceName={data.sourceName}
        destinationName={data.destinationName}
        rawConnections={data.rawConnections}
        status={data.status}
        onOpenDetail={() => data.onSelect(item.id)}
      >
        {item.plane === 'data' && !data.pairKey && <span>{`${region}·${direction}`}</span>}
        <strong>{data.labelName}</strong>
      </InteractiveInterfaceLabel>
    </EdgeLabelRenderer>}
  </>
}

const nodeTypes = { region: RegionFrame, functional: FunctionalNode, frontendMarker: PhysicalFrontendMarker, programGroup: PromotedProgramGroup, programStage: PromotedProgramNode, referenceTopology: ReferenceTopologyNode }
const edgeTypes = { physical: PhysicalBusEdge, programLoad: ProgramLoadEdge }

const regionLayout: Record<string, { x: number; y: number; width: number; height: number }> = {
  external: { x: 20, y: 25, width: 3620, height: 280 },
  control: { x: 20, y: 355, width: 3620, height: 1900 },
  west: { x: 20, y: 2305, width: 1350, height: 390 },
  central: { x: 1600, y: 2305, width: 400, height: 390 },
  east: { x: 2250, y: 2305, width: 1350, height: 390 },
}

const blockLayout: Record<string, { x: number; y: number; width: number; height: number }> = {
  'physical:west:mxm': { x: 30, y: 145, width: 270, height: 180 },
  'physical:west:sxm': { x: 540, y: 145, width: 270, height: 180 },
  'physical:west:mem': { x: 1050, y: 145, width: 270, height: 180 },
  'physical:central:vxm': { x: 50, y: 145, width: 300, height: 180 },
  'physical:east:mem': { x: 30, y: 145, width: 270, height: 180 },
  'physical:east:sxm': { x: 540, y: 145, width: 270, height: 180 },
  'physical:east:mxm': { x: 1050, y: 145, width: 270, height: 180 },
  'physical:external:instruction-ddr': { x: 180, y: 72, width: 430, height: 155 },
  'physical:external:program-bus': { x: 850, y: 72, width: 520, height: 155 },
  'physical:control:instruction-dma': { x: 260, y: 90, width: 360, height: 150 },
  'physical:control:qctl': { x: 3160, y: 1680, width: 360, height: 170 },
}

const programLoadLayerLayout = {
  controller: { x: 70, y: 70, width: 3450, height: 650, label: 'L1 · PROGRAM LOAD SYSTEM', note: 'DMA → response buffer → Assembler / Reassembler → Program Word FIFO.' },
  network: { x: 70, y: 770, width: 3450, height: 430, label: 'L2 · PROGRAM DISTRIBUTION SYSTEM', note: 'Elastic Stage → West/East Relay chains → FU frontend/local iMEM; VXM uses the direct Distributor bypass.' },
} as const

const programLoadNodeLayout: Record<string, { x: number; y: number; width: number; height: number }> = {
  'arch:control:program-load:instruction-dma': { x: 220, y: 330, width: 420, height: 125 },
  'arch:control:program-load:response': { x: 900, y: 330, width: 420, height: 125 },
  'arch:control:program-load:assembler': { x: 1580, y: 330, width: 480, height: 125 },
  'arch:control:program-load:word-fifo': { x: 2320, y: 330, width: 420, height: 125 },
  'arch:control:program-load:elastic': { x: 260, y: 920, width: 430, height: 125 },
  'arch:control:program-load:relay-fabric': { x: 980, y: 870, width: 1320, height: 220 },
  'arch:control:program-load:fu-entry': { x: 2660, y: 920, width: 520, height: 125 },
}

const programRelayFabricId = 'arch:control:program-load:relay-fabric'

interface Props {
  regions: PhysicalRegion[]
  blocks: PhysicalFunctionalBlock[]
  interfaces: PhysicalInterface[]
  drillNodes: ArchitectureDrillNode[]
  drillInterfaces: ArchitectureDrillInterface[]
  frontends: ConfigurationFrontend[]
  rawConnections: RawConnection[]
  selectedBlockId: string | null
  selectedInterfaceId: string | null
  selectedRawConnectionId: string | null
  planeFilter: 'all' | 'data' | 'control'
  signalQuery: string
  connectivityMode: boolean
  onOpenBlock: (id: string) => void
  onSelectInterface: (id: string) => void
  onSelectDrillInterface: (id: string) => void
  onFocusModeChange?: (active: boolean) => void
}

export default function PhysicalArchitectureGraph({ regions, blocks, interfaces, drillNodes, drillInterfaces, frontends, rawConnections, selectedBlockId, selectedInterfaceId, selectedRawConnectionId, planeFilter, signalQuery, connectivityMode, onOpenBlock, onSelectInterface, onSelectDrillInterface, onFocusModeChange }: Props) {
  const [activeFrontendId, setActiveFrontendId] = useState<ConfigurationFrontend['id'] | null>(null)
  const flowRef = useRef<ReactFlowInstance<Node<PhysicalNodeData>, PhysicalGraphEdge> | null>(null)
  const fitOptions = { padding: 0.06, maxZoom: 1.05 }
  useEffect(() => {
    let timer = 0
    const fit = () => {
      window.clearTimeout(timer)
      timer = window.setTimeout(() => flowRef.current?.fitView(fitOptions), 90)
    }
    window.addEventListener('resize', fit)
    return () => { window.removeEventListener('resize', fit); window.clearTimeout(timer) }
  }, [])
  const model = useMemo(() => {
    if (!connectivityMode) {
      const programBlock = blocks.find((block) => block.id === 'physical:control:program-load')
      const qctlBlock = blocks.find((block) => block.id === 'physical:control:qctl')
      const blockById = new Map(blocks.map((block) => [block.id, block]))
      const rawConnectionById = new Map(rawConnections.map((item) => [item.id, item]))
      const frontendByFu = new Map<string, ConfigurationFrontend>(frontends.map((frontend) => [frontend.fu, frontend]))
      const programNodeBySuffix = (suffix: string) => drillNodes.find((node) => node.id === `arch:control:program-load:${suffix}`)
      const nodes: Node<PhysicalNodeData>[] = []
      const edges: Edge<ReferenceEdgeData>[] = []
      const node = ({ id, label, x, y, width, height, tone = 'module', note, insetLabel, insetPlacement = 'center', caption, storageSpec, disableDrilldown = false, block, programNode, frontend, interfaceItem, selected = false, selectable = true }: {
        id: string
        label: string
        x: number
        y: number
        width: number
        height: number
        tone?: NonNullable<PhysicalNodeData['topologyNode']>['tone']
        note: string
        insetLabel?: string
        insetPlacement?: 'center' | 'lower-left'
        caption?: string
        storageSpec?: NonNullable<PhysicalNodeData['topologyNode']>['storageSpec']
        disableDrilldown?: boolean
        block?: PhysicalFunctionalBlock
        programNode?: ArchitectureDrillNode
        frontend?: ConfigurationFrontend
        interfaceItem?: PhysicalInterface
        selected?: boolean
        selectable?: boolean
      }) => nodes.push({
        id,
        type: 'referenceTopology',
        position: { x, y },
        style: { width, height, zIndex: tone === 'note' ? 2 : 10 },
        draggable: false,
        selectable,
        data: {
          topologyNode: { label, tone, note, insetLabel, insetPlacement, caption, storageSpec, disableDrilldown },
          block,
          programNode,
          programGroup: undefined,
          ownerBlock: programBlock,
          frontend,
          interfaceItem,
          interfaceSourceName: interfaceItem ? blockById.get(interfaceItem.sourceBlockId)?.displayName ?? interfaceItem.sourceBlockId : undefined,
          interfaceDestinationName: interfaceItem ? blockById.get(interfaceItem.destinationBlockId)?.displayName ?? interfaceItem.destinationBlockId : undefined,
          interfaceRawConnections: interfaceItem ? interfaceItem.rawConnectionIds.map((rawId) => rawConnectionById.get(rawId)).filter(Boolean) as RawConnection[] : undefined,
          onOpenInterface: onSelectInterface,
          selected,
          rawHighlighted: false,
        },
      })
      const edge = ({ id, source, target, relation, sourceHandle = 'right-source', targetHandle = 'left-target', arrow = true, dashed = false, type = 'straight' }: {
        id: string
        source: string
        target: string
        relation: ReferenceEdgeData['relation']
        sourceHandle?: string
        targetHandle?: string
        arrow?: boolean
        dashed?: boolean
        type?: 'straight' | 'smoothstep'
      }) => edges.push({
        id,
        source,
        target,
        sourceHandle,
        targetHandle,
        type,
        className: `physical-reference-edge relation-${relation}`,
        style: { stroke: ENGINEERING_NAVY, strokeWidth: 3, strokeDasharray: dashed ? '10 7' : undefined },
        markerEnd: arrow ? { type: MarkerType.ArrowClosed, width: 15, height: 11, color: ENGINEERING_NAVY } : undefined,
        data: { relation },
        zIndex: relation === 'interface' ? 3 : 4,
      })
      const selectedBlock = (id: string) => selectedBlockId === id
      const selectedInterface = (item?: PhysicalInterface) => item?.id === selectedInterfaceId
      const programClickNode = programNodeBySuffix('instruction-dma')

      // Fixed reference blueprint. These are explicit coordinates, not an auto layout.
      node({ id: 'reference:ddr', label: 'DDR', x: 650, y: 65, width: 125, height: 78, note: 'External instruction-memory boundary. The current RTL exposes a generic Program DMA interface; a DDR controller is not instantiated.', storageSpec: { title: 'External Instruction DDR', width: 'Needs Review', depth: 'Needs Review', contents: 'Program-image bytes', implementation: 'External integration endpoint only; no DDR controller, PHY or memory array is instantiated in the current RTL.', status: 'needs-review' }, block: blockById.get('physical:external:instruction-ddr'), selected: selectedBlock('physical:external:instruction-ddr') })
      node({ id: 'reference:axi', label: 'AXI', x: 970, y: 65, width: 125, height: 78, note: 'Conceptual AXI transport boundary. Current RTL does not instantiate an AXI adapter, so this remains Needs Review.', block: blockById.get('physical:external:program-bus'), selected: selectedBlock('physical:external:program-bus') })
      node({ id: 'reference:boot-rom', label: 'BOOT ROM', x: 703, y: 190, width: 145, height: 86, tone: 'boot', note: 'Conceptual boot source from the reference architecture. No BOOT ROM module was found in the current RTL snapshot.', storageSpec: { title: 'BOOT ROM', width: 'Needs Review', depth: 'Needs Review', contents: 'Boot / initial program image', implementation: 'Reference-architecture placeholder; no BOOT ROM module or array parameters were found in the current RTL.', status: 'needs-review' }, disableDrilldown: true })
      node({ id: 'reference:controller', label: 'Controller', x: 685, y: 322, width: 180, height: 96, note: 'Program Load controller and command-sequencing responsibility.', storageSpec: { title: 'Command Descriptor Array', width: '155-bit record', depth: '32 entries', contents: 'Opcode, source address, byte count, route, format and jump metadata', implementation: 'Register array command_mem_q in lpu_program_load_controller.', status: 'rtl-confirmed' }, disableDrilldown: true, programNode: programClickNode, selected: selectedBlock('physical:control:program-load') })
      node({ id: 'reference:dma', label: 'DMA', x: 970, y: 280, width: 285, height: 180, note: 'lpu_instruction_dma: generic Program DMA request/response engine with ordered ID tracking and a buffered response path.', insetLabel: 'Outstanding FIFO', insetPlacement: 'lower-left', storageSpec: { title: 'Outstanding ID FIFO', width: '8-bit DMA ID', depth: '16 entries', contents: 'Accepted read-request IDs in response order', implementation: 'u_outstanding_id_fifo inside lpu_instruction_dma.', status: 'rtl-confirmed', extraFacts: [{ label: 'DMA DATA', value: '256 bit' }] }, disableDrilldown: true, programNode: programClickNode, selected: selectedBlock('physical:control:program-load') || selectedBlock('physical:control:instruction-dma') })
      node({ id: 'reference:response-fifo', label: 'Response FIFO', x: 1335, y: 330, width: 145, height: 84, tone: 'buffer', note: 'Response FIFO inside lpu_instruction_dma; buffers generic Program DMA response beats.', storageSpec: { title: 'DMA Response FIFO', width: '298-bit record', depth: '16 entries', contents: '256-bit data + 32-bit keep + 8-bit ID + last + error', implementation: 'u_response_fifo inside lpu_instruction_dma.', status: 'rtl-confirmed' }, disableDrilldown: true, programNode: programNodeBySuffix('response') })
      node({ id: 'reference:config-fifo', label: 'Config FIFO', x: 1080, y: 515, width: 145, height: 82, tone: 'buffer', note: 'Image-context/configuration FIFO in lpu_program_load_path.', storageSpec: { title: 'Image Context / Config FIFO', width: '155-bit record', depth: '16 entries', contents: 'DMA transaction descriptor and Program route metadata', implementation: 'u_config_fifo in lpu_program_load_path.', status: 'rtl-confirmed' }, disableDrilldown: true, programNode: programNodeBySuffix('assembler') })
      node({ id: 'reference:reassembler', label: 'Reassembler', x: 1520, y: 510, width: 180, height: 92, note: 'lpu_program_load_reassembler converts buffered response bytes plus image context into complete Program Words.', storageSpec: { title: 'Reassembly Byte Reservoir', width: '512 bit', depth: '64 bytes', contents: 'Buffered DMA response bytes before 96/128-bit word emission', implementation: 'buffer_q with BUFFER_BYTES = 64 in lpu_program_load_reassembler.', status: 'rtl-confirmed' }, disableDrilldown: true, programNode: programNodeBySuffix('assembler') })
      node({ id: 'reference:word-fifo', label: 'Word FIFO', x: 1795, y: 510, width: 145, height: 92, tone: 'buffer', note: 'Eight-entry reassembled Program Word FIFO.', storageSpec: { title: 'Reassembled Program Word FIFO', width: '165-bit record', depth: '8 entries', contents: '128-bit word + strobe + Scope + 13-bit Destination + iMEM address + last', implementation: 'u_word_fifo in lpu_program_load_path.', status: 'rtl-confirmed' }, disableDrilldown: true, programNode: programNodeBySuffix('word-fifo') })

      node({ id: 'reference:event-buffer', label: 'EVENT BUFFER', x: 520, y: 650, width: 210, height: 96, note: 'Eight-slot, 32-bit TAG event buffer in the QCTL global subsystem.', storageSpec: { title: 'QCTL Event Buffer', width: '32-bit TAG + 228-bit pending mask', depth: '8 events', contents: 'Ordered event TAG and per-endpoint pending-consumer mask', implementation: 'event_tag_q and event_pending_q arrays in lpu_qctl_event_buffer.', status: 'rtl-confirmed' }, block: qctlBlock, selected: selectedBlock('physical:control:qctl') })
      node({ id: 'reference:qctl-pool', label: 'POOL', x: 805, y: 650, width: 155, height: 96, note: 'Logical QCTL queue address space. Physical record storage is distributed across independent East/West QCTL Relay instances.', storageSpec: { title: 'QCTL Distributed Record Pool', width: '96-bit record', depth: '14 × 64 = 896 records', contents: 'Records partitioned across 228 logical endpoint queues', implementation: 'No centralized Pool array: fourteen QCTL Relay regional stores provide the physical capacity.', status: 'rtl-confirmed', extraFacts: [{ label: 'QUEUE LIMIT', value: '16 records / logical queue' }] }, block: qctlBlock, selected: selectedBlock('physical:control:qctl') })
      node({ id: 'reference:qctl-manager', label: 'QCTL\nLoad Manager', x: 610, y: 810, width: 250, height: 128, note: 'lpu_qctl_load_manager creates partition and record packets for the two independent QCTL Relay chains.', block: qctlBlock, selected: selectedBlock('physical:control:qctl') })
      node({ id: 'reference:distributor', label: 'Distributor', x: 1110, y: 810, width: 285, height: 128, note: 'Program Distributor: input elastic stage, Scope fanout and East/West Program Distribution branches.', disableDrilldown: true, programNode: programNodeBySuffix('elastic'), selected: selectedBlock('physical:control:program-load') })

      node({ id: 'reference:relay-note', label: 'Relay 拓扑示意：Program Distribution 与 QCTL 分别使用独立的 Relay 网络', x: 1510, y: 965, width: 880, height: 42, tone: 'note', note: 'One visual row expresses the common topology only. Program Distribution and QCTL instantiate separate East/West seven-stage Relay networks. The central Elastic Stage belongs only to Program Distribution.', selectable: false })
      const relayIds: string[] = []
      for (let relayIndex = 0; relayIndex < 13; relayIndex += 1) {
        const id = relayIndex === 6 ? 'reference:elastic-stage' : `reference:relay-${relayIndex}`
        relayIds.push(id)
        node({
          id,
          label: relayIndex === 6 ? 'Elastic\nStage' : 'Relay',
          x: 65 + relayIndex * 185,
          y: 1040,
          width: 130,
          height: 82,
          tone: 'relay',
          note: relayIndex === 6
            ? 'Two-entry Program Distribution input elastic stage. This node is not part of the QCTL Relay Chain.'
            : 'Common Relay topology marker. Program Distribution and QCTL use distinct physical instances; open the corresponding Inspector for RTL-specific counts and connectivity.',
          storageSpec: relayIndex === 6
            ? { title: 'Program Distributor Elastic Stage', width: '165-bit record', depth: '2 entries', contents: 'Program Load record and route metadata', implementation: 'u_elastic_fifo in lpu_program_distribute_elastic_stage; it is not part of QCTL.', status: 'rtl-confirmed' }
            : { title: 'Independent Relay Storage', width: 'Program 165 bit · QCTL 96 bit', depth: 'Program 2 entries · QCTL 64 records + 2 transit', contents: 'Program Load records / QCTL regional records', implementation: 'The single drawn row represents two independent Relay networks with the same topology, not shared storage instances.', status: 'rtl-confirmed', extraFacts: [{ label: 'INSTANCES', value: '7 per hemisphere per network' }] },
          disableDrilldown: true,
          programNode: relayIndex === 6 ? programNodeBySuffix('elastic') : programNodeBySuffix('relay-fabric'),
          selected: selectedBlock('physical:control:program-load'),
        })
      }

      const fuSpecs = [
        { blockId: 'physical:west:mxm', fu: 'mxm', label: 'MXM' },
        { blockId: 'physical:west:sxm', fu: 'sxm', label: 'SXM' },
        { blockId: 'physical:west:mem', fu: 'mem', label: 'MEM' },
        { blockId: 'physical:central:vxm', fu: 'vxm', label: 'VXM' },
        { blockId: 'physical:east:mem', fu: 'mem', label: 'MEM' },
        { blockId: 'physical:east:sxm', fu: 'sxm', label: 'SXM' },
        { blockId: 'physical:east:mxm', fu: 'mxm', label: 'MXM' },
      ] as const
      fuSpecs.forEach((spec, index) => {
        const centerX = 190 + index * 350
        const block = blockById.get(spec.blockId)
        const frontend = frontendByFu.get(spec.fu)
        node({ id: `reference:frontend-${index}`, label: 'Frontend', x: centerX - 85, y: 1255, width: 170, height: 76, note: `${spec.label} FU-local frontend. Click to open the FU-specific interactive frontend level.`, frontend })
        node({ id: spec.blockId, label: spec.label, x: centerX - 95, y: 1443, width: 190, height: 124, note: block?.function ?? `${spec.label} functional unit`, block, selected: selectedBlock(spec.blockId) })
      })

      const interfaceSpecs = [
        { left: 'physical:west:mxm', right: 'physical:west:sxm', label: 'MXM-SXM\nInterface' },
        { left: 'physical:west:sxm', right: 'physical:west:mem', label: 'SXM-MEM\nInterface' },
        { left: 'physical:west:mem', right: 'physical:central:vxm', label: 'MEM-VXM\nInterface' },
        { left: 'physical:central:vxm', right: 'physical:east:mem', label: 'VXM-MEM\nInterface' },
        { left: 'physical:east:mem', right: 'physical:east:sxm', label: 'MEM-SXM\nInterface' },
        { left: 'physical:east:sxm', right: 'physical:east:mxm', label: 'SXM-MXM\nInterface' },
      ]
      const pairInterface = (left: string, right: string) => interfaces.find((item) => item.plane === 'data' && ((item.sourceBlockId === left && item.destinationBlockId === right) || (item.sourceBlockId === right && item.destinationBlockId === left)))
      interfaceSpecs.forEach((spec, index) => {
        const item = pairInterface(spec.left, spec.right)
        node({ id: `reference:fu-interface-${index}`, label: spec.label, x: 295 + index * 350, y: 1463, width: 140, height: 84, tone: 'interface', note: item?.classificationBasis ?? `${spec.label.replace('\n', ' ')} semantic interface`, interfaceItem: item, selected: selectedInterface(item) })
      })

      edge({ id: 'reference-edge:ddr-axi', source: 'reference:ddr', target: 'reference:axi', relation: 'program' })
      edge({ id: 'reference-edge:axi-dma', source: 'reference:axi', target: 'reference:dma', relation: 'program', sourceHandle: 'bottom-source', targetHandle: 'top-target', type: 'smoothstep' })
      edge({ id: 'reference-edge:boot-controller', source: 'reference:boot-rom', target: 'reference:controller', relation: 'program', sourceHandle: 'bottom-source', targetHandle: 'top-target' })
      edge({ id: 'reference-edge:controller-dma', source: 'reference:controller', target: 'reference:dma', relation: 'program' })
      edge({ id: 'reference-edge:dma-response', source: 'reference:dma', target: 'reference:response-fifo', relation: 'program' })
      edge({ id: 'reference-edge:controller-config', source: 'reference:controller', target: 'reference:config-fifo', relation: 'program', sourceHandle: 'bottom-source', targetHandle: 'left-target', type: 'smoothstep' })
      edge({ id: 'reference-edge:response-reassembler', source: 'reference:response-fifo', target: 'reference:reassembler', relation: 'program', sourceHandle: 'bottom-source', targetHandle: 'left-target', type: 'smoothstep' })
      edge({ id: 'reference-edge:config-reassembler', source: 'reference:config-fifo', target: 'reference:reassembler', relation: 'program' })
      edge({ id: 'reference-edge:reassembler-word', source: 'reference:reassembler', target: 'reference:word-fifo', relation: 'program' })
      edge({ id: 'reference-edge:word-distributor', source: 'reference:word-fifo', target: 'reference:distributor', relation: 'program', sourceHandle: 'bottom-source', targetHandle: 'top-target', type: 'smoothstep' })
      edge({ id: 'reference-edge:event-qctl', source: 'reference:event-buffer', target: 'reference:qctl-manager', relation: 'qctl', sourceHandle: 'bottom-source', targetHandle: 'top-target', type: 'smoothstep' })
      edge({ id: 'reference-edge:pool-qctl', source: 'reference:qctl-pool', target: 'reference:qctl-manager', relation: 'qctl', sourceHandle: 'bottom-source', targetHandle: 'top-target', type: 'smoothstep' })
      edge({ id: 'reference-edge:distributor-elastic', source: 'reference:distributor', target: relayIds[6], relation: 'program', sourceHandle: 'bottom-source', targetHandle: 'top-target', type: 'smoothstep' })
      edge({ id: 'reference-edge:qctl-west-relay', source: 'reference:qctl-manager', target: relayIds[5], relation: 'qctl', sourceHandle: 'bottom-source', targetHandle: 'top-target', type: 'smoothstep' })
      edge({ id: 'reference-edge:qctl-east-relay', source: 'reference:qctl-manager', target: relayIds[7], relation: 'qctl', sourceHandle: 'bottom-source', targetHandle: 'top-target', type: 'smoothstep' })
      for (let relayIndex = 5; relayIndex > 0; relayIndex -= 1) edge({ id: `reference-edge:west-relay-${relayIndex}`, source: relayIds[relayIndex], target: relayIds[relayIndex - 1], relation: 'relay' })
      edge({ id: 'reference-edge:elastic-west', source: relayIds[6], target: relayIds[5], relation: 'relay', sourceHandle: 'left-source', targetHandle: 'right-target' })
      edge({ id: 'reference-edge:elastic-east', source: relayIds[6], target: relayIds[7], relation: 'relay' })
      for (let relayIndex = 7; relayIndex < 12; relayIndex += 1) edge({ id: `reference-edge:east-relay-${relayIndex}`, source: relayIds[relayIndex], target: relayIds[relayIndex + 1], relation: 'relay' })
      const relayTapIndices = [0, 2, 4, 6, 8, 10, 12]
      relayTapIndices.forEach((relayIndex, fuIndex) => edge({ id: `reference-edge:relay-frontend-${fuIndex}`, source: relayIds[relayIndex], target: `reference:frontend-${fuIndex}`, relation: 'frontend', sourceHandle: 'bottom-source', targetHandle: 'top-target', type: 'smoothstep' }))
      fuSpecs.forEach((spec, index) => edge({ id: `reference-edge:frontend-fu-${index}`, source: `reference:frontend-${index}`, target: spec.blockId, relation: 'frontend', sourceHandle: 'bottom-source', targetHandle: 'top-target', type: 'smoothstep' }))
      interfaceSpecs.forEach((spec, index) => {
        edge({ id: `reference-edge:fu-interface-left-${index}`, source: spec.left, target: `reference:fu-interface-${index}`, relation: 'interface', arrow: false })
        edge({ id: `reference-edge:fu-interface-right-${index}`, source: `reference:fu-interface-${index}`, target: spec.right, relation: 'interface', arrow: false })
      })

      const query = signalQuery.trim().toLowerCase()
      if (query) for (const item of nodes) {
        const content = `${item.data.topologyNode?.label ?? ''} ${item.data.topologyNode?.note ?? ''}`.toLowerCase()
        item.style = { ...item.style, opacity: content.includes(query) ? 1 : 0.24 }
      }
      const visibleEdges = edges.filter((item) => planeFilter === 'all' || (planeFilter === 'data' ? item.data?.relation === 'interface' : item.data?.relation !== 'interface'))
      return { nodes, edges: visibleEdges }
    }

    const programBlockId = 'physical:control:program-load'
    const programRootId = 'arch:control:program-load'
    const programBlock = blocks.find((block) => block.id === programBlockId)
    const frontendByFu = new Map<string, ConfigurationFrontend>(frontends.map((frontend) => [frontend.fu, frontend]))
    // FU-local frontend entry points are rendered directly above their MEM/MXM/SXM/VXM
    // blocks in the physical topology. Keep the detailed retire/boundary model in the
    // snapshot for drill-down evidence, but do not duplicate it as a separate L3 band.
    const programNodes = drillNodes.filter((node) => node.blockId === programBlockId && node.parentId === programRootId && programLoadNodeLayout[node.id])
    const programNodeIds = new Set(programNodes.map((node) => node.id))
    const programInterfaces = drillInterfaces.filter((item) => item.blockId === programBlockId && programNodeIds.has(item.sourceNodeId) && programNodeIds.has(item.destinationNodeId))
    const displayBlockId = (id: string) => id === 'physical:control:instruction-dma' ? programBlockId : id
    const rawHighlightedBlockIds = new Set<string>()
    if (selectedRawConnectionId) for (const item of interfaces) if (item.rawConnectionIds.includes(selectedRawConnectionId)) {
      rawHighlightedBlockIds.add(displayBlockId(item.sourceBlockId))
      rawHighlightedBlockIds.add(displayBlockId(item.destinationBlockId))
    }
    const nodes: Node<PhysicalNodeData>[] = regions.map((region) => ({
      id: `physical-region:${region.id}`,
      type: 'region',
      position: { x: regionLayout[region.id].x, y: regionLayout[region.id].y },
      style: { width: regionLayout[region.id].width, height: regionLayout[region.id].height, zIndex: -5 },
      draggable: false,
      selectable: false,
      data: { region, selected: false, rawHighlighted: false },
    }))
    if (programBlock) {
      for (const [id, group] of Object.entries(programLoadLayerLayout)) nodes.push({
        id: `${programRootId}:layer:${id}`,
        type: 'programGroup',
        parentId: 'physical-region:control',
        position: { x: group.x, y: group.y },
        style: { width: group.width, height: group.height, zIndex: -3 },
        draggable: false,
        selectable: false,
        data: { programGroup: { id: `layer-${id}`, label: group.label, note: group.note, role: 'layer' }, ownerBlock: programBlock, selected: selectedBlockId === programBlockId, rawHighlighted: rawHighlightedBlockIds.has(programBlockId) },
      })
      for (const item of programNodes) {
        const layout = programLoadNodeLayout[item.id]
        nodes.push({
          id: item.id,
          type: 'programStage',
          parentId: 'physical-region:control',
          position: { x: layout.x, y: layout.y },
          style: { width: layout.width, height: layout.height, zIndex: selectedBlockId === programBlockId ? 14 : 10 },
          draggable: false,
          data: { programNode: item, ownerBlock: programBlock, selected: selectedBlockId === programBlockId, rawHighlighted: rawHighlightedBlockIds.has(programBlockId) },
        })
      }
    }
    for (const item of blocks) {
      if (item.id === 'physical:control:instruction-dma' || item.id === programBlockId) continue
      const layout = blockLayout[item.id]
      if (!layout) continue
      nodes.push({
        id: item.id,
        type: 'functional',
        parentId: `physical-region:${item.regionId}`,
        position: { x: layout.x, y: layout.y },
        style: { width: layout.width, height: layout.height, zIndex: selectedBlockId === item.id || (selectedBlockId === 'physical:control:instruction-dma' && item.id === 'physical:control:program-load') ? 14 : 10 },
        draggable: false,
        data: { block: item, selected: selectedBlockId === item.id || (selectedBlockId === 'physical:control:instruction-dma' && item.id === 'physical:control:program-load'), rawHighlighted: rawHighlightedBlockIds.has(item.id) },
      })
      const frontend = frontendByFu.get(item.kind)
      if (frontend) {
        const markerWidth = Math.min(230, layout.width - 30)
        nodes.push({
          id: `physical-frontend:${item.id}`,
          type: 'frontendMarker',
          parentId: `physical-region:${item.regionId}`,
          position: { x: layout.x + (layout.width - markerWidth) / 2, y: 62 },
          style: { width: markerWidth, height: 58, zIndex: 12 },
          draggable: false,
          data: { frontend, ownerBlock: item, selected: false, rawHighlighted: false },
        })
      }
    }
    const query = signalQuery.trim().toLowerCase()
    const rawMap = new Map(rawConnections.map((raw) => [raw.id, raw]))
    const visible = interfaces.filter((item) => {
      if (item.id === 'physical-interface:program:dma-command' || item.id === 'physical-interface:program:dma-response') return false
      if (planeFilter !== 'all' && item.plane !== planeFilter) return false
      if (query && !`${item.name} ${item.direction} ${item.classificationBasis} ${item.rawConnectionIds.join(' ')}`.toLowerCase().includes(query)) return false
      return true
    })
    const blockById = new Map(blocks.map((block) => [block.id, block]))
    const physicalEndpointId = (item: PhysicalInterface, blockId: string) => {
      if (blockId === 'physical:control:instruction-dma') return 'arch:control:program-load:instruction-dma'
      const endpointBlock = blockById.get(blockId)
      if (blockId === item.destinationBlockId && endpointBlock && frontendByFu.has(endpointBlock.kind) && (item.direction === 'program-load' || item.direction === 'instruction-dispatch')) return `physical-frontend:${blockId}`
      if (blockId !== programBlockId) return blockId
      if (item.direction === 'program-load' && item.destinationBlockId === 'physical:central:vxm') return 'arch:control:program-load:elastic'
      if (item.direction === 'program-load' && /^physical:(west|east):/.test(item.destinationBlockId)) return programRelayFabricId
      return 'arch:control:program-load:fu-entry'
    }
    const globalLeft = (blockId: string) => {
      if (blockId === programBlockId || blockId === 'physical:control:instruction-dma') return regionLayout.control.x + programLoadNodeLayout['arch:control:program-load:instruction-dma'].x
      const block = blockById.get(blockId)
      const region = block ? regionLayout[block.regionId] : undefined
      const layout = blockLayout[blockId]
      return region && layout ? region.x + layout.x : 0
    }
    const pairKeyFor = (item: PhysicalInterface) => [item.sourceBlockId, item.destinationBlockId].sort().join('::')
    const pairSummary = new Map<string, { name: string; signalCount: number; rawConnectionIds: string[]; sourceName: string; destinationName: string }>()
    for (const item of visible) if (item.plane === 'data') {
      const key = pairKeyFor(item)
      const sourceFirst = globalLeft(item.sourceBlockId) <= globalLeft(item.destinationBlockId)
      const left = blockById.get(sourceFirst ? item.sourceBlockId : item.destinationBlockId)
      const right = blockById.get(sourceFirst ? item.destinationBlockId : item.sourceBlockId)
      const name = `${(left?.shortName ?? 'Module').replace(/\s*×\d+$/, '')}–${(right?.shortName ?? 'Module').replace(/\s*×\d+$/, '')} Interface`
      const previous = pairSummary.get(key)
      pairSummary.set(key, {
        name,
        signalCount: (previous?.signalCount ?? 0) + item.signalCount,
        rawConnectionIds: [...new Set([...(previous?.rawConnectionIds ?? []), ...item.rawConnectionIds])],
        sourceName: left?.displayName ?? 'Left endpoint',
        destinationName: right?.displayName ?? 'Right endpoint',
      })
    }
    const labelSeen = new Set<string>()
    const edges: Edge<PhysicalEdgeData>[] = visible.flatMap((item) => {
      const sourceId = physicalEndpointId(item, item.sourceBlockId)
      const targetId = physicalEndpointId(item, item.destinationBlockId)
      if (sourceId === targetId) return []
      const pairKey = item.plane === 'data' ? pairKeyFor(item) : undefined
      const labelKey = pairKey ? `pair:${pairKey}` : item.plane === 'control' ? `${item.destinationBlockId}:${item.direction}` : item.id
      const showLabel = !labelSeen.has(labelKey) && (connectivityMode || item.direction !== 'instruction-dispatch')
      labelSeen.add(labelKey)
      const summary = pairKey ? pairSummary.get(pairKey) : undefined
      const semantic = interfaceSemanticPresentation(item.id, item.name)
      const labelName = summary?.name ?? semantic.displayName
      const edgeColor = item.id === selectedInterfaceId ? '#c17823' : ENGINEERING_NAVY
      const endpointName = (blockId: string) => blockId === programBlockId && item.direction === 'program-load' && item.destinationBlockId === 'physical:central:vxm'
        ? 'Elastic Stage → VXM Boundary'
        : blockId === programBlockId && item.direction === 'program-load' && /^physical:(west|east):/.test(item.destinationBlockId)
        ? 'Relay Chain → FU Frontend / local iMEM'
        : blockById.get(blockId)?.displayName ?? blockId
      const sourceName = summary?.sourceName ?? endpointName(item.sourceBlockId)
      const destinationName = summary?.destinationName ?? endpointName(item.destinationBlockId)
      const rawIds = summary?.rawConnectionIds ?? item.rawConnectionIds
      return [{
        id: item.id,
        source: sourceId,
        target: targetId,
        type: 'physical',
        markerEnd: { type: MarkerType.ArrowClosed, width: 12, height: 8, color: edgeColor },
        data: {
          interface: item,
          selected: item.id === selectedInterfaceId,
          showLabel,
          labelName,
          labelSignalCount: summary?.signalCount ?? item.signalCount,
          pairKey,
          sourceName,
          destinationName,
          rawConnections: rawIds.map((id) => rawMap.get(id)).filter(Boolean) as RawConnection[],
          status: `${semantic.confidence ?? item.evidenceStatus} · ${item.pathKind}`,
          onSelect: onSelectInterface,
        },
        zIndex: item.id === selectedInterfaceId ? 4 : item.plane === 'control' ? 1 : 2,
      }]
    })
    // Only real functional rectangles are routing obstacles. The large system/layer
    // containers are intentionally absent so a connection may cross their background,
    // while it can never cut through Decoder, FIFO, Branch, Relay or FU rectangles.
    const boxes: GraphBox[] = blocks.flatMap((block) => {
      if (block.id === 'physical:control:instruction-dma' || block.id === programBlockId) return []
      const region = regionLayout[block.regionId]
      const layout = blockLayout[block.id]
      if (!region || !layout) return []
      const result: GraphBox[] = [{ id: block.id, x: region.x + layout.x, y: region.y + layout.y, width: layout.width, height: layout.height }]
      if (frontendByFu.has(block.kind)) {
        const markerWidth = Math.min(230, layout.width - 30)
        result.push({ id: `physical-frontend:${block.id}`, x: region.x + layout.x + (layout.width - markerWidth) / 2, y: region.y + 62, width: markerWidth, height: 58 })
      }
      return result
    })
    for (const item of programNodes) {
      const layout = programLoadNodeLayout[item.id]
      boxes.push({ id: item.id, x: regionLayout.control.x + layout.x, y: regionLayout.control.y + layout.y, width: layout.width, height: layout.height })
    }
    const routeHint = (item: PhysicalInterface) => {
      const localProgram = /physical-interface:control:(west|east):(mem|mxm):program/.test(item.id)
      const dispatch = item.direction === 'instruction-dispatch'
      const dmaRequest = item.id === 'physical-interface:dma:external-request'
      const dmaResponse = item.id === 'physical-interface:dma:external-response'
      const routingLane = item.id.includes(':west:') ? 0 : item.id.includes(':east:') ? 2 : item.plane === 'status' ? 4 : 1
      return {
        sourceSide: dmaRequest ? 'top' as const : dmaResponse ? 'bottom' as const : localProgram || dispatch ? 'bottom' as const : undefined,
        targetSide: dmaRequest ? 'bottom' as const : dmaResponse ? 'top' as const : localProgram || dispatch ? 'top' as const : undefined,
        routingLane,
      }
    }
    const plans = layoutOrthogonalEdges(boxes, edges.map((edge) => {
      const item = edge.data!.interface
      const hint = routeHint(item)
      return {
        id: edge.id,
        sourceId: edge.source,
        targetId: edge.target,
        semanticName: edge.data!.pairKey ? 'link' : edge.data!.labelName,
        sourceSide: hint.sourceSide,
        targetSide: hint.targetSide,
        plane: item.plane,
        lineStyle: item.plane === 'status' || item.pathKind === 'processed-path' || item.pathKind === 'blocked-boundary' ? 'dashed' as const : 'solid' as const,
        routingLane: hint.routingLane,
        direction: item.direction,
      }
    }), { obstaclePadding: 30, channelSpacing: 30, labelClearance: 18, labelSpacing: 14, maxLabelWidth: 220, laneSearchCount: 5, canvasPadding: 300 })
    for (const edge of edges) {
      const plan = plans.get(edge.id)
      if (!plan) continue
      edge.sourceHandle = `${plan.sourceSide}-source`
      edge.targetHandle = `${plan.targetSide}-target`
      edge.data!.route = plan
      if (edge.data!.showLabel && edge.data!.pairKey) {
        const source = boxes.find((box) => box.id === edge.source)
        const target = boxes.find((box) => box.id === edge.target)
        if (source && target) {
          const sourceCenterX = source.x + source.width / 2
          const targetCenterX = target.x + target.width / 2
          plan.labelX = sourceCenterX <= targetCenterX ? (source.x + source.width + target.x) / 2 : (target.x + target.width + source.x) / 2
          plan.labelY = (source.y + source.height / 2 + target.y + target.height / 2) / 2
          plan.labelWidth = 152
          plan.labelHeight = 58
          plan.labelAnchorX = plan.labelX
          plan.labelAnchorY = plan.labelY
          plan.labelOffset = { x: 0, y: 0 }
        }
      }
    }
    const visibleProgramInterfaces = programInterfaces.filter((item) => {
      if (planeFilter !== 'all' && item.plane !== planeFilter) return false
      if (query && !`${item.name} ${item.category} ${item.direction}`.toLowerCase().includes(query)) return false
      return true
    })
    const programEdges: Edge<ProgramLoadEdgeData>[] = visibleProgramInterfaces.map((item) => ({
      id: item.id,
      source: item.sourceNodeId,
      target: item.destinationNodeId,
      type: 'programLoad',
      markerEnd: { type: MarkerType.ArrowClosed, width: 11, height: 7, color: item.plane === 'status' ? '#6b4e91' : ENGINEERING_NAVY },
      data: { interface: item, labelName: interfaceSemanticPresentation(item.id, item.name).displayName, selected: false, onSelect: onSelectDrillInterface },
      zIndex: item.plane === 'status' ? 2 : 3,
    }))
    const programRouteHint = (item: ArchitectureDrillInterface) => {
      const id = item.id
      if (id.includes(':interface:main-')) return { sourceSide: 'right' as const, targetSide: 'left' as const, routingLane: id.endsWith('vxm-direct') ? 3 : 0 }
      if (id.endsWith(':command-write') || id.endsWith(':dma-command') || id.endsWith(':dma-response') || id.endsWith(':reservoir-builder') || id.endsWith(':word-handoff')) return { sourceSide: 'right' as const, targetSide: 'left' as const, routingLane: 0 }
      if (id.endsWith(':context-enqueue')) return { sourceSide: 'top' as const, targetSide: 'top' as const, routingLane: 3 }
      if (id.endsWith(':descriptor-fetch') || id.endsWith(':response-reservoir') || id.endsWith(':context-builder') || id.endsWith(':word-enqueue') || id.endsWith(':prime-handoff') || id.endsWith(':elastic-handoff')) return { sourceSide: 'bottom' as const, targetSide: 'top' as const, routingLane: 1 }
      if (id.endsWith(':elastic-decode')) return { sourceSide: 'bottom' as const, targetSide: 'top' as const, routingLane: 0 }
      if (id.endsWith(':west')) return { sourceSide: 'left' as const, targetSide: 'top' as const, routingLane: 1 }
      if (id.endsWith(':east')) return { sourceSide: 'right' as const, targetSide: 'top' as const, routingLane: 2 }
      if (id.endsWith(':west-relay-chain')) return { sourceSide: 'right' as const, targetSide: 'left' as const, routingLane: 0 }
      if (id.endsWith(':east-relay-chain')) return { sourceSide: 'left' as const, targetSide: 'right' as const, routingLane: 0 }
      if (id.endsWith(':imem-write') || id.endsWith(':endpoint-boundary')) return { sourceSide: 'bottom' as const, targetSide: 'top' as const, routingLane: id.endsWith(':imem-write') ? 1 : 3 }
      if (id.endsWith(':commit')) return { sourceSide: 'left' as const, targetSide: 'left' as const, routingLane: 7 }
      if (id.endsWith(':start')) return { sourceSide: 'bottom' as const, targetSide: 'right' as const, routingLane: 6 }
      if (id.endsWith(':fault')) return { sourceSide: 'right' as const, targetSide: 'right' as const, routingLane: 11 }
      if (id.endsWith(':program-reset')) return { sourceSide: 'right' as const, targetSide: 'right' as const, routingLane: 13 }
      return { sourceSide: 'bottom' as const, targetSide: 'top' as const, routingLane: 4 }
    }
    const programPlans = layoutOrthogonalEdges(boxes, programEdges.map((edge, edgeIndex) => {
      const item = edge.data!.interface
      const hint = programRouteHint(item)
      return {
        id: edge.id,
        sourceId: edge.source,
        targetId: edge.target,
        semanticName: edge.data!.labelName,
        sourceSide: hint.sourceSide,
        targetSide: hint.targetSide,
        plane: item.plane,
        lineStyle: item.plane === 'status' || item.confidenceStatus === 'needs-review' ? 'dashed' as const : 'solid' as const,
        routingLane: hint.routingLane ?? edgeIndex % 9,
      }
    }), { obstaclePadding: 40, channelSpacing: 44, labelClearance: 26, labelSpacing: 20, maxLabelWidth: 200, laneSearchCount: 17, canvasPadding: 420 })
    for (const edge of programEdges) {
      const plan = programPlans.get(edge.id)
      if (!plan) continue
      edge.sourceHandle = `${plan.sourceSide}-source`
      edge.targetHandle = `${plan.targetSide}-target`
      edge.data!.route = plan
    }
    const frontendEdges: Edge<FrontendControlEdgeData>[] = planeFilter === 'data' ? [] : blocks.flatMap<Edge<FrontendControlEdgeData>>((block) => {
      const frontend = frontendByFu.get(block.kind)
      if (!frontend || !blockLayout[block.id]) return []
      return [{
        id: `physical-frontend-control:${block.id}`,
        source: `physical-frontend:${block.id}`,
        target: block.id,
        sourceHandle: 'bottom-source',
        targetHandle: 'top-target',
        type: 'smoothstep',
        className: 'physical-frontend-control-edge',
        style: { stroke: '#a46518', strokeWidth: 4 },
        markerEnd: { type: MarkerType.ArrowClosed, width: 14, height: 10, color: '#a46518' },
        data: { frontendId: frontend.id },
        zIndex: 5,
      }]
    })
    return { nodes, edges: [...edges, ...programEdges, ...frontendEdges] }
  }, [regions, blocks, interfaces, drillNodes, drillInterfaces, frontends, rawConnections, selectedBlockId, selectedInterfaceId, selectedRawConnectionId, planeFilter, signalQuery, connectivityMode, onSelectInterface, onSelectDrillInterface])

  const activeFrontend = activeFrontendId == null ? null : frontends.find((frontend) => frontend.id === activeFrontendId) ?? null
  if (activeFrontend) return <FrontendArchitectureLevel frontend={activeFrontend} onBack={() => setActiveFrontendId(null)} onFocusModeChange={onFocusModeChange} />

  return <ReactFlow<Node<PhysicalNodeData>, PhysicalGraphEdge>
    key={`${planeFilter}:${connectivityMode}`}
    nodes={model.nodes}
    edges={model.edges as PhysicalGraphEdge[]}
    nodeTypes={nodeTypes}
    edgeTypes={edgeTypes}
    nodesDraggable={false}
    nodesConnectable={false}
    onNodeClick={(_, node) => {
      const data = node.data as PhysicalNodeData
      if (data.frontend) setActiveFrontendId(data.frontend.id)
      else if (data.interfaceItem) onSelectInterface(data.interfaceItem.id)
      else if (data.topologyNode?.disableDrilldown) return
      else if (data.programNode || data.programGroup) onOpenBlock('physical:control:program-load')
      else if (data.block) onOpenBlock(data.block.id)
    }}
    onEdgeClick={(_, edge) => { if (edge.type === 'programLoad') onSelectDrillInterface(edge.id); else if (edge.type === 'physical') onSelectInterface(edge.id) }}
    minZoom={0.25}
    maxZoom={1.8}
    fitView
    fitViewOptions={fitOptions}
    onInit={(instance) => { flowRef.current = instance }}
    proOptions={{ hideAttribution: true }}
    className={`engineering-graph physical-engineering-graph ${connectivityMode ? '' : 'physical-reference-topology'}`}
    colorMode="light"
  >
    <Background color="#cbd4e1" gap={28} size={1} />
    <MiniMap position="top-right" pannable zoomable nodeColor={(node) => (node.type === 'region' ? '#dce4ef' : '#9db3d2')} maskColor="rgba(230, 235, 242, .78)" />
    <Controls showInteractive={false} />
  </ReactFlow>
}
