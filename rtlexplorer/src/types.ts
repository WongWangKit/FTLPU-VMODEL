export type PortDirection = 'input' | 'output' | 'inout' | 'ref' | 'unknown'

export interface Parameter {
  name: string
  default: string | null
  raw: string
  resolvedDefault: number | null
}

export interface Port {
  name: string
  direction: PortDirection
  width: number | null
  widthExpression: string
  dataType: string
  packedDimensions: string[]
  unpackedDimensions: string[]
  raw: string
  line: number | null
}

export interface Connection {
  port: string | null
  expression: string
  kind: 'signal' | 'constant' | 'concatenation' | 'expression' | 'unconnected'
  positionalIndex: number | null
  direction: PortDirection
  width: number | null
  widthExpression: string | null
  connectedModule: string | null
  line: number | null
}

export interface ContinuousAssignment {
  id: string
  left: string
  right: string
  expression: string
  file: string
  line: number
  kind: 'continuous'
}

export interface InstanceTemplate {
  id: string
  name: string
  moduleName: string
  line: number | null
  sourceFile: string
  parameterOverrides: Array<{ name: string | null; value: string; positionalIndex: number | null }>
  connections: Connection[]
  generated: boolean
  generateContext: string | null
  unresolved: boolean
}

export interface ModuleDefinition {
  id: string
  name: string
  file: string
  line: number
  endLine: number
  parameters: Parameter[]
  ports: Port[]
  instances: InstanceTemplate[]
  assignments: ContinuousAssignment[]
  description: { text: string; source: string; status: string }
  userDescription?: string
  userDescriptionUpdatedAt?: string | null
}

export interface HierarchyNode {
  id: string
  path: string
  name: string
  moduleName: string
  parentId: string | null
  depth: number
  line: number | null
  sourceFile: string
  generated: boolean
  generateContext: string | null
  unresolved: boolean
  definitionId: string | null
  templateId?: string
}

export interface HierarchyEdge {
  id: string
  source: string
  target: string
  instanceName: string
  moduleName: string
  generated: boolean
  connections: Connection[]
}

export interface Warning {
  code: string
  severity: 'warning' | 'error' | string
  file: string
  line: number | null
  message: string
}

export interface ArchitectureContainer extends HierarchyNode {
  displayName: string
  role: string
  classification: 'primary-subsystem-path' | 'legacy-direct-instantiation'
  primary: boolean
  template: boolean
  childCount: number
}

export interface InterfaceEndpoint {
  id: string
  instanceId: string
  instanceName: string
  moduleName: string
  portName: string
  portDirection: PortDirection
  flow: 'source' | 'destination' | 'unknown'
  width: number | null
  widthExpression: string | null
  sourceFile: string
  line: number | null
  generated: boolean
  boundary: boolean
}

export interface RawConnection {
  id: string
  scopeId: string
  scopeModule: string
  signalName: string
  connectionExpression: string
  sourceEndpoints: InterfaceEndpoint[]
  destinationEndpoints: InterfaceEndpoint[]
  unresolvedEndpoints: InterfaceEndpoint[]
  resolvedWidth: number | null
  widthExpressions: string[]
  sourceFile: string
  line: number | null
  evidence: string[]
  connectionStatus: 'rtl-confirmed' | 'partial-or-unresolved'
  semanticId?: string
  semanticName?: string
  signalGroup?: { id: string; name: string }
}

export interface SemanticInterface {
  id: string
  scopeId: string
  scopeModule: string
  semanticName: string
  category: string
  connectionStatus: 'rtl-confirmed'
  semanticStatus: 'auto-inferred' | 'manual-confirmed' | 'needs-review'
  confidence: 'confirmed' | 'high' | 'medium' | 'low'
  classificationBasis: string
  manuallyConfirmed: boolean
  rawConnectionIds: string[]
  sourceInstances: Array<{ id: string; name: string; moduleName: string; boundary: boolean }>
  destinationInstances: Array<{ id: string; name: string; moduleName: string; boundary: boolean }>
  signalGroups: Array<{ id: string; name: string; rawConnectionIds: string[] }>
  sourceLocations: Array<{ file: string; line: number | null }>
  signalCount: number
  totalWidth: number | null
  hasUnresolvedWidth: boolean
  bidirectional: boolean
}

