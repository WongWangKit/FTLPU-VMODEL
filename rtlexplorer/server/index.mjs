import http from 'node:http'
import { promises as fs, createReadStream } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseProject, writeSnapshot, hierarchyForTop } from './rtl-parser.mjs'
import { attachArchitectureModel, loadArchitectureRules } from './architecture-model.mjs'
import { loadPhysicalArchitectureRules } from './physical-architecture-model.mjs'

const serverDirectory = path.dirname(fileURLToPath(import.meta.url))
const appRoot = path.resolve(serverDirectory, '..')
const configPath = path.join(appRoot, 'config.json')
const dataDirectory = path.join(appRoot, 'data')
const snapshotPath = path.join(dataDirectory, 'architecture-snapshot.json')
const configurationOverviewPath = path.join(dataDirectory, 'configuration-overview.json')
const importedSnapshotPath = path.join(dataDirectory, 'imported-snapshot.json')
const metadataPath = path.join(dataDirectory, 'module-metadata.json')
const architectureRulesPath = path.join(dataDirectory, 'architecture-rules.json')
const physicalArchitectureRulesPath = path.join(dataDirectory, 'physical-architecture-rules.json')
const distDirectory = path.join(appRoot, 'dist')

let config = JSON.parse(await fs.readFile(configPath, 'utf8'))
const isaSourceRoots = {
  VMODEL: path.resolve(appRoot, '..', 'FTLPU-VMODEL-main'),
  CMODEL: path.resolve(appRoot, '..', 'FTLPU-CMODEL-clock'),
  SOFTWARE: path.resolve(appRoot, '..', 'FTLPU-SOFTWARE-main'),
}
let snapshot = null
let savedConfigurationOverview = null
let metadata = { schemaVersion: 1, modules: {} }
let architectureRules = await loadArchitectureRules(architectureRulesPath)
let physicalArchitectureRules = await loadPhysicalArchitectureRules(physicalArchitectureRulesPath)
let scanState = { running: false, phase: 'idle', completed: 0, total: 0, message: 'Ready', error: null }

try { metadata = JSON.parse(await fs.readFile(metadataPath, 'utf8')) } catch {}
try { savedConfigurationOverview = JSON.parse(await fs.readFile(configurationOverviewPath, 'utf8')) } catch {}
try { snapshot = JSON.parse(await fs.readFile(snapshotPath, 'utf8')) } catch {}
if (snapshot) {
  snapshot = attachArchitectureModel(snapshot, architectureRules, physicalArchitectureRules)
  if (savedConfigurationOverview) snapshot = { ...snapshot, configurationOverview: savedConfigurationOverview }
}

function applyMetadata(value) {
  if (!value) return value
  return {
    ...value,
    modules: value.modules.map((module) => ({
      ...module,
      userDescription: metadata.modules?.[module.name]?.description ?? '',
      userDescriptionUpdatedAt: metadata.modules?.[module.name]?.updatedAt ?? null,
    })),
  }
}

async function writeJsonAtomic(filePath, value) {
  await fs.mkdir(path.dirname(filePath), { recursive: true })
  const temporary = `${filePath}.${process.pid}.tmp`
  await fs.writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, 'utf8')
  await fs.rename(temporary, filePath)
}

