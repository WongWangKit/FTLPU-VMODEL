import { spawn } from 'node:child_process'
import { promises as fs } from 'node:fs'
import path from 'node:path'

const appUrl = process.argv[2] ?? 'http://127.0.0.1:4173/'
const artifactDir = path.resolve(process.argv[3] ?? 'artifacts/stage16')
const width = Number(process.argv[4] ?? 1920)
const height = Number(process.argv[5] ?? 1080)
const debugPort = Number(process.argv[6] ?? 9466)
const edge = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'
await fs.mkdir(artifactDir, { recursive: true })
const userData = path.join(artifactDir, `.stage16-edge-profile-${width}x${height}-${process.pid}`)
await fs.mkdir(userData, { recursive: true })

const browser = spawn(edge, [
  '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
  `--remote-debugging-port=${debugPort}`, `--user-data-dir=${userData}`,
  `--window-size=${width},${height}`, appUrl,
], { stdio: 'ignore' })

let socket
let sequence = 0
const pending = new Map()
const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))

async function retry(fn, timeout = 20000) {
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

async function waitFor(expression, timeout = 15000) {
  return retry(async () => {
    const value = await evaluate(expression)
    if (!value) throw new Error(`Waiting for ${expression}`)
    return value
  }, timeout)
}

async function screenshot(name) {
  const response = await command('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false })
  await fs.writeFile(path.join(artifactDir, name), Buffer.from(response.result.data, 'base64'))
}

async function clickView(label) {
  await evaluate(`(() => { const button=[...document.querySelectorAll('.view-switcher button')].find((item)=>item.textContent.includes(${JSON.stringify(label)})); button?.click(); return !!button })()`)
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
  await waitFor(`document.querySelectorAll('.view-switcher button').length >= 5`)

  await clickView('Configuration')
  await waitFor(`!!document.querySelector('.configuration-reactflow[data-configuration-mode="unified"]')`)
  await evaluate(`document.querySelector('.configuration-visualization').scrollIntoView({block:'start'}); true`)
  await wait(250)
  const schemeA = await evaluate(`(() => ({
    frames:document.querySelectorAll('.configuration-reactflow[data-configuration-mode="unified"] .configuration-fu-frame').length,
    units:document.querySelectorAll('.configuration-reactflow[data-configuration-mode="unified"] .configuration-unit-node').length,
    links:document.querySelectorAll('.configuration-reactflow[data-configuration-mode="unified"] .configuration-composition-edge').length,
    minimap:!!document.querySelector('.configuration-reactflow[data-configuration-mode="unified"] .react-flow__minimap'),
    inspector:!!document.querySelector('[data-configuration-inspector]'),
    titleOverflows:[...document.querySelectorAll('.configuration-unit-node strong')].filter((item)=>item.scrollWidth>item.clientWidth+1 || item.scrollHeight>item.clientHeight+1).map((item)=>item.textContent.trim()),
  }))()`)
  await screenshot(`configuration-scheme-a-${width}x${height}.png`)

  await evaluate(`(() => { const button=[...document.querySelectorAll('.configuration-mode-switch button')].find((item)=>item.textContent.includes('分区画布')); button?.click(); return !!button })()`)
  await waitFor(`!!document.querySelector('.configuration-reactflow[data-configuration-mode="partitioned"]')`)
  await wait(200)
  const schemeB = await evaluate(`(() => ({
    frames:document.querySelectorAll('.configuration-reactflow[data-configuration-mode="partitioned"] .configuration-fu-frame').length,
    units:document.querySelectorAll('.configuration-reactflow[data-configuration-mode="partitioned"] .configuration-unit-node').length,
    fuTabs:document.querySelectorAll('.configuration-fu-tabs button').length,
    inspectorText:document.querySelector('[data-configuration-inspector]')?.textContent.replace(/\\s+/g,' ').trim(),
    titleOverflows:[...document.querySelectorAll('.configuration-reactflow[data-configuration-mode="partitioned"] .configuration-unit-node strong')].filter((item)=>item.scrollWidth>item.clientWidth+1 || item.scrollHeight>item.clientHeight+1).map((item)=>item.textContent.trim()),
  }))()`)
  await screenshot(`configuration-scheme-b-${width}x${height}.png`)

  await clickView('Physical Architecture')
  await waitFor(`!!document.querySelector('[data-id="physical:control:instruction-dma"]')`)
  await evaluate(`window.scrollTo(0,0); true`)
  await wait(200)
  const physical = await evaluate(`(() => ({
    dma:document.querySelector('[data-id="physical:control:instruction-dma"] .physical-block')?.getAttribute('data-evidence-status'),
    ddr:document.querySelector('[data-id="physical:external:instruction-ddr"] .physical-block')?.getAttribute('data-evidence-status'),
    bus:document.querySelector('[data-id="physical:external:program-bus"] .physical-block')?.getAttribute('data-evidence-status'),
    regions:document.querySelectorAll('.physical-region-frame').length,
    externalLabels:[...new Set([...document.querySelectorAll('.physical-bus-label strong')].map((item)=>item.textContent.trim()))].filter((text)=>/External|Program Read|Program Response|DDR|BUS/i.test(text)),
  }))()`)
  await screenshot(`physical-dma-ddr-boundary-${width}x${height}.png`)

  await evaluate(`(() => { const node=document.querySelector('[data-id="physical:control:instruction-dma"] .physical-block'); node?.dispatchEvent(new MouseEvent('click',{bubbles:true})); return !!node })()`)
  await waitFor(`document.querySelectorAll('.connectivity-group-frame').length >= 3 && document.body.textContent.includes('Instruction DMA · RTL Architecture')`)
  await wait(250)
  const dma = await evaluate(`(() => ({
    groups:[...document.querySelectorAll('.connectivity-group-frame')].map((item)=>item.textContent.replace(/\\s+/g,' ').trim()),
    nodes:[...new Set([...document.querySelectorAll('.connectivity-node.architecture-node strong')].map((item)=>item.textContent.trim()))],
    edgeLabels:[...new Set([...document.querySelectorAll('.connectivity-edge-label strong')].map((item)=>item.textContent.trim()))],
    clippedNodes:[...document.querySelectorAll('.connectivity-node.architecture-node')].filter((item)=>{const r=item.getBoundingClientRect();const canvas=document.querySelector('.functional-canvas').getBoundingClientRect();return r.top<canvas.top || r.bottom>canvas.bottom || r.left<canvas.left || r.right>canvas.right}).map((item)=>item.textContent.replace(/\\s+/g,' ').trim()),
  }))()`)
  await screenshot(`instruction-dma-drilldown-${width}x${height}.png`)

  const result = {
    viewport: { width, height },
    url: appUrl,
    schemeA,
    schemeB,
    physical,
    dma,
    assertions: {
      schemeAHasFiveFus: schemeA.frames === 5,
      schemeAHasMinimap: schemeA.minimap,
      schemeBHasOneFu: schemeB.frames === 1,
      schemeBHasFiveTabs: schemeB.fuTabs === 5,
      dmaIsRtlConfirmed: physical.dma === 'rtl-confirmed',
      externalBoundariesNeedReview: physical.ddr === 'needs-review' && physical.bus === 'needs-review',
      dmaHasThreeSemanticGroups: dma.groups.length === 3,
      dmaHasEightNodes: dma.nodes.length === 8,
      noConfigurationTitleOverflow: schemeA.titleOverflows.length === 0 && schemeB.titleOverflows.length === 0,
    },
  }
  await fs.writeFile(path.join(artifactDir, `stage16-browser-audit-${width}x${height}.json`), `${JSON.stringify(result, null, 2)}\n`)
  console.log(JSON.stringify(result, null, 2))
} finally {
  try { socket?.close() } catch {}
  browser.kill()
  await new Promise((resolve) => { const timer = setTimeout(resolve, 1200); browser.once('exit', () => { clearTimeout(timer); resolve() }) })
  const resolvedProfile = path.resolve(userData)
  const resolvedArtifacts = path.resolve(artifactDir)
  if (resolvedProfile.startsWith(`${resolvedArtifacts}${path.sep}.stage16-edge-profile-`)) await fs.rm(resolvedProfile, { recursive: true, force: true })
}
