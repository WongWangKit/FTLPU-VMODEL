import test from 'node:test'
import assert from 'node:assert/strict'
import { promises as fs } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const read = (file) => fs.readFile(path.join(root, file), 'utf8')

test('VXM functional block uses the dedicated interactive explorer', async () => {
  const [detail, source, styles] = await Promise.all([
    read('src/components/FunctionalBlockDetail.tsx'),
    read('src/components/VxmFunctionalExplorer.tsx'),
    read('src/styles.css'),
  ])
  assert.match(detail, /import VxmFunctionalExplorer/)
  assert.match(detail, /block\.kind === 'vxm' \? <VxmFunctionalExplorer/)
  assert.match(detail, /block\.kind === 'vxm'.*custom-explorer-scroll/)
  assert.match(source, /LOCAL RTL · CURRENT WORKSPACE/)
  assert.match(styles, /\.vxm-explorer/)
})

test('VXM explorer exposes the required hierarchy and five cycle-driven demonstrations', async () => {
  const source = await read('src/components/VxmFunctionalExplorer.tsx')
  for (const view of ['SLICE OVERVIEW', 'CONTROL WAVE', '16×8 TILE', 'LANE / CHAIN', 'STREAM FORMAT', 'ALU', 'LUT SRAM', 'STREAM BRIDGE']) assert.match(source, new RegExp(view.replace(/[×/]/g, '\\$&')))
  for (const marker of ['flow_direction=', 'useAnimationClock(5)', '[2, 4, 8]', '{length}-STAGE CHAIN', "format === 'FP32' ? 6", 'TAGGED RESPONSE', 'mode-${mode}']) assert.match(source, new RegExp(marker.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
  assert.match(source, /<AnimationControls/)
})

test('VXM structural counts, formats, placement, LUT widths and boundaries stay explicit', async () => {
  const [source, configuration] = await Promise.all([
    read('src/components/VxmFunctionalExplorer.tsx'),
    read('src/components/ConfigurationOverview.tsx'),
  ])
  for (const fact of ['4 × 16 × 8 = 512', 'Q112–119', 'Q120 · 15 bit', 'Q121–127 inactive', 'Stage 1 / 5 / 9 / 13', 'Stage 3 / 7 / 11 / 15', "canonical 6'b100110 (0x26)", '32 Streams / direction']) assert.match(source, new RegExp(fact.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
  for (const width of ['26 bit × 64', '32 bit × 64', '50 bit × 64']) assert.match(configuration, new RegExp(width.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
  assert.match(source, /RTL IMPLEMENTED \/ INTEGRATION PENDING/)
  assert.match(source, /Slice Interface Available \/ Top-level Tie-off/)
  assert.match(source, /READ_BITS_8 unsupported/)
  assert.match(source, /active_width not interpreted as lane gating/)
})

test('VXM Tile is a real 16 by 8 clickable array and LUT is 4 by 4 by 8', async () => {
  const source = await read('src/components/VxmFunctionalExplorer.tsx')
  assert.match(source, /Array\.from\(\{ length: 8 \}/)
  assert.match(source, /Array\.from\(\{ length: 16 \}/)
  assert.match(source, /lanes\.map\(\(lane\).*stages\.map/)
  assert.match(source, /tiles\.map\(\(tileId\).*lanes\.flatMap/)
  assert.match(source, /4 Tiles × 4 Functions × 8 Lanes = 128 SRAMs/)
  assert.match(source, /64 entries/)
})
