import { promises as fs } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseProject, writeSnapshot } from './rtl-parser.mjs'
import { attachArchitectureModel, loadArchitectureRules } from './architecture-model.mjs'
import { loadPhysicalArchitectureRules } from './physical-architecture-model.mjs'

const appRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const command = process.argv[2] ?? 'scan'

if (command !== 'scan') {
  console.error(`Unknown command: ${command}`)
  process.exitCode = 2
} else {
  const configPath = path.join(appRoot, 'config.json')
  const config = JSON.parse(await fs.readFile(configPath, 'utf8'))
  const parsedSnapshot = await parseProject(config, (progress) => {
    if (progress.phase === 'parse' && progress.completed % 10 !== 0) return
    console.log(`[${progress.phase}] ${progress.completed}/${progress.total} ${progress.message}`)
  })
  const architectureRules = await loadArchitectureRules(path.join(appRoot, 'data', 'architecture-rules.json'))
  const physicalArchitectureRules = await loadPhysicalArchitectureRules(path.join(appRoot, 'data', 'physical-architecture-rules.json'))
  const snapshot = attachArchitectureModel(parsedSnapshot, architectureRules, physicalArchitectureRules)
  const outputPath = path.join(appRoot, 'data', 'architecture-snapshot.json')
  const configurationOverviewPath = path.join(appRoot, 'data', 'configuration-overview.json')
  await Promise.all([
    writeSnapshot(snapshot, outputPath),
    fs.writeFile(configurationOverviewPath, `${JSON.stringify(snapshot.configurationOverview, null, 2)}\n`, 'utf8'),
  ])
  console.log(JSON.stringify({ outputPath, configurationOverviewPath, summary: snapshot.summary, warnings: snapshot.warnings.length }, null, 2))
}