export interface ArchitectureModel {
  schemaVersion: number
  generatedAt: string
  policy: {
    defaultView: 'architecture'
    primaryOrganization: 'subsystem'
    primaryTopInstances: string[]
    legacyTopInstances: string[]
    legacyRootIds: string[]
    statement: string
    semanticDisclaimer: string
  }
  containers: ArchitectureContainer[]
  containment: Array<{ id: string; parentId: string; childId: string; relation: 'containment'; primary: boolean }>
  interfaces: SemanticInterface[]
  rawConnections: RawConnection[]
  summary: {
    containerCount: number
    primaryContainerCount: number
    legacyContainerCount: number
    containmentCount: number
    interfaceCount: number
    rawConnectionCount: number
    confirmedConnectionCount: number
    inferredSemanticCount: number
    manualSemanticCount: number
    needsReviewCount: number
    coverageByModule: Array<{ moduleName: string; scopeCount: number; interfaceCount: number; signalCount: number; needsReviewCount: number }>
  }
}

export type EvidenceStatus = 'rtl-confirmed' | 'simulation-model-confirmed' | 'architecture-inferred' | 'reference-manual' | 'partially-verified' | 'needs-review'

export interface PhysicalSourceLocation {
  file: string
  line: number | null
}

export interface PhysicalRtlMapping {
  rtlNodeId: string | null
  rtlPath: string | null
  moduleName: string | null
  instanceName: string | null
  instanceSelector: string
  cardinality: number
  generateContext: string | null
  source: PhysicalSourceLocation | null
  evidenceStatus: EvidenceStatus
  basis: string
}

export interface PhysicalFact {
  label: string
  value: number | null
  expression: string
  evidenceStatus: EvidenceStatus
  source: PhysicalSourceLocation
}

export interface PhysicalBlockStructure {
  viewType: 'mem-array' | 'mxm-array' | 'sxm-fabric' | 'vxm-tiles' | 'control-complex' | 'optional-control' | 'program-load-pipeline' | 'program-command-store' | 'reassembly-pipeline' | 'distribution-fabric' | 'hemisphere-router' | 'instruction-dma' | 'external-memory' | 'external-bus-boundary'
  facts?: PhysicalFact[]
  array?: { groups: number; columnsPerGroup: number; banksPerColumn: number; tilesPerBank: number }
  controlPath?: string[]
  storagePath?: string[]
  executionPath?: string[]
  namingNote?: string
}

export interface PhysicalRegion {
  id: 'west' | 'central' | 'east' | 'control' | 'external'
  name: string
  order: number
  placementStatus: EvidenceStatus
  topologyStatus: EvidenceStatus
  basis: string
}

export interface PhysicalFunctionalBlock {
  id: string
  displayName: string
  shortName: string
  kind: 'mem' | 'sxm' | 'mxm' | 'vxm' | 'instruction-control' | 'qctl' | 'program-load-pipeline' | 'program-store' | 'instruction-reassembly' | 'program-distributor' | 'hemisphere-router' | 'instruction-dma' | 'external-memory' | 'external-bus-boundary'
  regionId: PhysicalRegion['id']
  order: number
  function: string
  instanceCount: number
  instanceCountExpression: string
  instanceCountStatus: EvidenceStatus
  placementStatus: EvidenceStatus
  placementBasis: string
  primary: boolean
  enabledByDefault: boolean
  rtlMappings: PhysicalRtlMapping[]
  definitionNames: string[]
  parameters: string[]
  structure: PhysicalBlockStructure
  inputInterfaceIds: string[]
  outputInterfaceIds: string[]
}

export interface PhysicalInterfacePathStep {
  label: string
  file: string
  line: number
  kind: 'port-binding' | 'indexed-net' | 'direct-net' | 'processing-stage' | 'continuous-assignment' | 'wrapper-chain' | string
}

