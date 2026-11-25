import { spawn } from 'node:child_process'
import { promises as fs } from 'node:fs'
import path from 'node:path'

const appUrl = process.argv[2] ?? 'http://127.0.0.1:4173/'
const artifactDir = path.resolve(process.argv[3] ?? 'artifacts')
const width = Number(process.argv[4] ?? 1920)
const height = Number(process.argv[5] ?? 1080)
const debugPort = Number(process.argv[6] ?? 9340)
const edge = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'
await fs.mkdir(artifactDir, { recursive: true })
const userData = path.join(artifactDir, `.stage15-edge-profile-${width}x${height}-${process.pid}`)
await fs.mkdir(userData, { recursive: true })

const browser = spawn(edge, [
  '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
  `--remote-debugging-port=${debugPort}`, `--user-data-dir=${userData}`,
  `--window-size=${width},${height}`, appUrl,
], { stdio: 'ignore' })

let socket
let sequence = 0
const pending = new Map()

async function retry(fn, timeout = 15000) {
  const start = Date.now()
  let error
  while (Date.now() - start < timeout) {
    try { return await fn() } catch (next) { error = next; await new Promise((resolve) => setTimeout(resolve, 120)) }
  }
  throw error
}

function command(method, params = {}) {
  const id = ++sequence
  socket.send(JSON.stringify({ id, method, params }))
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }))
}

