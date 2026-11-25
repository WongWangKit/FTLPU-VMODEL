import test from 'node:test'
import assert from 'node:assert/strict'
import { auditGraphRoutes, layoutOrthogonalEdges } from '../src/lib/graph-layout-engine.ts'

test('routes Distributor branches without crossing nodes or labels', () => {
  const boxes = [
    { id: 'input', x: 0, y: 250, width: 285, height: 124 },
    { id: 'decode', x: 480, y: 250, width: 285, height: 124 },
    { id: 'west', x: 1020, y: 0, width: 285, height: 124 },
    { id: 'east', x: 1020, y: 250, width: 285, height: 124 },
    { id: 'retire', x: 1020, y: 500, width: 285, height: 124 },
  ]
  const plans = layoutOrthogonalEdges(boxes, [
    { id: 'in', sourceId: 'input', targetId: 'decode', semanticName: 'Reassembled Instruction Words' },
    { id: 'west-edge', sourceId: 'decode', targetId: 'west', semanticName: 'West Hemisphere Dispatch' },
    { id: 'east-edge', sourceId: 'decode', targetId: 'east', semanticName: 'East Hemisphere Dispatch' },
    { id: 'retire-edge', sourceId: 'decode', targetId: 'retire', semanticName: 'Retire and Fault Status' },
  ])
  assert.equal(plans.size, 4)
  const audit = auditGraphRoutes(boxes, plans.values())
  for (const metric of ['nodeOverlaps', 'nodeEdgeOverlaps', 'edgeOverlaps', 'solidDashedEdgeOverlaps', 'edgeCrossings', 'labelNodeOverlaps', 'labelLabelOverlaps', 'labelEdgeOverlaps', 'arrowNodeOverlaps', 'arrowArrowOverlaps', 'labelCanvasOverflows', 'nodeCanvasOverflows']) assert.equal(audit[metric], 0, metric)
  assert.equal(new Set([...plans.values()].map((plan) => `${plan.labelX}:${plan.labelY}`)).size, 4)
})

test('uses an outer channel when the direct route is blocked', () => {
  const boxes = [
    { id: 'a', x: 0, y: 120, width: 240, height: 110 },
    { id: 'obstacle', x: 380, y: 80, width: 260, height: 190 },
    { id: 'c', x: 780, y: 120, width: 240, height: 110 },
  ]
  const plans = layoutOrthogonalEdges(boxes, [{ id: 'edge', sourceId: 'a', targetId: 'c', semanticName: 'Command and Payload' }])
  const plan = plans.get('edge')
  assert.ok(plan)
  assert.equal(plan.routingType, 'orthogonal-channel')
  assert.equal(auditGraphRoutes(boxes, plans.values()).nodeCrossings, 0)
})

test('separates parallel semantic labels and preserves source/target ownership', () => {
  const boxes = [
    { id: 'source', x: 0, y: 0, width: 260, height: 120 },
    { id: 'target', x: 700, y: 0, width: 260, height: 120 },
  ]
  const plans = layoutOrthogonalEdges(boxes, [
    { id: 'data', sourceId: 'source', targetId: 'target', semanticName: 'Data Payload' },
    { id: 'valid', sourceId: 'source', targetId: 'target', semanticName: 'Valid' },
    { id: 'ready', sourceId: 'target', targetId: 'source', semanticName: 'Ready Return' },
  ])
  assert.equal(plans.get('data')?.sourceId, 'source')
  assert.equal(plans.get('ready')?.targetId, 'source')
  assert.equal(plans.get('data')?.targetPortCount, 3)
  assert.notDeepEqual(plans.get('data')?.points.at(-1), plans.get('valid')?.points.at(-1))
  assert.ok(plans.get('data')?.labelSegmentLength >= 150)
  assert.equal(auditGraphRoutes(boxes, plans.values()).labelCollisions, 0)
})

test('keeps an unobstructed adjacent interface straight and places its interface block inline', () => {
  const boxes = [
    { id: 'sx', x: 0, y: 0, width: 240, height: 120 },
    { id: 'mem', x: 700, y: 0, width: 240, height: 120 },
  ]
  const plans = layoutOrthogonalEdges(boxes, [
    { id: 'sx-mem', sourceId: 'sx', targetId: 'mem', semanticName: 'SXM-MEM Interface' },
  ])
  const plan = plans.get('sx-mem')
  assert.ok(plan)
  assert.equal(plan.routingType, 'orthogonal-direct')
  assert.equal(plan.points.length, 2)
  assert.deepEqual(plan.labelOffset, { x: 0, y: 0 })
  assert.equal(auditGraphRoutes(boxes, plans.values()).nodeCrossings, 0)
})