export interface PhysicalInterface {
  id: string
  name: string
  plane: 'data' | 'control' | 'status'
  direction: 'east-stream' | 'west-stream' | 'instruction-dispatch' | 'program-load' | string
  sourceBlockId: string
  destinationBlockId: string
  semanticInterfaceIds: string[]
  rawConnectionIds: string[]
  signalGroups: Array<{ id: string; name: string; rawConnectionIds: string[] }>
  signalCount: number
  totalResolvedWidth: number | null
  evidenceStatus: EvidenceStatus
  topologyStatus: EvidenceStatus
  pathKind: 'direct-net' | 'indexed-net-alias' | 'continuous-alias' | 'processed-path' | 'wrapper-chain' | string
  classificationBasis: string
  rtlPath: PhysicalInterfacePathStep[]
  notes: string[]
}

export type ArchitectureLevel = 'functional' | 'structural' | 'rtl'
export type ArchitectureSourceKind = 'rtl-module-instance' | 'generate-structure' | 'parameterized-structure' | 'architectural-grouping'

export interface ArchitectureParameterRef {
  name: string
  expression: string
  value: number | null
  evidenceStatus: EvidenceStatus
  source: PhysicalSourceLocation
}

export interface ArchitectureRtlInstanceRef {
  rtlNodeId: string | null
  rtlPath: string | null
  moduleName: string
  instanceSelector: string
}

export interface ArchitectureSourceEvidence extends PhysicalSourceLocation {
  basis: string
  evidenceStatus: EvidenceStatus
}

export interface ArchitectureDrillNode {
  id: string
  blockId: string
  displayName: string
  architectureLevel: ArchitectureLevel
  nodeType: string
  parentId: string | null
  description: string
  childIds: string[]
  interfaceIds: string[]
  rtlModuleRefs: string[]
  rtlInstanceRefs: ArchitectureRtlInstanceRef[]
  parameterRefs: ArchitectureParameterRef[]
  sourceEvidence: ArchitectureSourceEvidence[]
  confidenceStatus: EvidenceStatus
  sourceKind: ArchitectureSourceKind
  layout: 'pipeline' | 'grid' | 'array' | 'branch' | 'split' | 'queue-map' | string
  tags: Array<{ label: string; value: string }>
  selector: string | null
  architectureContainer: string | null
  handoffStage: string | null
  boundaryRole: string | null
}

export interface ArchitectureDrillInterface {
  id: string
  blockId: string
  scopeNodeId: string
  name: string
  category: string
  plane: 'data' | 'control' | 'status'
  direction: string
  sourceNodeId: string
  destinationNodeId: string
  semanticDescription: string
  rawConnectionIds: string[]
  signalGroups: Array<{ id: string; name: string; rawConnectionIds: string[] }>
  signalCount: number
  totalResolvedWidth: number | null
  confidenceStatus: EvidenceStatus
  sourceEvidence: ArchitectureSourceEvidence[]
  notes: string[]
}

export interface ArchitectureDrilldownModel {
  schemaVersion: number
  generatedAt: string
  rootNodeIdsByBlock: Record<string, string>
  nodes: ArchitectureDrillNode[]
  interfaces: ArchitectureDrillInterface[]
  summary: {
    nodeCount: number
    functionalNodeCount: number
    structuralNodeCount: number
    rtlBackedNodeCount: number
    parameterizedNodeCount: number
    interfaceCount: number
    interfacesWithRawSignals: number
  }
}

export interface PhysicalArchitectureModel {
  schemaVersion: number
  generatedAt: string
  policy: {
    defaultView: 'physical'
    statement: string
    accuracyStatement: string
    floorplanDisclaimer: string
    evidenceLevels: EvidenceStatus[]
  }
  regions: PhysicalRegion[]
  blocks: PhysicalFunctionalBlock[]
  interfaces: PhysicalInterface[]
  drilldown: ArchitectureDrilldownModel
  rtlMappings: Array<{ blockId: string; rtlNodeId: string | null; moduleName: string | null; instanceSelector: string; evidenceStatus: EvidenceStatus }>
  wrapperMappings: Array<{ moduleName: string; architectureRole: string; showAsFunctionalBlock: boolean; status: EvidenceStatus; basis: string; rtlNodeIds: string[] }>
  summary: {
    regionCount: number
    functionalBlockCount: number
    optionalBlockCount: number
    dataInterfaceCount: number
    controlInterfaceCount: number
    confirmedPlacementCount: number
    inferredPlacementCount: number
  }
  sourceEvidence: string[]
}