async function evaluate(expression) {
  const response = await command('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })
  if (response.exceptionDetails) throw new Error(response.exceptionDetails.text)
  return response.result?.result?.value
}

async function waitFor(expression, timeout = 10000) {
  return retry(async () => {
    const value = await evaluate(expression)
    if (!value) throw new Error(`Waiting for: ${expression}`)
    return value
  }, timeout)
}

async function click(selector) {
  const point = await evaluate(`(() => { const element = document.querySelector(${JSON.stringify(selector)}); if (!element) return null; const rect = element.getBoundingClientRect(); return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 } })()`)
  if (!point) throw new Error(`Missing click target: ${selector}`)
  await command('Input.dispatchMouseEvent', { type: 'mousePressed', x: point.x, y: point.y, button: 'left', clickCount: 1 })
  await command('Input.dispatchMouseEvent', { type: 'mouseReleased', x: point.x, y: point.y, button: 'left', clickCount: 1 })
  if (selector.includes('react-flow__node')) await evaluate(`(() => { const element=document.querySelector(${JSON.stringify(selector)}); if (element) element.click(); return true })()`)
  return point
}

async function hover(selector) {
  const point = await evaluate(`(() => { const element = document.querySelector(${JSON.stringify(selector)}); if (!element) return null; const rect = element.getBoundingClientRect(); return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 } })()`)
  if (!point) throw new Error(`Missing hover target: ${selector}`)
  await command('Input.dispatchMouseEvent', { type: 'mouseMoved', x: point.x, y: point.y })
}

async function screenshot(name) {
  const response = await command('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false })
  await fs.writeFile(path.join(artifactDir, name), Buffer.from(response.result.data, 'base64'))
}

const geometryExpression = `(() => {
  const graph = document.querySelector('.engineering-graph')
  if (!graph) return null
  const graphRect = graph.getBoundingClientRect()
  const visible = (element) => { const r = element.getBoundingClientRect(); const s = getComputedStyle(element); return r.width > 1 && r.height > 1 && s.visibility !== 'hidden' && s.display !== 'none' }
  const rect = (element) => { const r = element.getBoundingClientRect(); return { left:r.left, top:r.top, right:r.right, bottom:r.bottom, width:r.width, height:r.height } }
  const overlap = (a,b,pad=0) => a.left < b.right-pad && a.right > b.left+pad && a.top < b.bottom-pad && a.bottom > b.top+pad
  const nodes = [...graph.querySelectorAll('.physical-block,.connectivity-node,.architecture-module')].filter(visible)
  const labels = [...graph.querySelectorAll('.physical-bus-label,.connectivity-edge-label,.semantic-edge-label')].filter(visible)
  const paths = [...graph.querySelectorAll('path.directed-edge,path.physical-bus,path.connectivity-edge,path.semantic-edge')].filter((item) => getComputedStyle(item).display !== 'none' && item.getTotalLength() > 1)
  const nodeRects = nodes.map(rect), labelRects = labels.map(rect)
  const nodeNode = nodeRects.flatMap((a,i) => nodeRects.slice(i+1).map((b) => overlap(a,b,2))).filter(Boolean).length
  const labelLabel = labelRects.flatMap((a,i) => labelRects.slice(i+1).map((b) => overlap(a,b,2))).filter(Boolean).length
  const labelNode = labelRects.flatMap((a) => nodeRects.map((b) => overlap(a,b,2))).filter(Boolean).length
  const samples = paths.map((edge) => {
    const length = edge.getTotalLength(); const matrix = edge.getScreenCTM(); const points = []
    for (let index=0; index<=48; index+=1) { const p=edge.getPointAtLength(length*index/48); const q=new DOMPoint(p.x,p.y).matrixTransform(matrix); points.push({x:q.x,y:q.y}) }
    return { edge, points, id:edge.closest('.react-flow__edge')?.getAttribute('data-id') ?? '', dashed:getComputedStyle(edge).strokeDasharray !== 'none' }
  })
  const pointInside = (point, box, inset=3) => point.x > box.left+inset && point.x < box.right-inset && point.y > box.top+inset && point.y < box.bottom-inset
  let nodeEdge=0, labelEdge=0, edgeOverlap=0, solidDashedOverlap=0, edgeCrossings=0, arrowNode=0, arrowArrow=0
  const nodeEdgeIds=[]
  for (const sample of samples) {
    if (sample.points.slice(2,-2).some((point) => nodeRects.some((box) => pointInside(point,box,5)))) { nodeEdge += 1; nodeEdgeIds.push(sample.id) }
    const end = sample.points.at(-1)
    if (nodeRects.some((box) => pointInside(end,box,6))) arrowNode += 1
  }
  labels.forEach((label,index) => {
    const edgeId = label.dataset.edgeId
    for (const sample of samples) if (!edgeId || sample.id !== edgeId) if (sample.points.some((point) => pointInside(point,labelRects[index],1))) { labelEdge += 1; break }
  })
  for (let i=0;i<samples.length;i+=1) for (let j=i+1;j<samples.length;j+=1) {
    let near=0
    for (const a of samples[i].points.slice(1,-1)) if (samples[j].points.slice(1,-1).some((b) => Math.hypot(a.x-b.x,a.y-b.y)<3.2)) near += 1
    if (near >= 4) { edgeOverlap += 1; if (samples[i].dashed !== samples[j].dashed) solidDashedOverlap += 1 }
    else if (near > 0) edgeCrossings += 1
    const a=samples[i].points.at(-1), b=samples[j].points.at(-1)
    if (Math.hypot(a.x-b.x,a.y-b.y)<8) arrowArrow += 1
  }
  const outside = (box) => box.left < graphRect.left-2 || box.top < graphRect.top-2 || box.right > graphRect.right+2 || box.bottom > graphRect.bottom+2
  return {
    nodes:nodes.length, labels:labels.length, edges:paths.length,
    nodeNode, nodeEdge, nodeEdgeIds, edgeOverlap, solidDashedOverlap, edgeCrossings,
    labelNode, labelLabel, labelEdge, arrowNode, arrowArrow,
    nodeCanvasOverflow:nodeRects.filter(outside).length,
    labelCanvasOverflow:labelRects.filter(outside).length,
    missingArrowMarkers:paths.filter((item) => !item.getAttribute('marker-end') && !item.getAttribute('marker-start')).length,
    semanticLabels:labels.map((item) => item.querySelector(':scope > strong,:scope > span')?.textContent?.trim() ?? item.textContent.trim()).filter(Boolean),
  }
})()`

try {
  const pages = await retry(async () => {
    const response = await fetch(`http://127.0.0.1:${debugPort}/json`)
    if (!response.ok) throw new Error(`DevTools HTTP ${response.status}`)
    const result = await response.json()
    if (!result.length) throw new Error('No Edge page')
    return result
  })
  const page = pages.find((item) => item.type === 'page' && item.url.startsWith(appUrl)) ?? pages.find((item) => item.type === 'page')
  if (!page) throw new Error('No target Edge page')
  socket = new WebSocket(page.webSocketDebuggerUrl)
  socket.addEventListener('message', (event) => {
    const message = JSON.parse(event.data); const item = pending.get(message.id); if (!item) return
    pending.delete(message.id); if (message.error) item.reject(new Error(message.error.message)); else item.resolve(message)
  })
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, { once: true }); socket.addEventListener('error', reject, { once: true }) })
  await command('Page.enable'); await command('Runtime.enable')
  await waitFor(`document.querySelectorAll('.physical-block').length >= 13`)
  const physical = await evaluate(geometryExpression)
  const routerSymmetry = await evaluate(`(() => { const r=(id)=>document.querySelector('.react-flow__node[data-id="'+id+'"]')?.getBoundingClientRect(); const w=r('physical:control:west-router'),e=r('physical:control:east-router'),d=r('physical:control:distributor'); return { routerDeltaY:w&&e?Math.abs(w.top-e.top):null, distributorCenterDelta:d&&w&&e?Math.abs((d.left+d.width/2)-((w.left+w.width/2+e.left+e.width/2)/2)):null } })()`)
  const localLabels = await evaluate(`[...document.querySelectorAll('.physical-bus-label')].filter((item)=>item.textContent.includes('Local iMEM Load')).map((item)=>({text:item.querySelector(':scope > strong')?.textContent.trim(),lane:item.dataset.routeLane,lineStyle:item.dataset.lineStyle,rect:(()=>{const r=item.getBoundingClientRect();return{x:r.x,y:r.y,width:r.width,height:r.height}})()}))`)
  await screenshot(`stage15-physical-${width}x${height}.png`)

  const result = { viewport: { width, height }, physical, routerSymmetry, localLabels }
  if (width === 1920 && height === 1080) {
    const mxmLabel = `.physical-bus-label[data-edge-id="physical-interface:control:west:mxm:program"]`
    await hover(mxmLabel)
    await waitFor(`getComputedStyle(document.querySelector(${JSON.stringify(`${mxmLabel} .interface-evidence-tooltip`)})).visibility === 'visible'`)
    result.mxmTooltip = await evaluate(`(() => { const tip=document.querySelector(${JSON.stringify(`${mxmLabel} .interface-evidence-tooltip`)}); return { text:tip.textContent.replace(/\\s+/g,' ').trim(), rawSignals:[...tip.querySelectorAll('code')].map((item)=>item.textContent.trim()) } })()`)
    await screenshot('stage15-mxm-local-imem-tooltip-1920x1080.png')
    await click(mxmLabel)
    await waitFor(`!!document.querySelector('.bus-detail-view')`)
    result.busDetail = await evaluate(`({ source:document.querySelector('.bus-endpoint-card.endpoint-source h2')?.textContent?.trim() ?? '', destination:document.querySelector('.bus-endpoint-card.endpoint-destination h2')?.textContent?.trim() ?? '', groups:document.querySelectorAll('.bus-group-heading').length, rawExpanders:document.querySelectorAll('.bus-group-heading').length })`)
    await evaluate(`history.back(); true`); await waitFor(`document.querySelectorAll('.physical-block').length >= 13`)

    const blockIds = await evaluate(`[...document.querySelectorAll('.react-flow__node[data-id^="physical:"]')].filter((item)=>item.querySelector('.physical-block')).map((item)=>item.getAttribute('data-id'))`)
    result.functionalViews = []
    for (const blockId of blockIds) {
      await click(`.react-flow__node[data-id="${blockId}"]`)
      await waitFor(`!!document.querySelector('.functional-engineering-graph') || !!document.querySelector('.drill-leaf-view') || !!document.querySelector('.storage-node-detail')`)
      await new Promise((resolve) => setTimeout(resolve, 260))
      const audit = await evaluate(geometryExpression)
      const title = await evaluate(`document.querySelector('.drill-current-title strong')?.textContent?.trim() ?? ${JSON.stringify(blockId)}`)
      result.functionalViews.push({ blockId, title, audit })
      if (audit && (audit.nodeEdge || audit.edgeOverlap || audit.solidDashedOverlap || audit.edgeCrossings || audit.labelNode || audit.labelLabel || audit.arrowArrow)) {
        await screenshot(`stage15-conflict-${blockId.replace(/[^a-z0-9]+/gi, '-')}-${width}x${height}.png`)
      }
      await click('.drill-back'); await waitFor(`document.querySelectorAll('.physical-block').length >= 13`)
      await new Promise((resolve) => setTimeout(resolve, 180))
    }
    await click('.react-flow__node[data-id="physical:west:mem"]')
    await waitFor(`!!document.querySelector('.functional-engineering-graph')`)
    await new Promise((resolve) => setTimeout(resolve, 260))
    result.memFunctional = await evaluate(geometryExpression)
    await screenshot('stage15-mem-functional-1920x1080.png')
  }
  await fs.writeFile(path.join(artifactDir, `stage15-browser-audit-${width}x${height}.json`), `${JSON.stringify(result, null, 2)}\n`)
  console.log(JSON.stringify(result, null, 2))
} finally {
  try { socket?.close() } catch {}
  browser.kill()
  await new Promise((resolve) => { const timer = setTimeout(resolve, 1200); browser.once('exit', () => { clearTimeout(timer); resolve() }) })
  const resolvedProfile = path.resolve(userData)
  const resolvedArtifacts = path.resolve(artifactDir)
  if (resolvedProfile.startsWith(`${resolvedArtifacts}${path.sep}.stage15-edge-profile-`)) await fs.rm(resolvedProfile, { recursive: true, force: true })
}
