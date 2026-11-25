export type PortSide = 'left' | 'right' | 'top' | 'bottom'

export interface GraphPoint { x: number; y: number }
export interface GraphBox { id: string; x: number; y: number; width: number; height: number }

export interface EdgeLayoutRequest {
  id: string
  sourceId: string
  targetId: string
  semanticName: string
  sourceSide?: PortSide
  targetSide?: PortSide
  direction?: string
  plane?: 'data' | 'control' | 'status'
  lineStyle?: 'solid' | 'dashed'
  routingLane?: number
}

export interface EdgeRoutePlan {
  id: string
  sourceId: string
  targetId: string
  sourceSide: PortSide
  targetSide: PortSide
  sourcePortIndex: number
  sourcePortCount: number
  targetPortIndex: number
  targetPortCount: number
  routingType: 'orthogonal-direct' | 'orthogonal-channel'
  channelIndex: number
  routingLane: number
  plane: 'data' | 'control' | 'status'
  lineStyle: 'solid' | 'dashed'
  points: GraphPoint[]
  waypoints: GraphPoint[]
  path: string
  labelX: number
  labelY: number
  labelWidth: number
  labelHeight: number
  labelAnchorX: number
  labelAnchorY: number
  labelSegmentLength: number
  labelOffset: GraphPoint
}

export interface GraphRoutingOptions {
  obstaclePadding?: number
  channelSpacing?: number
  labelClearance?: number
  labelSpacing?: number
  maxLabelWidth?: number
  laneSearchCount?: number
  canvasPadding?: number
}

interface GraphRect { x: number; y: number; width: number; height: number }

const EPSILON = .5

function center(box: GraphBox): GraphPoint {
  return { x: box.x + box.width / 2, y: box.y + box.height / 2 }
}

function sidePoint(box: GraphBox, side: PortSide, slotIndex = 0, slotCount = 1): GraphPoint {
  const ratio = (slotIndex + 1) / (slotCount + 1)
  if (side === 'left') return { x: box.x, y: box.y + box.height * ratio }
  if (side === 'right') return { x: box.x + box.width, y: box.y + box.height * ratio }
  if (side === 'top') return { x: box.x + box.width * ratio, y: box.y }
  return { x: box.x + box.width * ratio, y: box.y + box.height }
}

function outward(point: GraphPoint, side: PortSide, distance: number): GraphPoint {
  if (side === 'left') return { x: point.x - distance, y: point.y }
  if (side === 'right') return { x: point.x + distance, y: point.y }
  if (side === 'top') return { x: point.x, y: point.y - distance }
  return { x: point.x, y: point.y + distance }
}

function chooseSides(source: GraphBox, target: GraphBox, request: EdgeLayoutRequest): [PortSide, PortSide] {
  if (request.sourceSide && request.targetSide) return [request.sourceSide, request.targetSide]
  const a = center(source)
  const b = center(target)
  const dx = b.x - a.x
  const dy = b.y - a.y
  if (Math.abs(dx) >= Math.abs(dy) * .8) return dx >= 0 ? ['right', 'left'] : ['left', 'right']
  return dy >= 0 ? ['bottom', 'top'] : ['top', 'bottom']
}

function simplify(points: GraphPoint[]): GraphPoint[] {
  const deduped = points.filter((point, index) => index === 0 || Math.abs(point.x - points[index - 1].x) > EPSILON || Math.abs(point.y - points[index - 1].y) > EPSILON)
  return deduped.filter((point, index) => {
    if (index === 0 || index === deduped.length - 1) return true
    const previous = deduped[index - 1]
    const next = deduped[index + 1]
    return !((Math.abs(previous.x - point.x) < EPSILON && Math.abs(point.x - next.x) < EPSILON) || (Math.abs(previous.y - point.y) < EPSILON && Math.abs(point.y - next.y) < EPSILON))
  })
}