export interface ConfigurationEvidence {
  file: string
  line: number
  symbol: string
  expression: string
  status: EvidenceStatus
}

export interface ConfigurationUnit {
  id: string
  name: string
  unitType: string
  category: 'structure' | 'storage' | 'buffer' | 'register' | 'interface' | 'control' | 'compute' | string
  count: number | null
  expression: string
  evidence: ConfigurationEvidence[]
  status: EvidenceStatus
  detail: string | null
  tier?: number
}

export interface ConfigurationCompositionLink {
  id: string
  sourceUnitId: string
  targetUnitId: string
  label: string
  status: EvidenceStatus
}

export interface ConfigurationComposition {
  id: string
  name: string
  fu: 'mem' | 'mxm' | 'sxm' | 'vxm' | 'control' | string
  instanceCount: number | null
  status: EvidenceStatus
  evidence: ConfigurationEvidence[]
  units: ConfigurationUnit[]
  links: ConfigurationCompositionLink[]
}

export interface ConfigurationFrontendStage {
  id: string
  name: string
  role: string
  status: EvidenceStatus
  specs: Array<{
    label: string
    value: string
    status: EvidenceStatus
  }>
  pipeline?: {
    kind: 'decoder' | 'scheduler'
    visualization?: 'pipeline' | 'state-machine'
    stateBadge?: string
    title: string
    summary: string
    inputLabel: string
    outputLabel: string
    timingNote: string
    steps: Array<{
      id: string
      name: string
      description: string
      boundary: string
      tone?: 'main' | 'idle' | 'dictionary' | 'escape' | 'done' | 'fault' | 'fault-summary'
      rtlStates?: string[]
      position?: { x: number; y: number; width?: number; height?: number }
      annotation?: boolean
    }>
    transitions?: Array<{
      id: string
      source: string
      target: string
      label: string
      sourceHandle?: string
      targetHandle?: string
      tone?: 'main' | 'dictionary' | 'escape' | 'done' | 'fault' | 'loop'
      offset?: number
    }>
  }
  evidence: ConfigurationEvidence[]
}

export interface ConfigurationFrontendVariant {
  id: string
  name: string
  count: number | null
  status: EvidenceStatus
  stages: ConfigurationFrontendStage[]
}

export interface ConfigurationFrontend {
  id: 'mem' | 'mxm' | 'sxm' | 'vxm'
  label: string
  fu: 'mem' | 'mxm' | 'sxm' | 'vxm'
  instanceCount: number | null
  status: EvidenceStatus
  integration: string
  summary: string
  variants: ConfigurationFrontendVariant[]
  evidence: ConfigurationEvidence[]
}