async function runScan(nextConfig = config) {
  if (scanState.running) throw new Error('A scan is already running.')
  scanState = { running: true, phase: 'starting', completed: 0, total: 0, message: 'Starting RTL scan', error: null }
  try {
    const parsedSnapshot = await parseProject(nextConfig, (progress) => {
      scanState = { ...scanState, ...progress, running: true, error: null }
    })
    architectureRules = await loadArchitectureRules(architectureRulesPath)
    physicalArchitectureRules = await loadPhysicalArchitectureRules(physicalArchitectureRulesPath)
    const nextSnapshot = attachArchitectureModel(parsedSnapshot, architectureRules, physicalArchitectureRules)
    savedConfigurationOverview = nextSnapshot.configurationOverview
    await Promise.all([writeSnapshot(nextSnapshot, snapshotPath), writeJsonAtomic(configurationOverviewPath, savedConfigurationOverview)])
    await writeJsonAtomic(configPath, nextConfig)
    config = nextConfig
    snapshot = nextSnapshot
    scanState = { running: false, phase: 'complete', completed: nextSnapshot.summary.sourceFileCount, total: nextSnapshot.summary.sourceFileCount, message: 'RTL scan complete', error: null }
    return nextSnapshot
  } catch (error) {
    scanState = { ...scanState, running: false, phase: 'failed', message: 'RTL scan failed', error: error.message }
    throw error
  }
}

if (!snapshot) {
  try { await runScan(config) }
  catch (error) { console.error(`Initial RTL scan failed: ${error.stack ?? error.message}`) }
}

function jsonResponse(response, status, body) {
  const payload = Buffer.from(JSON.stringify(body))
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': payload.length,
    'Cache-Control': 'no-store',
  })
  response.end(payload)
}

async function readJsonBody(request, limit = 64 * 1024 * 1024) {
  const chunks = []
  let size = 0
  for await (const chunk of request) {
    size += chunk.length
    if (size > limit) throw new Error('Request body is too large.')
    chunks.push(chunk)
  }
  if (!chunks.length) return {}
  return JSON.parse(Buffer.concat(chunks).toString('utf8'))
}

const mimeTypes = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.map': 'application/json; charset=utf-8',
}