test('keeps a long Program Word to FU-local router one-hop connection straight', () => {
  const boxes = [
    { id: 'schedule', x: 0, y: 0, width: 315, height: 136 },
    { id: 'icu-router', x: 0, y: 320, width: 315, height: 136 },
  ]
  const plans = layoutOrthogonalEdges(boxes, [
    { id: 'enqueue', sourceId: 'schedule', targetId: 'icu-router', semanticName: 'Program Word → FU-local Router' },
  ], { obstaclePadding: 28, labelClearance: 18, labelSpacing: 14 })
  const plan = plans.get('enqueue')
  assert.ok(plan)
  assert.equal(plan.routingType, 'orthogonal-direct')
  assert.equal(plan.points.length, 2)
  assert.equal(plan.points[0].x, plan.points[1].x)
  assert.equal(auditGraphRoutes(boxes, plans.values()).edgeCrossings, 0)
})

test('separates solid control flow from dashed status return lanes and arrow endpoints', () => {
  const boxes = [
    { id: 'router', x: 0, y: 0, width: 300, height: 132 },
    { id: 'consumer', x: 0, y: 420, width: 300, height: 132 },
  ]
  const plans = layoutOrthogonalEdges(boxes, [
    { id: 'load', sourceId: 'router', targetId: 'consumer', semanticName: 'Local iMEM Load', sourceSide: 'bottom', targetSide: 'top', plane: 'control', lineStyle: 'solid', routingLane: 0 },
    { id: 'status', sourceId: 'consumer', targetId: 'router', semanticName: 'Status Return', sourceSide: 'top', targetSide: 'bottom', plane: 'status', lineStyle: 'dashed', routingLane: 2 },
  ], { channelSpacing: 30, laneSearchCount: 5 })
  const audit = auditGraphRoutes(boxes, plans.values())
  assert.equal(audit.edgeOverlaps, 0)
  assert.equal(audit.solidDashedEdgeOverlaps, 0)
  assert.equal(audit.arrowArrowOverlaps, 0)
  assert.notDeepEqual(plans.get('load')?.points, plans.get('status')?.points)
})

test('treats Program Load modules as obstacles but permits crossing system containers', () => {
  // The two large load_system / distribute_system frames are deliberately not
  // represented as boxes. Only concrete functional rectangles are obstacles.
  const boxes = [
    { id: 'elastic', x: 2260, y: 565, width: 500, height: 90 },
    { id: 'decode', x: 1510, y: 825, width: 500, height: 105 },
    { id: 'west', x: 260, y: 1000, width: 340, height: 105 },
    { id: 'east', x: 2920, y: 1000, width: 340, height: 105 },
    { id: 'relay', x: 830, y: 965, width: 1860, height: 205 },
    { id: 'lifecycle', x: 2890, y: 360, width: 520, height: 130 },
  ]
  const plans = layoutOrthogonalEdges(boxes, [
    { id: 'elastic-decode', sourceId: 'elastic', targetId: 'decode', semanticName: 'Buffered Program Load Record', sourceSide: 'bottom', targetSide: 'top', routingLane: 0 },
    { id: 'west-record', sourceId: 'decode', targetId: 'west', semanticName: 'West Record', sourceSide: 'left', targetSide: 'top', routingLane: 1 },
    { id: 'east-record', sourceId: 'decode', targetId: 'east', semanticName: 'East Record', sourceSide: 'right', targetSide: 'top', routingLane: 2 },
    { id: 'west-relay', sourceId: 'west', targetId: 'relay', semanticName: 'West Relay Chain', sourceSide: 'right', targetSide: 'left', routingLane: 0 },
    { id: 'east-relay', sourceId: 'east', targetId: 'relay', semanticName: 'East Relay Chain', sourceSide: 'left', targetSide: 'right', routingLane: 0 },
    { id: 'fault', sourceId: 'relay', targetId: 'lifecycle', semanticName: 'Fault', sourceSide: 'right', targetSide: 'right', plane: 'status', lineStyle: 'dashed', routingLane: 11 },
    { id: 'reset', sourceId: 'lifecycle', targetId: 'relay', semanticName: 'Program Reset', sourceSide: 'right', targetSide: 'right', plane: 'control', lineStyle: 'solid', routingLane: 13 },
  ], { obstaclePadding: 40, channelSpacing: 44, labelClearance: 26, labelSpacing: 20, maxLabelWidth: 200, laneSearchCount: 17, canvasPadding: 420 })
  const audit = auditGraphRoutes(boxes, plans.values())
  assert.equal(plans.size, 7)
  assert.equal(audit.nodeCrossings, 0)
  assert.equal(audit.nodeEdgeOverlaps, 0)
  assert.equal(audit.arrowNodeOverlaps, 0)
  assert.equal(audit.solidDashedEdgeOverlaps, 0)
})