export interface ConfigurationOverviewModel {
  schemaVersion: number
  generatedAt: string
  source: {
    snapshotGeneratedAt: string
    projectRoot: string | null
    selectedTop: string | null
    rtlFileCount: number | null
    packageSha256: string | null
  }
  policy: { statement: string; warning: string }
  summary: Array<{
    id: string
    label: string
    total: number | null
    perHemisphere: number | null
    availability: string
    status: EvidenceStatus
    evidence: ConfigurationEvidence[]
  }>
  programLoad: {
    controlDomain: {
      widthBits: number
      values: string[]
      relationship: string
      status: EvidenceStatus
      evidence: ConfigurationEvidence[]
    }
    wordTransport: {
      dataBits: number
      strobeBits: number
      bitsPerStrobe: number
      addressBits: number
      scopeBits: number
      destinationBits: number
      sequenceIdPresent: boolean
      status: EvidenceStatus
      evidence: ConfigurationEvidence[]
    }
    routing: {
      scope: {
        widthBits: number
        values: Array<{ name: string; encoding: number; meaning: string }>
        relationship: string
        status: EvidenceStatus
        evidence: ConfigurationEvidence[]
      }
      destination: {
        widthBits: number
        fields: Array<{ name: string; bits: string; widthBits: number; meaning: string }>
        relationship: string
        status: EvidenceStatus
        evidence: ConfigurationEvidence[]
      }
      kinds: Array<{ name: string; encoding: number; status: EvidenceStatus }>
      mappings: Array<{ name: string; localIndex: string; status: EvidenceStatus; statement: string }>
      controlSystemBoundary: { status: EvidenceStatus; statement: string; evidence: ConfigurationEvidence[] }
    }
    relay: {
      recordWidthBits: number
      bufferDepth: number
      groupsPerHemisphere: number
      slicesPerGroup: number
      banksPerSlice: number
      groupsPerRelay: number
      relayCountPerHemisphere: number
      totalRelayStages: number
      localProgramPortsPerHemisphere: number
      totalLocalProgramPorts: number
      stages: Array<{
        index: number
        groupStart: number
        groupEnd: number
        bankStart: number
        bankEnd: number
        bankCount: number
      }>
      implementationStatus: string
      verificationStatus: string
      integrationStatus: string
      vxmBypass: string
      peripheralForward: string
      clusterAdapter: string
      timing: {
        storageMeaning: string
        readyBoundary: string
        throughput: string
      }
      verification: {
        result: string
        checks: number
        networkChecks: number
        topChecks: number
        physicalEdges: number
        singleStageChecks: number
        fixedDefect: string
      }
      evidence: ConfigurationEvidence[]
    }
    endpointBoundaries: Array<{
      id: 'sxm' | 'vxm'
      name: string
      route: string
      boundary: string
      boundaryStatus: string
      endpointStatus: string
      ready: string
      commit: string
      missingAdapter: string
      frontendStatus: string
      status: EvidenceStatus
      evidence: ConfigurationEvidence[]
    }>
    resetLifecycle: {
      trigger: string
      transportReset: string
      effects: string[]
      status: EvidenceStatus
      evidence: ConfigurationEvidence[]
    }
    destinations: Array<{
      id: string
      name: string
      acceptedStrobe: string
      validPayloadBits: number
      behavior: string
      status: EvidenceStatus
      evidence: ConfigurationEvidence[]
    }>
    commit: {
      signals: string[]
      ordering: string
      sequenceIdPresent: boolean
      status: EvidenceStatus
      evidence: ConfigurationEvidence[]
    }
    excludedPaths: Array<{ name: string; status: EvidenceStatus; statement: string; evidence: ConfigurationEvidence[] }>
    reviewItems: Array<{ name: string; status: EvidenceStatus; statement: string }>
    validation: {
      status: string
      scope: string
      limitation: string
      results: string[]
      evidence: ConfigurationEvidence[]
    }
  }
  qctl: {
    laneCount: number | null
    enabledByDefault: boolean
    status: EvidenceStatus
    groups: Array<{ id: string; name: string; first: number; last: number; count: number; status: EvidenceStatus; statement: string }>
    pipeline: Array<{ id: string; name: string; count: number | null; statement: string; evidence: ConfigurationEvidence[] }>
    relayTopology: {
      globalCapacity: number | null
      regionDepth: number | null
      queueEntryLimit: number | null
      transitDepth: number | null
      storeContract: Array<{ id: string; name: string; statement: string }>
      phases: Array<{ id: string; name: string; path: string; statement: string }>
      chains: Array<{
        id: string
        name: string
        scope: string
        stages: Array<{ id: string; name: string; queues: string; locals: string }>
      }>
    }
    states: Array<{ id: string; name: string; statement: string }>
    barrier: { participantMask: string; arrival: string; notify: string; release: string; roundIsolation: string }
    eventBuffer: { tagBits: number; depth: number | null; statement: string }
    memPacket: { ordinalBits: number; retirement: string; sramCommitRelationship: string }
    endpointBoundary: { connected: string[]; notConnected: string[]; statement: string }
    validation: { status: string; scope: string; limitation: string; results: string[] }
    evidence: ConfigurationEvidence[]
  }
  memIsa: {
    machineCodeBits: number | null
    nativeCommandBits: number | null
    queueEntryBits: number | null
    addressBits: number | null
    status: EvidenceStatus
    notes: Array<{ name: string; status: EvidenceStatus; statement: string }>
    evidence: ConfigurationEvidence[]
  }
  frontends: ConfigurationFrontend[]
  compositions: ConfigurationComposition[]
  memArray: {
    memCount: number | null
    groupsPerMem: number | null
    columnsPerGroup: number | null
    columnsPerMem: number | null
    banksPerColumn: number | null
    banksPerMem: number | null
    tileSlicesPerBank: number | null
    logicalTileSlicesPerMem: number | null
    logicalTileSlicesSystem: number | null
    wordWidthBits: number | null
    depthRows: number | null
    macroWidthBits: number
    macroDepthRows: number
    widthBanks: number | null
    depthBanks: number | null
    mappedMacrosPerSlice: number | null
    mappedMacrosPerMem: number | null
    mappedMacrosSystem: number | null
    activePhysicalMacros: number
    macroSelectEnabled: boolean
    macroDefineEnabled: boolean
    implementationStatus: string
    formula: string
    evidence: ConfigurationEvidence[]
    samplePath: string
    activeImplementation: 'native' | 'legacy' | 'needs-review'
    nativeEnabledByDefault: boolean
    machineCodeBits: number | null
    nativeCommandBits: number | null
    queueEntryBits: number | null
    leafSramsPerBank: number | null
    leafSramsPerMem: number | null
    leafSramsSystem: number | null
    streamRegisterColumns: number | null
    streamRegisterPackageColumns: number | null
    streamRegisterMemBoundaries: number | null
    streamRegisterStatus: EvidenceStatus
    streamRegisterNote: string
    streamRegisterEvidence: ConfigurationEvidence[]
    leafWidthBits: number | null
    leafDepthRows: number | null
    leafImplementation: string
  }
}