export function roundedOrthogonalPath(points: GraphPoint[], radius = 11): string {
  const clean = simplify(points)
  if (!clean.length) return ''
  if (clean.length === 1) return `M ${clean[0].x} ${clean[0].y}`
  let result = `M ${clean[0].x} ${clean[0].y}`
  for (let index = 1; index < clean.length - 1; index += 1) {
    const previous = clean[index - 1]
    const current = clean[index]
    const next = clean[index + 1]
    const incomingLength = Math.abs(current.x - previous.x) + Math.abs(current.y - previous.y)
    const outgoingLength = Math.abs(next.x - current.x) + Math.abs(next.y - current.y)
    const bend = Math.min(radius, incomingLength / 2, outgoingLength / 2)
    const before = {
      x: current.x - Math.sign(current.x - previous.x) * bend,
      y: current.y - Math.sign(current.y - previous.y) * bend,
    }
    const after = {
      x: current.x + Math.sign(next.x - current.x) * bend,
      y: current.y + Math.sign(next.y - current.y) * bend,
    }
    result += ` L ${before.x} ${before.y} Q ${current.x} ${current.y} ${after.x} ${after.y}`
  }
  const last = clean[clean.length - 1]
  return `${result} L ${last.x} ${last.y}`
}

function expanded(box: GraphBox, amount: number): GraphRect {
  return { x: box.x - amount, y: box.y - amount, width: box.width + amount * 2, height: box.height + amount * 2 }
}

export function rectsOverlap(a: GraphRect, b: GraphRect): boolean {
  return a.x < b.x + b.width && a.x + a.width > b.x && a.y < b.y + b.height && a.y + a.height > b.y
}

function segmentIntersectsRect(a: GraphPoint, b: GraphPoint, rect: GraphRect): boolean {
  if (Math.abs(a.x - b.x) < EPSILON) {
    const minY = Math.min(a.y, b.y)
    const maxY = Math.max(a.y, b.y)
    return a.x > rect.x && a.x < rect.x + rect.width && maxY > rect.y && minY < rect.y + rect.height
  }
  if (Math.abs(a.y - b.y) < EPSILON) {
    const minX = Math.min(a.x, b.x)
    const maxX = Math.max(a.x, b.x)
    return a.y > rect.y && a.y < rect.y + rect.height && maxX > rect.x && minX < rect.x + rect.width
  }
  return true
}

function pathObstacleCount(points: GraphPoint[], obstacles: GraphRect[]): number {
  let count = 0
  for (let index = 1; index < points.length; index += 1) for (const obstacle of obstacles) if (segmentIntersectsRect(points[index - 1], points[index], obstacle)) count += 1
  return count
}

function pathLength(points: GraphPoint[]): number {
  let total = 0
  for (let index = 1; index < points.length; index += 1) total += Math.abs(points[index].x - points[index - 1].x) + Math.abs(points[index].y - points[index - 1].y)
  return total
}

function longestSegmentLength(points: GraphPoint[]): number {
  return Math.max(0, ...points.slice(1).map((point, index) => Math.abs(point.x - points[index].x) + Math.abs(point.y - points[index].y)))
}

function bendCount(points: GraphPoint[]): number {
  const clean = simplify(points)
  return Math.max(0, clean.length - 2)
}

function segmentOverlapPenalty(points: GraphPoint[], existing: GraphPoint[][]): number {
  let penalty = 0
  for (let index = 1; index < points.length; index += 1) {
    const a = points[index - 1]
    const b = points[index]
    for (const path of existing) for (let cursor = 1; cursor < path.length; cursor += 1) {
      const c = path[cursor - 1]
      const d = path[cursor]
      const horizontal = Math.abs(a.y - b.y) < EPSILON && Math.abs(c.y - d.y) < EPSILON
      const vertical = Math.abs(a.x - b.x) < EPSILON && Math.abs(c.x - d.x) < EPSILON
      if (horizontal && Math.abs(a.y - c.y) < 8 && Math.max(Math.min(a.x, b.x), Math.min(c.x, d.x)) < Math.min(Math.max(a.x, b.x), Math.max(c.x, d.x))) penalty += 1
      if (vertical && Math.abs(a.x - c.x) < 8 && Math.max(Math.min(a.y, b.y), Math.min(c.y, d.y)) < Math.min(Math.max(a.y, b.y), Math.max(c.y, d.y))) penalty += 1
    }
  }
  return penalty
}

