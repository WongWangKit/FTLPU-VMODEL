import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'

const snapshot = JSON.parse(await readFile(new URL('../public/data/architecture-snapshot.json', import.meta.url), 'utf8'))
const configuration = snapshot.configurationOverview

test('public snapshot maps SXM Program/ROW to both native Hemisphere instances', () => {
  const sxmSummary = configuration.summary.find((item) => item.id === 'sxm')
  assert.equal(sxmSummary?.total, 2)
  assert.equal(sxmSummary?.availability, 'Program + ROW integrated')
  assert.equal(sxmSummary?.status, 'rtl-confirmed')

  const frontend = configuration.frontends.find((item) => item.id === 'sxm')
  assert.equal(frontend?.instanceCount, 2)
  assert.deepEqual(frontend?.variants[0]?.stages.map((stage) => stage.id), ['sxm-program-native', 'sxm-native-calendar', 'sxm-native-row'])
  assert.equal(configuration.programLoad.endpointBoundaries.find((item) => item.id === 'sxm')?.boundaryStatus, 'INTEGRATED')

  for (const hemisphere of ['east', 'west']) {
    const block = snapshot.physicalArchitecture.blocks.find((item) => item.id === `physical:${hemisphere}:sxm`)
    assert.equal(block?.rtlMappings[0]?.moduleName, 'lpu_sxm_native_subsystem')
    assert.equal(block?.rtlMappings[0]?.cardinality, 1)
  }
})