async function serveStatic(request, response, url) {
  const requested = decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname)
  const candidate = path.resolve(distDirectory, `.${requested}`)
  const withinDist = candidate === distDirectory || candidate.startsWith(`${distDirectory}${path.sep}`)
  let filePath = withinDist ? candidate : path.join(distDirectory, 'index.html')
  try {
    const stat = await fs.stat(filePath)
    if (!stat.isFile()) filePath = path.join(distDirectory, 'index.html')
  } catch {
    filePath = path.join(distDirectory, 'index.html')
  }
  try {
    const stat = await fs.stat(filePath)
    response.writeHead(200, {
      'Content-Type': mimeTypes[path.extname(filePath)] ?? 'application/octet-stream',
      'Content-Length': stat.size,
      'Cache-Control': filePath.endsWith('index.html') ? 'no-store' : 'public, max-age=31536000, immutable',
    })
    if (request.method === 'HEAD') response.end()
    else createReadStream(filePath).pipe(response)
  } catch {
    jsonResponse(response, 503, { error: 'Frontend build is missing. Run npm run build.' })
  }
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url ?? '/', 'http://127.0.0.1')
  try {
    if (request.method === 'GET' && url.pathname === '/api/snapshot') {
      if (!snapshot) return jsonResponse(response, 503, { error: scanState.error ?? 'No architecture snapshot is available.', scanState })
      return jsonResponse(response, 200, applyMetadata(snapshot))
    }
    if (request.method === 'GET' && url.pathname === '/api/status') return jsonResponse(response, 200, scanState)
    if (request.method === 'GET' && url.pathname === '/api/architecture-rules') return jsonResponse(response, 200, architectureRules)
    if (request.method === 'GET' && url.pathname === '/api/physical-architecture-rules') return jsonResponse(response, 200, physicalArchitectureRules)
    if (request.method === 'GET' && url.pathname === '/api/config') {
      return jsonResponse(response, 200, { ...config, appRoot, snapshotPath })
    }
    if (request.method === 'POST' && url.pathname === '/api/rescan') {
      const body = await readJsonBody(request)
      const nextConfig = {
        ...config,
        ...(body.projectRoot ? { projectRoot: body.projectRoot } : {}),
        ...(body.sourceDirectory ? { sourceDirectory: body.sourceDirectory } : {}),
        ...(body.filelist ? { filelist: body.filelist } : {}),
        ...(body.veribleExecutable ? { veribleExecutable: body.veribleExecutable } : {}),
        ...(body.preferredTop ? { preferredTop: body.preferredTop } : {}),
      }
      const result = await runScan(nextConfig)
      return jsonResponse(response, 200, { ok: true, summary: result.summary, warningCount: result.warnings.length })
    }
    if (request.method === 'POST' && url.pathname === '/api/select-top') {
      if (!snapshot) return jsonResponse(response, 503, { error: 'No architecture snapshot is available.' })
      const body = await readJsonBody(request, 1024 * 1024)
      if (!snapshot.modules.some((module) => module.name === body.top)) return jsonResponse(response, 400, { error: 'Unknown module definition.' })
      const rebuilt = hierarchyForTop(snapshot.modules, body.top, { maxDepth: config.hierarchyMaxDepth, maxNodes: config.hierarchyMaxNodes })
      snapshot = attachArchitectureModel({
        ...snapshot,
        summary: {
          ...snapshot.summary,
          selectedTop: body.top,
          hierarchyNodeCount: rebuilt.hierarchy.nodes.length,
          hierarchyEdgeCount: rebuilt.hierarchy.edges.length,
        },
        hierarchy: rebuilt.hierarchy,
        warnings: [...snapshot.warnings.filter((warning) => !['HIERARCHY_DEPTH_LIMIT', 'HIERARCHY_RECURSION', 'HIERARCHY_NODE_LIMIT'].includes(warning.code)), ...rebuilt.warnings],
      }, architectureRules, physicalArchitectureRules)
      if (savedConfigurationOverview) snapshot = { ...snapshot, configurationOverview: savedConfigurationOverview }
      config = { ...config, preferredTop: body.top }
      await Promise.all([writeSnapshot(snapshot, snapshotPath), writeJsonAtomic(configPath, config)])
      return jsonResponse(response, 200, applyMetadata(snapshot))
    }
    if (request.method === 'POST' && url.pathname === '/api/metadata') {
      const body = await readJsonBody(request, 2 * 1024 * 1024)
      if (!body.moduleName || typeof body.description !== 'string') return jsonResponse(response, 400, { error: 'moduleName and description are required.' })
      if (!snapshot?.modules.some((module) => module.name === body.moduleName)) return jsonResponse(response, 400, { error: 'Unknown module definition.' })
      metadata = {
        schemaVersion: 1,
        modules: {
          ...(metadata.modules ?? {}),
          [body.moduleName]: { description: body.description.trim(), updatedAt: new Date().toISOString() },
        },
      }
      await writeJsonAtomic(metadataPath, metadata)
      return jsonResponse(response, 200, { ok: true, module: metadata.modules[body.moduleName] })
    }
    if (request.method === 'POST' && url.pathname === '/api/import-snapshot') {
      const body = await readJsonBody(request)
      if (body.schemaVersion !== 1 || !Array.isArray(body.modules) || !body.hierarchy) return jsonResponse(response, 400, { error: 'Unsupported Architecture Snapshot.' })
      snapshot = attachArchitectureModel(body, architectureRules, physicalArchitectureRules)
      if (savedConfigurationOverview) snapshot = { ...snapshot, configurationOverview: savedConfigurationOverview }
      await writeSnapshot(snapshot, importedSnapshotPath)
      return jsonResponse(response, 200, { ok: true, summary: snapshot.summary, importedPath: importedSnapshotPath })
    }
    if (request.method === 'GET' && url.pathname === '/api/export') {
      if (!snapshot) return jsonResponse(response, 503, { error: 'No architecture snapshot is available.' })
      const payload = Buffer.from(`${JSON.stringify(applyMetadata(snapshot), null, 2)}\n`)
      response.writeHead(200, {
        'Content-Type': 'application/json; charset=utf-8',
        'Content-Length': payload.length,
        'Content-Disposition': `attachment; filename="lpu-architecture-snapshot-${new Date().toISOString().slice(0, 10)}.json"`,
        'Cache-Control': 'no-store',
      })
      return response.end(payload)
    }
    if (request.method === 'GET' && url.pathname === '/api/source') {
      if (!snapshot) return jsonResponse(response, 503, { error: 'No architecture snapshot is available.' })
      const relativeFile = url.searchParams.get('file') ?? ''
      const requestedLine = Math.max(1, Number.parseInt(url.searchParams.get('line') ?? '1', 10) || 1)
      const projectRoot = path.resolve(snapshot.project.projectRoot)
      const sourcePath = path.resolve(projectRoot, relativeFile)
      if (!(sourcePath === projectRoot || sourcePath.startsWith(`${projectRoot}${path.sep}`))) return jsonResponse(response, 403, { error: 'Source path is outside the configured project.' })
      const text = await fs.readFile(sourcePath, 'utf8')
      const lines = text.split(/\r?\n/)
      const start = Math.max(1, requestedLine - 10)
      const end = Math.min(lines.length, requestedLine + 20)
      return jsonResponse(response, 200, {
        file: relativeFile,
        absolutePath: sourcePath,
        focusLine: requestedLine,
        startLine: start,
        lines: lines.slice(start - 1, end).map((line, index) => ({ number: start + index, text: line })),
      })
    }
    if (request.method === 'GET' && url.pathname === '/api/isa-source') {
      const repo = url.searchParams.get('repo') ?? ''
      const relativeFile = url.searchParams.get('file') ?? ''
      const requestedLine = Number.parseInt(url.searchParams.get('line') ?? '', 10)
      const root = isaSourceRoots[repo]
      if (!root || !relativeFile || path.isAbsolute(relativeFile) || !Number.isInteger(requestedLine) || requestedLine < 1) {
        return jsonResponse(response, 400, { error: 'Invalid ISA source request.' })
      }
      const sourcePath = path.resolve(root, relativeFile)
      if (!sourcePath.startsWith(`${root}${path.sep}`) || !/\.(sv|svh|cpp|hpp|h|cc|md|txt)$/i.test(sourcePath)) {
        return jsonResponse(response, 403, { error: 'ISA source path is outside the allowed files.' })
      }
      const realRoot = await fs.realpath(root)
      const realSource = await fs.realpath(sourcePath)
      if (!realSource.startsWith(`${realRoot}${path.sep}`)) {
        return jsonResponse(response, 403, { error: 'ISA source path is outside the allowed files.' })
      }
      const lines = (await fs.readFile(realSource, 'utf8')).split(/\r?\n/)
      if (requestedLine > lines.length) return jsonResponse(response, 404, { error: 'Source line is unavailable.' })
      const start = Math.max(1, requestedLine - 3)
      const end = Math.min(lines.length, requestedLine + 5)
      return jsonResponse(response, 200, {
        repo, file: relativeFile, focusLine: requestedLine, startLine: start,
        lines: lines.slice(start - 1, end).map((line, index) => ({ number: start + index, text: line })),
      })
    }
    if ((request.method === 'GET' || request.method === 'HEAD') && !url.pathname.startsWith('/api/')) return serveStatic(request, response, url)
    return jsonResponse(response, 404, { error: 'Not found.' })
  } catch (error) {
    const status = error.message === 'A scan is already running.' ? 409 : 500
    console.error(error.stack ?? error.message)
    return jsonResponse(response, status, { error: error.message })
  }
})

const port = Number(process.env.RTL_EXPLORER_PORT ?? config.port ?? 4173)
server.listen(port, '127.0.0.1', () => {
  console.log(`LPU RTL Architecture Explorer: http://127.0.0.1:${port}`)
  console.log(`RTL source remains local: ${config.projectRoot}`)
})