function collinearOverlapLength(a: GraphPoint, b: GraphPoint, c: GraphPoint, d: GraphPoint, tolerance = 8): number {
  const firstHorizontal = Math.abs(a.y - b.y) < EPSILON
  const secondHorizontal = Math.abs(c.y - d.y) < EPSILON
  if (firstHorizontal !== secondHorizontal) return 0
  if (firstHorizontal) {
    if (Math.abs(a.y - c.y) >= tolerance) return 0
    return Math.max(0, Math.min(Math.max(a.x, b.x), Math.max(c.x, d.x)) - Math.max(Math.min(a.x, b.x), Math.min(c.x, d.x)))
  }
  if (Math.abs(a.x - c.x) >= tolerance) return 0
  return Math.max(0, Math.min(Math.max(a.y, b.y), Math.max(c.y, d.y)) - Math.max(Math.min(a.y, b.y), Math.min(c.y, d.y)))
}

function pathOverlapLength(points: GraphPoint[], existing: GraphPoint[][], tolerance = 8): number {
  let total = 0
  for (let index = 1; index < points.length; index += 1) for (const path of existing) for (let cursor = 1; cursor < path.length; cursor += 1) {
    total += collinearOverlapLength(points[index - 1], points[index], path[cursor - 1], path[cursor], tolerance)
  }
  return total
}

function pointEquals(a: GraphPoint, b: GraphPoint): boolean {
  return Math.abs(a.x - b.x) < EPSILON && Math.abs(a.y - b.y) < EPSILON
}

function segmentCrossesSegment(a: GraphPoint, b: GraphPoint, c: GraphPoint, d: GraphPoint): boolean {
  const firstHorizontal = Math.abs(a.y - b.y) < EPSILON
  const secondHorizontal = Math.abs(c.y - d.y) < EPSILON
  if (firstHorizontal === secondHorizontal) return false
  const horizontalA = firstHorizontal ? a : c
  const horizontalB = firstHorizontal ? b : d
  const verticalA = firstHorizontal ? c : a
  const verticalB = firstHorizontal ? d : b
  const intersection = { x: verticalA.x, y: horizontalA.y }
  const onHorizontal = intersection.x > Math.min(horizontalA.x, horizontalB.x) + EPSILON && intersection.x < Math.max(horizontalA.x, horizontalB.x) - EPSILON
  const onVertical = intersection.y > Math.min(verticalA.y, verticalB.y) + EPSILON && intersection.y < Math.max(verticalA.y, verticalB.y) - EPSILON
  if (!onHorizontal || !onVertical) return false
  return ![a, b, c, d].some((point) => pointEquals(point, intersection))
}

function pathCrossingPenalty(points: GraphPoint[], existing: GraphPoint[][]): number {
  let penalty = 0
  for (let index = 1; index < points.length; index += 1) for (const path of existing) for (let cursor = 1; cursor < path.length; cursor += 1) {
    if (segmentCrossesSegment(points[index - 1], points[index], path[cursor - 1], path[cursor])) penalty += 1
  }
  return penalty
}

function pathIntersectsRect(points: GraphPoint[], rect: GraphRect): boolean {
  for (let index = 1; index < points.length; index += 1) if (segmentIntersectsRect(points[index - 1], points[index], rect)) return true
  return false
}

function routeCandidates(source: GraphBox, target: GraphBox, sourceSide: PortSide, targetSide: PortSide, start: GraphPoint, end: GraphPoint, channelIndex: number, boxes: GraphBox[], padding: number, spacing: number, laneSearchCount: number): GraphPoint[][] {
  const startStub = outward(start, sourceSide, padding)
  const endStub = outward(end, targetSide, padding)
  const bounds = boxes.reduce((value, box) => ({
    left: Math.min(value.left, box.x),
    right: Math.max(value.right, box.x + box.width),
    top: Math.min(value.top, box.y),
    bottom: Math.max(value.bottom, box.y + box.height),
  }), { left: source.x, right: source.x + source.width, top: source.y, bottom: source.y + source.height })
  const offset = (channelIndex - 1.5) * spacing
  const horizontalPorts = (sourceSide === 'left' || sourceSide === 'right') && (targetSide === 'left' || targetSide === 'right')
  if (horizontalPorts) {
    const midpoint = (startStub.x + endStub.x) / 2 + offset
    const candidates: GraphPoint[][] = [[start, startStub, { x: midpoint, y: startStub.y }, { x: midpoint, y: endStub.y }, endStub, end]]
    for (let laneOffset = 0; laneOffset < laneSearchCount; laneOffset += 1) {
      const lane = channelIndex + laneOffset
      const top = bounds.top - padding * 2 - lane * spacing
      const bottom = bounds.bottom + padding * 2 + lane * spacing
      candidates.push([start, startStub, { x: startStub.x, y: top }, { x: endStub.x, y: top }, endStub, end])
      candidates.push([start, startStub, { x: startStub.x, y: bottom }, { x: endStub.x, y: bottom }, endStub, end])
    }
    return candidates.map(simplify)
  }
  const midpoint = (startStub.y + endStub.y) / 2 + offset
  const candidates: GraphPoint[][] = [[start, startStub, { x: startStub.x, y: midpoint }, { x: endStub.x, y: midpoint }, endStub, end]]
  for (let laneOffset = 0; laneOffset < laneSearchCount; laneOffset += 1) {
    const lane = channelIndex + laneOffset
    const left = bounds.left - padding * 2 - lane * spacing
    const right = bounds.right + padding * 2 + lane * spacing
    candidates.push([start, startStub, { x: left, y: startStub.y }, { x: left, y: endStub.y }, endStub, end])
    candidates.push([start, startStub, { x: right, y: startStub.y }, { x: right, y: endStub.y }, endStub, end])
  }
  return candidates.map(simplify)
}