export interface Snapshot {
  schemaVersion: number
  generatedAt: string
  project: {
    name: string
    projectRoot: string
    sourceDirectory: string
    filelist: string
    statusNote: string | null
    git: { head: string | null; status: string | null; available: boolean; error?: string }
  }
  configuration: {
    parser: string
    parserVersion: string
    veribleExecutable: string
    filelistFiles: string[]
    includeDirectories: string[]
    defines: string[]
    nestedFilelists: string[]
    sourceFilesNotInPrimaryFilelist: string[]
    generateHandling: string
    conditionalCompilation: string
    globalParameters?: Array<{
      name: string
      default: string | null
      raw: string
      resolvedDefault: number | null
      packageName: string
      sourceFile: string
      line: number
    }>
  }
  summary: {
    sourceFileCount: number
    primaryFilelistRtlFileCount: number
    definitionCount: number
    instanceTemplateCount: number
    unresolvedInstanceCount: number
    generatedTemplateCount: number
    portCount: number
    autoTop: string | null
    selectedTop: string | null
    topCandidateCount: number
    hierarchyNodeCount: number
    hierarchyEdgeCount: number
  }
  topCandidates: Array<{
    name: string
    file: string
    line: number
    reachableDefinitions: number
    inPrimaryFilelist: boolean
  }>
  modules: ModuleDefinition[]
  hierarchy: { top: string; nodes: HierarchyNode[]; edges: HierarchyEdge[]; truncated: boolean }
  warnings: Warning[]
  sourceFiles: Array<{ file: string; sha256: string; inPrimaryFilelist: boolean; parsed: boolean; diagnosticCount: number }>
  architecture: ArchitectureModel
  physicalArchitecture: PhysicalArchitectureModel
  configurationOverview: ConfigurationOverviewModel
}

export interface SearchResult {
  id: string
  kind: 'block' | 'architecture' | 'module' | 'instance' | 'port' | 'signal' | 'interface' | 'file'
  title: string
  subtitle: string
  nodeId?: string
  moduleName?: string
  interfaceId?: string
  rawConnectionId?: string
  physicalBlockId?: string
  physicalInterfaceId?: string
  architectureNodeId?: string
}

export type ViewMode = 'physical' | 'functional' | 'hierarchy' | 'configuration' | 'isa'
