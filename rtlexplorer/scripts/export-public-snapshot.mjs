import { promises as fs } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url))
const appRoot = path.resolve(scriptDirectory, '..')
const dataDirectory = path.join(appRoot, 'data')
const publicDataDirectory = path.join(appRoot, 'public', 'data')
const snapshotPath = path.join(dataDirectory, 'architecture-snapshot.json')
const configurationOverviewPath = path.join(dataDirectory, 'configuration-overview.json')
const outputPath = path.join(publicDataDirectory, 'architecture-snapshot.json')

const snapshot = JSON.parse(await fs.readFile(snapshotPath, 'utf8'))
let configurationOverview = snapshot.configurationOverview

try {
  configurationOverview = JSON.parse(await fs.readFile(configurationOverviewPath, 'utf8'))
} catch {
  // Older snapshots already embed configurationOverview.
}

const rtlRoot = snapshot.project?.projectRoot
const replacementRoots = [rtlRoot, appRoot].filter(Boolean)

function replaceLocalRoots(value) {
  let result = value
  for (const root of replacementRoots) {
    result = result.replaceAll(root, root === rtlRoot ? 'local-rtl-snapshot' : 'rtl-explorer')
  }
  return result
}

function sanitize(value) {
  if (Array.isArray(value)) return value.map(sanitize)
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, nested]) => [key, sanitize(nested)]))
  }
  return typeof value === 'string' ? replaceLocalRoots(value) : value
}

const publicSnapshot = sanitize({ ...snapshot, configurationOverview })
publicSnapshot.project = {
  ...publicSnapshot.project,
  projectRoot: 'local-rtl-snapshot',
  git: publicSnapshot.project?.git
    ? { available: publicSnapshot.project.git.available, head: publicSnapshot.project.git.head }
    : { available: false },
}
publicSnapshot.configuration = {
  ...publicSnapshot.configuration,
  veribleExecutable: 'verible-verilog-syntax',
}

if (publicSnapshot.configurationOverview?.project) {
  publicSnapshot.configurationOverview.project = {
    ...publicSnapshot.configurationOverview.project,
    projectRoot: 'local-rtl-snapshot',
  }
}

const serialized = `${JSON.stringify(publicSnapshot)}\n`
const forbiddenPatterns = [/[A-Za-z]:\\Users\\/i, /D:\\LPU\\/i, /BEGIN [A-Z ]*PRIVATE KEY/i]
for (const pattern of forbiddenPatterns) {
  if (pattern.test(serialized)) throw new Error(`Public snapshot still contains forbidden local or secret material: ${pattern}`)
}

await fs.mkdir(publicDataDirectory, { recursive: true })
await fs.writeFile(outputPath, serialized, 'utf8')
console.log(`Public snapshot written: ${outputPath} (${Buffer.byteLength(serialized)} bytes)`)