function estimatedLabelRect(name: string, maxWidth: number): { width: number; height: number } {
  const units = [...name].reduce((total, character) => total + (/[^\u0000-\u00ff]/.test(character) ? 1.8 : 1), 0)
  const naturalWidth = units * 7.1 + 52
  const width = Math.min(maxWidth, Math.max(118, naturalWidth))
  return { width, height: naturalWidth > maxWidth || units > 27 ? 52 : 38 }
}

function placeLabel(points: GraphPoint[], name: string, obstacles: GraphRect[], occupied: GraphRect[], occupiedPaths: GraphPoint[][], bounds: GraphRect, clearance: number, labelSpacing: number, maxWidth: number) {
  const size = estimatedLabelRect(name, maxWidth)
  const segments = points.slice(1).map((point, index) => ({ a: points[index], b: point, length: Math.abs(point.x - points[index].x) + Math.abs(point.y - points[index].y), index })).sort((a, b) => b.length - a.length)
  const isClear = (rect: GraphRect) => {
    const padded = expanded({ id: 'label', ...rect }, labelSpacing)
    if (rect.x < bounds.x || rect.y < bounds.y || rect.x + rect.width > bounds.x + bounds.width || rect.y + rect.height > bounds.y + bounds.height) return false
    if (obstacles.some((obstacle) => rectsOverlap(padded, obstacle))) return false
    if (occupied.some((other) => rectsOverlap(padded, other))) return false
    if (occupiedPaths.some((path) => pathIntersectsRect(path, padded))) return false
    return true
  }
  // Prefer an opaque interface block directly on a long straight carrier.
  // The line remains continuous in SVG but is visually split by the block,
  // matching an engineering diagram's module-interface-module notation.
  for (const segment of segments) {
    const horizontal = Math.abs(segment.a.y - segment.b.y) < EPSILON
    const required = (horizontal ? size.width : size.height) + clearance * 2
    if (segment.length < required) continue
    const x = (segment.a.x + segment.b.x) / 2
    const y = (segment.a.y + segment.b.y) / 2
    const rect = { x: x - size.width / 2, y: y - size.height / 2, width: size.width, height: size.height }
    if (!isClear(rect)) continue
    occupied.push(rect)
    return { x, y, ...size, anchorX: x, anchorY: y, offset: { x: 0, y: 0 } }
  }
  const fractions = [.5, .34, .66, .2, .8]
  const radialSteps = Array.from({ length: 18 }, (_, index) => [-(index + 1), index + 1]).flat()
  for (const segment of segments) for (const fraction of fractions) for (const sign of radialSteps) {
    const horizontal = Math.abs(segment.a.y - segment.b.y) < EPSILON
    const baseX = segment.a.x + (segment.b.x - segment.a.x) * fraction
    const baseY = segment.a.y + (segment.b.y - segment.a.y) * fraction
    const offsetDistance = (horizontal ? size.height / 2 : size.width / 2) + clearance * Math.abs(sign)
    const x = horizontal ? baseX : baseX + Math.sign(sign) * offsetDistance
    const y = horizontal ? baseY + Math.sign(sign) * offsetDistance : baseY
    const rect = { x: x - size.width / 2, y: y - size.height / 2, width: size.width, height: size.height }
    if (!isClear(rect)) continue
    occupied.push(rect)
    return { x, y, ...size, anchorX: baseX, anchorY: baseY, offset: { x: x - baseX, y: y - baseY } }
  }
  // Dense branch/merge views can reserve the entire carrier corridor with
  // perpendicular return paths.  Search a small two-dimensional mounting
  // grid before accepting an unsafe fallback position.
  const anchor = segments[0]
  const anchorX = (anchor.a.x + anchor.b.x) / 2
  const anchorY = (anchor.a.y + anchor.b.y) / 2
  for (let ring = 1; ring <= 6; ring += 1) {
    const stepX = (size.width / 2 + clearance * 2) * ring
    const stepY = (size.height / 2 + clearance * 2) * ring
    for (const [dx, dy] of [[-stepX, 0], [stepX, 0], [0, -stepY], [0, stepY], [-stepX, -stepY], [stepX, -stepY], [-stepX, stepY], [stepX, stepY]]) {
      const x = anchorX + dx
      const y = anchorY + dy
      const rect = { x: x - size.width / 2, y: y - size.height / 2, width: size.width, height: size.height }
      if (!isClear(rect)) continue
      occupied.push(rect)
      return { x, y, ...size, anchorX, anchorY, offset: { x: dx, y: dy } }
    }
  }
  const longest = segments[0]
  const x = (longest.a.x + longest.b.x) / 2
  const y = (longest.a.y + longest.b.y) / 2 - size.height / 2 - clearance
  const rect = { x: x - size.width / 2, y: y - size.height / 2, width: size.width, height: size.height }
  occupied.push(rect)
  return { x, y, ...size, anchorX: x, anchorY: (longest.a.y + longest.b.y) / 2, offset: { x: 0, y: -size.height / 2 - clearance } }
}

