import { spawn } from 'node:child_process'
import { promises as fs } from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const appUrl = process.argv[2] ?? 'http://127.0.0.1:4173/'
const artifactDir = path.resolve(process.argv[3] ?? 'artifacts')
const edge = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'
const debugPort = 9338
await fs.mkdir(artifactDir, { recursive: true })
const userData = await fs.mkdtemp(path.join(os.tmpdir(), 'rtl-explorer-edge-'))

const browser = spawn(edge, [
  '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
  `--remote-debugging-port=${debugPort}`, `--user-data-dir=${userData}`,
  '--window-size=1920,1080', appUrl,
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
  if (selector.includes('react-flow__node')) await evaluate(`(() => { const element = document.querySelector(${JSON.stringify(selector)}); if (element) element.click(); return true })()`)
}

async function clickText(selector, text) {
  const point = await evaluate(`(() => { const element = [...document.querySelectorAll(${JSON.stringify(selector)})].find((item) => item.textContent.includes(${JSON.stringify(text)})); if (!element) return null; const rect = element.getBoundingClientRect(); return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 } })()`)
  if (!point) throw new Error(`Missing text click target: ${selector} / ${text}`)
  await command('Input.dispatchMouseEvent', { type: 'mousePressed', x: point.x, y: point.y, button: 'left', clickCount: 1 })
  await command('Input.dispatchMouseEvent', { type: 'mouseReleased', x: point.x, y: point.y, button: 'left', clickCount: 1 })
}

async function screenshot(name) {
  const response = await command('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false })
  await fs.writeFile(path.join(artifactDir, name), Buffer.from(response.result.data, 'base64'))
}

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
    const message = JSON.parse(event.data)
    const item = pending.get(message.id)
    if (!item) return
    pending.delete(message.id)
    if (message.error) item.reject(new Error(message.error.message)); else item.resolve(message)
  })
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, { once: true }); socket.addEventListener('error', reject, { once: true }) })
  await command('Page.enable')
  await command('Runtime.enable')
  await waitFor(`document.querySelectorAll('.physical-block').length >= 13`)
  await screenshot('stage14-physical-1920x1080.png')

  const physicalAudit = await evaluate(`(() => {
    const rect = (id) => document.querySelector('.react-flow__node[data-id="' + id + '"]')?.getBoundingClientRect()
    const store = rect('physical:control:program-store'), reassembly = rect('physical:control:reassembly'), distributor = rect('physical:control:distributor')
    const west = rect('physical:control:west-router'), east = rect('physical:control:east-router')
    const directed = [...document.querySelectorAll('.react-flow__edge-path.directed-edge')]
    return {
      verticalPipeline: !!store && !!reassembly && !!distributor && store.top < reassembly.top && reassembly.top < distributor.top,
      symmetricRouters: !!west && !!east && Math.abs(west.top - east.top) < 1 && Math.abs(west.height - east.height) < 1,
      directedEdges: directed.length,
      missingArrowMarkers: directed.filter((item) => !item.getAttribute('marker-end') && !item.getAttribute('marker-start')).length,
    }
  })()`)

  await click('.react-flow__node[data-id="physical:west:mem"]')
  await waitFor(`document.querySelector('.drill-current-title strong')?.textContent.includes('MEM West')`)
  await waitFor(`!!document.querySelector('[data-node-id="arch:west:mem:macro:word-fifo"]')`)
  const wordRect = await evaluate(`(() => { const r = document.querySelector('[data-node-id="arch:west:mem:macro:word-fifo"]').getBoundingClientRect(); return { x:r.x+r.width/2, y:r.y+r.height/2 } })()`)
  await command('Input.dispatchMouseEvent', { type: 'mouseMoved', x: wordRect.x, y: wordRect.y })
  await waitFor(`getComputedStyle(document.querySelector('[data-node-id="arch:west:mem:macro:word-fifo"] .hardware-spec-tooltip')).visibility === 'visible'`)
  const tooltipAudit = await evaluate(`(() => { const tip = document.querySelector('[data-node-id="arch:west:mem:macro:word-fifo"] .hardware-spec-tooltip'); return { text: tip.textContent.replace(/\\s+/g,' ').trim(), fontSize: getComputedStyle(tip.querySelector('div b')).fontSize } })()`)
  await screenshot('stage14-mem-word-fifo-hover-1920x1080.png')

  await click('.react-flow__node[data-id="arch:west:mem:execution"]')
  await waitFor(`document.querySelector('.drill-current-title strong')?.textContent.includes('Memory Execution Array')`)
  await screenshot('stage14-mem-execution-array-1920x1080.png')
  await click('.react-flow__node[data-id="arch:west:mem:execution:group:0"]')
  await waitFor(`document.querySelector('.drill-current-title strong')?.textContent.includes('Group[0]')`)
  await click('.react-flow__node[data-id="arch:west:mem:execution:column:0"]')
  await waitFor(`document.querySelector('.drill-current-title strong')?.textContent.includes('Column[0]')`)
  const beforeBack = await evaluate(`({ title: document.querySelector('.drill-current-title strong').textContent, back: document.querySelector('.drill-back').textContent.trim(), historyLength: history.length })`)
  await click('.drill-back')
  await waitFor(`document.querySelector('.drill-current-title strong')?.textContent.includes('Group[0]')`)
  const afterParentBack = await evaluate(`document.querySelector('.drill-current-title strong').textContent`)
  await evaluate(`history.back(); true`)
  await waitFor(`document.querySelector('.drill-current-title strong')?.textContent.includes('Memory Execution Array')`)
  const afterBrowserBack = await evaluate(`document.querySelector('.drill-current-title strong').textContent`)
  await evaluate(`history.forward(); true`)
  await waitFor(`document.querySelector('.drill-current-title strong')?.textContent.includes('Group[0]')`)
  const afterBrowserForward = await evaluate(`document.querySelector('.drill-current-title strong').textContent`)

  await clickText('.view-switcher button', 'Physical Architecture')
  await waitFor(`document.querySelectorAll('.physical-block').length >= 13`)
  await click('.react-flow__node[data-id="physical:control:distributor"]')
  await waitFor(`document.querySelector('.drill-current-title strong')?.textContent.includes('Program Load Distributor')`)
  const symmetryAudit = await evaluate(`(() => {
    const label = (text) => [...document.querySelectorAll('.connectivity-edge-label')].find((item) => item.textContent.includes(text))?.getBoundingClientRect()
    const node = (id) => document.querySelector('[data-node-id="' + id + '"]')?.getBoundingClientRect()
    const westHandshake = label('West Branch Handshake'), eastHandshake = label('East Branch Handshake')
    const westNode = node('arch:control:distributor:west'), eastNode = node('arch:control:distributor:east')
    const westComplete = label('West Branch Complete'), eastComplete = label('East Branch Complete')
    return {
      handshakeLabelDeltaY: westHandshake && eastHandshake ? Math.abs(westHandshake.top - eastHandshake.top) : null,
      branchNodeDeltaY: westNode && eastNode ? Math.abs(westNode.top - eastNode.top) : null,
      completionLabelDeltaY: westComplete && eastComplete ? Math.abs(westComplete.top - eastComplete.top) : null,
      edgeCount: document.querySelectorAll('.connectivity-edge').length,
      missingArrowMarkers: [...document.querySelectorAll('.connectivity-edge')].filter((item) => !item.getAttribute('marker-end')).length,
    }
  })()`)
  await screenshot('stage14-distributor-1920x1080.png')

  const result = { physicalAudit, tooltipAudit, navigationAudit: { beforeBack, afterParentBack, afterBrowserBack, afterBrowserForward }, symmetryAudit }
  await fs.writeFile(path.join(artifactDir, 'stage14-browser-audit.json'), JSON.stringify(result, null, 2))
  console.log(JSON.stringify(result, null, 2))
} finally {
  try { socket?.close() } catch {}
  browser.kill()
  await new Promise((resolve) => { const timer = setTimeout(resolve, 1200); browser.once('exit', () => { clearTimeout(timer); resolve() }) })
  if (path.resolve(userData).startsWith(path.resolve(os.tmpdir()))) {
    try { await retry(() => fs.rm(userData, { recursive: true, force: true }), 4000) }
    catch (error) { console.warn(`Temporary Edge profile cleanup deferred: ${error.message}`) }
  }
}
