import { spawn } from 'node:child_process'
import { promises as fs } from 'node:fs'
import path from 'node:path'

const appUrl = process.argv[2] ?? 'http://127.0.0.1:5180/'
const artifactDir = path.resolve(process.argv[3] ?? 'artifacts')
const edge = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'
const debugPort = Number(process.argv[4] ?? 9462)
const userData = path.join(artifactDir, `.mem-decoder-edge-profile-${process.pid}`)
await fs.mkdir(userData, { recursive: true })

const browser = spawn(edge, [
  '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
  `--remote-debugging-port=${debugPort}`, `--user-data-dir=${userData}`,
  '--window-size=2048,1200', appUrl,
], { stdio: 'ignore' })

let socket
let sequence = 0
const pending = new Map()
const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))

async function retry(fn, timeout = 15000) {
  const start = Date.now()
  let lastError
  while (Date.now() - start < timeout) {
    try { return await fn() } catch (error) { lastError = error; await wait(120) }
  }
  throw lastError
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
    if (!value) throw new Error(`Waiting for ${expression}`)
    return value
  }, timeout)
}

async function clickText(selector, text, synthetic = false) {
  const target = await evaluate(`(() => {
    const element = [...document.querySelectorAll(${JSON.stringify(selector)})].find((item) => (item.textContent || '').includes(${JSON.stringify(text)}))
    if (!element) return null
    const bounds = element.getBoundingClientRect()
    return { x: bounds.x + bounds.width / 2, y: bounds.y + bounds.height / 2 }
  })()`)
  if (!target) throw new Error(`Missing click target: ${selector} / ${text}`)
  await command('Input.dispatchMouseEvent', { type: 'mousePressed', x: target.x, y: target.y, button: 'left', clickCount: 1 })
  await command('Input.dispatchMouseEvent', { type: 'mouseReleased', x: target.x, y: target.y, button: 'left', clickCount: 1 })
  if (synthetic) await evaluate(`(() => {
    const element = [...document.querySelectorAll(${JSON.stringify(selector)})].find((item) => (item.textContent || '').includes(${JSON.stringify(text)}))
    element?.click()
    return !!element
  })()`)
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
  await new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve, { once: true })
    socket.addEventListener('error', reject, { once: true })
  })
  await command('Page.enable')
  await command('Runtime.enable')
  await waitFor(`document.querySelectorAll('.react-flow__node-frontendMarker').length > 0`)
  const regularView = await evaluate(`({
    architecturePolicyPresent: !!document.querySelector('.architecture-policy'),
    physicalTopologyTextPresent: /PHYSICAL TOPOLOGY/i.test(document.body.innerText),
    floorplanDisclaimerPresent: /此视图不是最终芯片.*floorplan|后端物理坐标|实际布线/i.test(document.body.innerText),
  })`)
  await clickText('.react-flow__node-frontendMarker', 'MEM FRONTEND', true)
  await waitFor(`[...document.querySelectorAll('button.frontend-stage-trigger')].some((item) => /MEM Macro Decoder/i.test(item.textContent || ''))`)
  await clickText('button.frontend-stage-trigger', 'MEM Macro Decoder')
  await waitFor(`document.querySelector('.physical-frontend-pipeline-level > header h2')?.textContent.includes('MEM Macro Decoder 状态转移图')`)
  await evaluate(`document.querySelector('button[aria-label="Fit View"]')?.click(); true`)
  await wait(350)

  const result = await evaluate(`(() => {
    const rect = (element) => {
      const value = element.getBoundingClientRect()
      return { x: value.x, y: value.y, right: value.right, bottom: value.bottom }
    }
    const overlaps = (a, b, padding = 1) => a.x < b.right - padding && a.right > b.x + padding && a.y < b.bottom - padding && a.bottom > b.y + padding
    const nodes = [...document.querySelectorAll('.react-flow__node-frontendPipelineStep')].map((element) => ({ text: element.textContent.replace(/\\s+/g, ' ').trim(), ...rect(element) }))
    const labels = [...document.querySelectorAll('.react-flow__edge-text')].filter((element) => element.textContent.trim()).map((element) => ({ text: element.textContent.trim(), ...rect(element) }))
    const nodeOverlaps = []
    const labelOverlaps = []
    const labelNodeOverlaps = []
    for (let index = 0; index < nodes.length; index += 1) for (let other = index + 1; other < nodes.length; other += 1) if (overlaps(nodes[index], nodes[other])) nodeOverlaps.push([nodes[index].text, nodes[other].text])
    for (let index = 0; index < labels.length; index += 1) for (let other = index + 1; other < labels.length; other += 1) if (overlaps(labels[index], labels[other])) labelOverlaps.push([labels[index].text, labels[other].text])
    for (const label of labels) for (const node of nodes) if (overlaps(label, node, 2)) labelNodeOverlaps.push([label.text, node.text])
    const edgePaths = [...document.querySelectorAll('.decoder-state-transition .react-flow__edge-path')]
    const nodeElements = [...document.querySelectorAll('.frontend-pipeline-step[data-state-machine="true"]')]
    const isVisible = (selector) => {
      const element = document.querySelector(selector)
      if (!element) return false
      const style = getComputedStyle(element)
      const bounds = element.getBoundingClientRect()
      return style.display !== 'none' && style.visibility !== 'hidden' && bounds.width > 0 && bounds.height > 0
    }
    return {
      title: document.querySelector('.physical-frontend-pipeline-level > header h2')?.textContent.trim(),
      focusChrome: {
        brandVisible: isVisible('.topbar .brand'),
        viewSwitcherVisible: isVisible('.topbar .view-switcher'),
        topbarActionsVisible: isVisible('.topbar-actions'),
        statusStripVisible: isVisible('.status-strip'),
        architecturePolicyVisible: isVisible('.architecture-policy'),
        architectureToolbarVisible: isVisible('.architecture-toolbar'),
        leftSidebarVisible: isVisible('.left-panel'),
        rightSidebarVisible: isVisible('.right-sidebar-shell'),
        graphLegendVisible: isVisible('.graph-legend-bar'),
        stateBackButtonPresent: !!document.querySelector('.decoder-state-machine-heading button'),
        stateSummaryPresent: !!document.querySelector('.frontend-pipeline-level-summary'),
        stateFrameHeaderVisible: isVisible('.physical-frontend-pipeline-level[data-state-machine-focus="true"] .frontend-level-variant > header'),
      },
      functionalNodes: nodes.length,
      transitionLabels: labels.length,
      oldFifteenStateTextPresent: /15-state|15 state|15 状态/i.test(document.body.innerText),
      idleCompletionLoopPresent: labels.some((label) => /Queue Macro 数 = 0.*done_o = 1/.test(label.text)),
      missingArrowMarkers: edgePaths.filter((path) => !path.getAttribute('marker-end')).length,
      edgeStrokeWidths: [...new Set(edgePaths.map((path) => getComputedStyle(path).strokeWidth))],
      edgeStrokeColors: [...new Set(edgePaths.map((path) => getComputedStyle(path).stroke))],
      nodeBorderWidths: [...new Set(nodeElements.map((node) => getComputedStyle(node).borderTopWidth))],
      nodeBorderColors: [...new Set(nodeElements.map((node) => getComputedStyle(node).borderTopColor))],
      nodeOverlaps,
      labelOverlaps,
      labelNodeOverlaps,
    }
  })()`)
  result.regularView = regularView

  await screenshot('mem-macro-decoder-state-transition.png')
  await clickText('.decoder-state-machine-heading button', 'L2 MEM Frontend')
  await waitFor(`!!document.querySelector('.physical-frontend-level')`)
  result.focusChrome.backNavigationWorks = true
  await fs.writeFile(path.join(artifactDir, 'mem-macro-decoder-browser-audit.json'), `${JSON.stringify(result, null, 2)}\n`)
  console.log(JSON.stringify(result, null, 2))
} finally {
  try { socket?.close() } catch {}
  browser.kill()
  await new Promise((resolve) => {
    const timer = setTimeout(resolve, 1200)
    browser.once('exit', () => { clearTimeout(timer); resolve() })
  })
  const resolvedProfile = path.resolve(userData)
  const resolvedArtifacts = path.resolve(artifactDir)
  if (resolvedProfile.startsWith(`${resolvedArtifacts}${path.sep}.mem-decoder-edge-profile-`)) await fs.rm(resolvedProfile, { recursive: true, force: true })
}