export function layoutOrthogonalEdges(boxes: GraphBox[], requests: EdgeLayoutRequest[], options: GraphRoutingOptions = {}): Map<string, EdgeRoutePlan> {
  const obstaclePadding = options.obstaclePadding ?? 22
  const channelSpacing = options.channelSpacing ?? 20
  const labelClearance = options.labelClearance ?? 13
  const labelSpacing = options.labelSpacing ?? 12
  const maxLabelWidth = options.maxLabelWidth ?? 230
  const laneSearchCount = options.laneSearchCount ?? 4
  const canvasPadding = options.canvasPadding ?? 240
  const boxMap = new Map(boxes.map((box) => [box.id, box]))
  const requestSides = new Map<string, { sourceSide: PortSide; targetSide: PortSide }>()
  const endpointGroups = new Map<string, string[]>()
  for (const request of requests) {
    const source = boxMap.get(request.sourceId)
    const target = boxMap.get(request.targetId)
    if (!source || !target) continue
    const [sourceSide, targetSide] = chooseSides(source, target, request)
    requestSides.set(request.id, { sourceSide, targetSide })
    // Source and target ownership share a node-side slot pool. This prevents
    // opposite-direction arrows from landing on the same pixel.
    for (const key of [`${request.sourceId}:${sourceSide}`, `${request.targetId}:${targetSide}`]) endpointGroups.set(key, [...(endpointGroups.get(key) ?? []), request.id])
  }
  const occupiedPaths: GraphPoint[][] = []
  const occupiedLabels: GraphRect[] = []
  const result = new Map<string, EdgeRoutePlan>()
  const outgoingIndex = new Map<string, number>()
  const canvas = boxes.reduce((value, box) => ({
    x: Math.min(value.x, box.x - canvasPadding),
    y: Math.min(value.y, box.y - canvasPadding),
    right: Math.max(value.right, box.x + box.width + canvasPadding),
    bottom: Math.max(value.bottom, box.y + box.height + canvasPadding),
  }), { x: 0, y: 0, right: 0, bottom: 0 })
  const canvasRect = { x: canvas.x, y: canvas.y, width: canvas.right - canvas.x, height: canvas.bottom - canvas.y }

  for (const request of requests) {
    const source = boxMap.get(request.sourceId)
    const target = boxMap.get(request.targetId)
    if (!source || !target) continue
    const sourceChannelIndex = outgoingIndex.get(request.sourceId) ?? 0
    outgoingIndex.set(request.sourceId, sourceChannelIndex + 1)
    const routingLane = request.routingLane ?? sourceChannelIndex
    const lineStyle = request.lineStyle ?? (request.plane === 'status' ? 'dashed' : 'solid')
    const channelIndex = routingLane + (lineStyle === 'dashed' ? 1 : 0)
    const { sourceSide, targetSide } = requestSides.get(request.id) ?? { sourceSide: 'right' as PortSide, targetSide: 'left' as PortSide }
    const sourceGroup = endpointGroups.get(`${request.sourceId}:${sourceSide}`) ?? [request.id]
    const targetGroup = endpointGroups.get(`${request.targetId}:${targetSide}`) ?? [request.id]
    const sourcePortIndex = sourceGroup.indexOf(request.id)
    const targetPortIndex = targetGroup.indexOf(request.id)
    const start = sidePoint(source, sourceSide, sourcePortIndex, sourceGroup.length)
    const end = sidePoint(target, targetSide, targetPortIndex, targetGroup.length)
    const obstacles = boxes.filter((box) => box.id !== source.id && box.id !== target.id).map((box) => expanded(box, obstaclePadding))
    const candidates = routeCandidates(source, target, sourceSide, targetSide, start, end, channelIndex, boxes, obstaclePadding, channelSpacing, laneSearchCount)
    const labelSize = estimatedLabelRect(request.semanticName, maxLabelWidth)
    const preferredLabelSegment = Math.min(280, Math.max(150, labelSize.width * .82))
    const scored = candidates.map((points, index) => {
      const bends = bendCount(points)
      const obstacleHits = pathObstacleCount(points, obstacles)
      const labelCarrierPenalty = Math.max(0, preferredLabelSegment - longestSegmentLength(points))
      return {
        points,
        index,
        score: obstacleHits * 100000 + segmentOverlapPenalty(points, occupiedPaths) * 10000 + pathOverlapLength(points, occupiedPaths) * 220 + pathCrossingPenalty(points, occupiedPaths) * 9000 + bends * 5200 + labelCarrierPenalty * (bends === 0 ? 12 : 110) + pathLength(points),
      }
    }).sort((a, b) => a.score - b.score)
    const best = scored[0]
    occupiedPaths.push(best.points)
    result.set(request.id, {
      id: request.id,
      sourceId: request.sourceId,
      targetId: request.targetId,
      sourceSide,
      targetSide,
      sourcePortIndex,
      sourcePortCount: sourceGroup.length,
      targetPortIndex,
      targetPortCount: targetGroup.length,
      routingType: best.index === 0 ? 'orthogonal-direct' : 'orthogonal-channel',
      channelIndex,
      routingLane,
      plane: request.plane ?? 'control',
      lineStyle,
      points: best.points,
      waypoints: best.points.slice(1, -1),
      path: roundedOrthogonalPath(best.points, 2),
      labelX: 0,
      labelY: 0,
      labelWidth: 0,
      labelHeight: 0,
      labelAnchorX: 0,
      labelAnchorY: 0,
      labelSegmentLength: longestSegmentLength(best.points),
      labelOffset: { x: 0, y: 0 },
    })
  }
  // Route every edge first, then place interface blocks against the complete
  // wire set.  This prevents a later branch or return path from cutting
  // through an interface block that was already placed by an earlier edge.
  for (const request of requests) {
    const plan = result.get(request.id)
    if (!plan) continue
    const otherPaths = [...result.values()].filter((other) => other.id !== plan.id).map((other) => other.points)
    const label = placeLabel(plan.points, request.semanticName, boxes.map((box) => expanded(box, 10)), occupiedLabels, otherPaths, canvasRect, labelClearance, labelSpacing, maxLabelWidth)
    plan.labelX = label.x
    plan.labelY = label.y
    plan.labelWidth = label.width
    plan.labelHeight = label.height
    plan.labelAnchorX = label.anchorX
    plan.labelAnchorY = label.anchorY
    plan.labelOffset = label.offset
  }
  return result
}

