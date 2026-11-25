import { spawn } from 'node:child_process'
import { promises as fs } from 'node:fs'
import path from 'node:path'

const appUrl = process.argv[2] ?? 'http://127.0.0.1:4173/'
const artifactDir = path.resolve(process.argv[3] ?? 'artifacts')
const width = Number(process.argv[4] ?? 1920)
const height = Number(process.argv[5] ?? 1080)
const debugPort = Number(process.argv[6] ?? 9450)
const edge = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe'
await fs.mkdir(artifactDir, { recursive: true })
const userData = path.join(artifactDir, `.configuration-edge-profile-${width}x${height}-${process.pid}`)
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
  await waitFor(`document.querySelectorAll('.view-switcher button').length >= 5`)
  await evaluate(`(() => { const button=[...document.querySelectorAll('.view-switcher button')].find((item)=>item.textContent.includes('Configuration')); button?.click(); return !!button })()`)
  await waitFor(`!!document.querySelector('.configuration-overview')`)
  await wait(250)
  const result = await evaluate(`(() => {
    const view=document.querySelector('.configuration-overview')
    const canvas=document.querySelector('.configuration-canvas')
    const style=(selector)=>getComputedStyle(document.querySelector(selector))
    const textOverflows=[...view.querySelectorAll('h1,h2,h3,.composition-unit span,.configuration-summary-grid span,.contract-card span,.contract-card strong,.contract-card small,.program-contract-reviews strong,.program-contract-reviews span')].filter((item)=>item.scrollWidth>item.clientWidth+1 || item.scrollHeight>item.clientHeight+1).map((item)=>item.textContent.trim())
    const array=document.querySelector('.mem-sram-array')
    return {
      viewport:{width:innerWidth,height:innerHeight},
      summaryCards:view.querySelectorAll('.configuration-summary-grid article').length,
      compositionCards:view.querySelectorAll('.configuration-composition').length,
      memGroups:view.querySelectorAll('.mem-sram-group').length,
      memSliceCells:view.querySelectorAll('.mem-sram-slice').length,
      sampleMacroCells:view.querySelectorAll('.sample-macro-grid i').length,
      programLoadContract:!!view.querySelector('.program-load-contract'),
      strobeSegments:view.querySelectorAll('.strobe-segments > b').length,
      programLoadDestinations:view.querySelectorAll('.contract-destinations > article').length,
      commitText:view.querySelector('.ordered-commit')?.textContent.replace(/\s+/g,' ').trim(),
      reviewItems:view.querySelectorAll('.program-contract-reviews > div').length,
      textOverflows,
      canvasClientWidth:canvas.clientWidth,
      canvasScrollWidth:canvas.scrollWidth,
      arrayWidth:array.getBoundingClientRect().width,
      palette:{sram:style('.composition-unit.resource-storage').backgroundColor,stream:style('.composition-unit.resource-interface').backgroundColor,mem:style('.configuration-composition.fu-mem > header').backgroundColor},
      borders:{hero:style('.configuration-hero').borderTopWidth,composition:style('.configuration-composition').borderTopWidth,color:style('.configuration-hero').borderTopColor},
      macroStatus:document.querySelector('.availability-badge')?.textContent.trim(),
      mappedTotal:[...document.querySelectorAll('.mem-array-metrics div')].find((item)=>item.textContent.includes('All-MEM'))?.querySelector('strong')?.textContent.trim(),
      activeMacroText:document.querySelector('.configuration-callout')?.textContent.replace(/\\s+/g,' ').trim(),
    }
  })()`)
  await screenshot(`configuration-overview-${width}x${height}.png`)
  await evaluate(`document.querySelector('.program-load-contract').scrollIntoView({block:'start'}); true`)
  await wait(150)
  await screenshot(`configuration-program-load-${width}x${height}.png`)
  await evaluate(`document.querySelector('.mem-array-detail').scrollIntoView({block:'start'}); true`)
  await wait(150)
  await screenshot(`configuration-mem-array-${width}x${height}.png`)
  await fs.writeFile(path.join(artifactDir, `configuration-browser-audit-${width}x${height}.json`), `${JSON.stringify(result, null, 2)}\n`)
  console.log(JSON.stringify(result, null, 2))
} finally {
  try { socket?.close() } catch {}
  browser.kill()
  await new Promise((resolve) => { const timer = setTimeout(resolve, 1200); browser.once('exit', () => { clearTimeout(timer); resolve() }) })
  const resolvedProfile = path.resolve(userData)
  const resolvedArtifacts = path.resolve(artifactDir)
  if (resolvedProfile.startsWith(`${resolvedArtifacts}${path.sep}.configuration-edge-profile-`)) await fs.rm(resolvedProfile, { recursive: true, force: true })
}