export function auditGraphRoutes(boxes: GraphBox[], plans: Iterable<EdgeRoutePlan>, canvasBounds?: GraphRect) {
  const planList = [...plans]
  const nodeRects = boxes.map((box) => expanded(box, 2))
  const labelRects: GraphRect[] = []
  let nodeCrossings = 0
  let labelNodeOverlaps = 0
  let labelCollisions = 0
  let edgeCrossings = 0
  let labelEdgeOverlaps = 0
  let nodeOverlaps = 0
  let edgeOverlaps = 0
  let solidDashedEdgeOverlaps = 0
  let arrowNodeOverlaps = 0
  let arrowArrowOverlaps = 0
  let labelCanvasOverflows = 0
  let nodeCanvasOverflows = 0
  for (let index = 0; index < nodeRects.length; index += 1) for (let otherIndex = index + 1; otherIndex < nodeRects.length; otherIndex += 1) {
    if (rectsOverlap(nodeRects[index], nodeRects[otherIndex])) nodeOverlaps += 1
  }
  const derivedCanvas = boxes.reduce((value, box) => ({
    x: Math.min(value.x, box.x - 240), y: Math.min(value.y, box.y - 240),
    right: Math.max(value.right, box.x + box.width + 240), bottom: Math.max(value.bottom, box.y + box.height + 240),
  }), { x: 0, y: 0, right: 0, bottom: 0 })
  const canvas = canvasBounds ?? { x: derivedCanvas.x, y: derivedCanvas.y, width: derivedCanvas.right - derivedCanvas.x, height: derivedCanvas.bottom - derivedCanvas.y }
  const outsideCanvas = (rect: GraphRect) => rect.x < canvas.x || rect.y < canvas.y || rect.x + rect.width > canvas.x + canvas.width || rect.y + rect.height > canvas.y + canvas.height
  nodeCanvasOverflows = nodeRects.filter(outsideCanvas).length
  for (const [planIndex, plan] of planList.entries()) {
    const source = boxes.find((box) => box.id === plan.sourceId)
    const target = boxes.find((box) => box.id === plan.targetId)
    const obstacles = nodeRects.filter((_, index) => boxes[index].id !== source?.id && boxes[index].id !== target?.id)
    nodeCrossings += pathObstacleCount(plan.points, obstacles)
    const label = { x: plan.labelX - plan.labelWidth / 2, y: plan.labelY - plan.labelHeight / 2, width: plan.labelWidth, height: plan.labelHeight }
    if (nodeRects.some((node) => rectsOverlap(label, node))) labelNodeOverlaps += 1
    if (labelRects.some((other) => rectsOverlap(label, other))) labelCollisions += 1
    if (outsideCanvas(label)) labelCanvasOverflows += 1
    for (const [otherIndex, other] of planList.entries()) {
      if (otherIndex === planIndex) continue
      if (pathIntersectsRect(other.points, label)) labelEdgeOverlaps += 1
    }
    edgeCrossings += pathCrossingPenalty(plan.points, planList.slice(0, planIndex).map((other) => other.points))
    for (let otherIndex = 0; otherIndex < planIndex; otherIndex += 1) {
      const other = planList[otherIndex]
      const overlap = pathOverlapLength(plan.points, [other.points], EPSILON)
      if (overlap > EPSILON) {
        edgeOverlaps += 1
        if (plan.lineStyle !== other.lineStyle) solidDashedEdgeOverlaps += 1
      }
      const arrow = plan.points.at(-1)!
      const otherArrow = other.points.at(-1)!
      if (Math.hypot(arrow.x - otherArrow.x, arrow.y - otherArrow.y) < 10) arrowArrowOverlaps += 1
    }
    const arrow = plan.points.at(-1)!
    for (const box of boxes) {
      if (box.id === plan.sourceId || box.id === plan.targetId) continue
      if (arrow.x >= box.x && arrow.x <= box.x + box.width && arrow.y >= box.y && arrow.y <= box.y + box.height) arrowNodeOverlaps += 1
    }
    labelRects.push(label)
  }
  return {
    nodeOverlaps,
    nodeCrossings,
    nodeEdgeOverlaps: nodeCrossings,
    edgeOverlaps,
    solidDashedEdgeOverlaps,
    edgeCrossings,
    labelNodeOverlaps,
    labelCollisions,
    labelLabelOverlaps: labelCollisions,
    labelEdgeOverlaps,
    arrowNodeOverlaps,
    arrowArrowOverlaps,
    labelCanvasOverflows,
    nodeCanvasOverflows,
  }
}
