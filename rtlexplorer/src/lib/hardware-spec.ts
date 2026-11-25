import type { ArchitectureDrillNode } from '../types'

export interface HardwareQuickSpec {
  kind: 'storage' | 'register-file' | 'memory-bank' | 'tile-array' | 'lane-array' | 'decoder' | 'router' | 'module'
  eyebrow: string
  primaryLabel: string
  primaryValue: string
  secondary: Array<{ label: string; value: string }>
  needsReview: boolean
}

function value(node: ArchitectureDrillNode, pattern: RegExp) {
  const item = node.parameterRefs.find((parameter) => pattern.test(parameter.name))
  if (!item) return null
  return {
    text: item.value === null ? item.expression || 'Needs Review' : String(item.value),
    numeric: item.value,
    needsReview: item.value === null || item.evidenceStatus === 'needs-review',
  }
}

function firstValue(node: ArchitectureDrillNode, patterns: RegExp[]) {
  for (const pattern of patterns) {
    const result = value(node, pattern)
    if (result) return result
  }
  return null
}

function dimension(text: string | null, unit: string) {
  return text ? `${text}${/^\d+$/.test(text) ? ` ${unit}` : ''}` : 'Needs Review'
}

export function buildHardwareQuickSpec(node: ArchitectureDrillNode): HardwareQuickSpec {
  const identity = `${node.nodeType} ${node.displayName}`.toLowerCase()
  const storage = /(fifo|queue|buffer|storage|store|reservoir|elastic|instruction-memory|imem)/.test(identity)
  const registerFile = /(register[- ]?file|register-array)/.test(identity)
  const memoryBank = /(memory bank|bank-control|bank array)/.test(identity)
  const tileArray = /(tile-array|tile row array|compute-array|execution-array|dot bank array)/.test(identity)
  const laneArray = /(lane-array|vector-lane)/.test(identity)
  const decoder = /(decoder|route-decode|macro-decode)/.test(identity)
  const router = /(router|routing|distributor)/.test(identity)
  const width = firstValue(node, [/(?:DATA|PAYLOAD|ENTRY|INSTRUCTION|WORD|REGISTER|BANK)_WIDTH/i, /^WIDTH$/i])
  const depth = firstValue(node, [/DEPTH/i, /ENTRIES/i])
  const count = firstValue(node, [/(?:REGISTER|BANK|TILE|LANE|PORT|STREAM|ACTIVE_COLUMNS|GROUPS)_COUNT/i, /^(?:REGISTERS|BANKS|TILES|LANES|STREAMS|ACTIVE_COLUMNS|GROUPS|ROWS|COMMAND_DEPTH)$/i])
  const needs = (...items: Array<{ needsReview: boolean } | null>) => items.some((item) => !item || item.needsReview)

  if (registerFile) {
    const registerCount = firstValue(node, [/COMMAND_DEPTH/i, /REGISTER_COUNT/i, /DEPTH/i])
    return {
      kind: 'register-file', eyebrow: 'REGISTER STORAGE', primaryLabel: 'REGISTER COUNT × WIDTH',
      primaryValue: `${dimension(registerCount?.text ?? null, 'registers')} × ${dimension(width?.text ?? null, 'bit')}`,
      secondary: [], needsReview: needs(registerCount, width),
    }
  }
  if (storage) {
    const secondary: HardwareQuickSpec['secondary'] = []
    if (width?.numeric !== null && width?.numeric !== undefined && depth?.numeric !== null && depth?.numeric !== undefined) secondary.push({ label: 'CAPACITY', value: `${width.numeric * depth.numeric} bit` })
    secondary.push({ label: 'TYPE', value: node.nodeType.replaceAll('-', ' ') })
    return {
      kind: 'storage', eyebrow: /(fifo|queue)/.test(identity) ? 'FIFO / QUEUE SPECIFICATION' : 'BUFFER SPECIFICATION',
      primaryLabel: 'WIDTH × DEPTH',
      primaryValue: `${dimension(width?.text ?? null, 'bit')} × ${dimension(depth?.text ?? null, 'entries')}`,
      secondary, needsReview: needs(width, depth),
    }
  }
  if (memoryBank) {
    const banks = firstValue(node, [/BANK_COUNT/i, /^BANKS$/i])
    return {
      kind: 'memory-bank', eyebrow: 'MEMORY BANK SPECIFICATION', primaryLabel: 'BANKS / WIDTH / DEPTH',
      primaryValue: `${dimension(banks?.text ?? null, 'banks')} · ${dimension(width?.text ?? null, 'bit')} · ${dimension(depth?.text ?? null, 'entries')}`,
      secondary: [], needsReview: needs(banks, width, depth),
    }
  }
  if (tileArray || laneArray) {
    const tiles = firstValue(node, [/^TILES$/i, /TILE_COUNT/i, /^ROWS$/i])
    const lanes = firstValue(node, [/^LANES$/i, /LANE_COUNT/i])
    const shown = tileArray ? tiles : lanes
    return {
      kind: tileArray ? 'tile-array' : 'lane-array', eyebrow: tileArray ? 'TILE ARRAY SPECIFICATION' : 'LANE ARRAY SPECIFICATION',
      primaryLabel: tileArray ? 'TILE / ROW COUNT' : 'LANE COUNT / DATA WIDTH',
      primaryValue: tileArray ? dimension(shown?.text ?? null, 'tiles') : `${dimension(shown?.text ?? null, 'lanes')} · ${dimension(width?.text ?? null, 'bit')}`,
      secondary: count && count !== shown ? [{ label: 'RELATED DIMENSION', value: count.text }] : [], needsReview: tileArray ? needs(shown) : needs(shown, width),
    }
  }
  if (decoder) {
    const inputWidth = firstValue(node, [/(?:INPUT|INSTRUCTION|WORD)_WIDTH/i])
    const outputCount = firstValue(node, [/(?:OUTPUT|CONTROL)_COUNT/i])
    return {
      kind: 'decoder', eyebrow: 'DECODER SPECIFICATION', primaryLabel: 'INPUT WIDTH / CONTROL OUTPUTS',
      primaryValue: `${dimension(inputWidth?.text ?? null, 'bit')} · ${dimension(outputCount?.text ?? null, 'outputs')}`,
      secondary: [], needsReview: needs(inputWidth, outputCount),
    }
  }
  if (router) {
    const ports = firstValue(node, [/(?:PORT|INPUT|OUTPUT)_COUNT/i])
    return {
      kind: 'router', eyebrow: 'ROUTER SPECIFICATION', primaryLabel: 'RTL PORT COUNT',
      primaryValue: dimension(ports?.text ?? null, 'ports'), secondary: [], needsReview: needs(ports),
    }
  }
  return {
    kind: 'module', eyebrow: 'MODULE SUMMARY', primaryLabel: 'PARAMETERIZED DIMENSIONS',
    primaryValue: count?.text ?? 'Needs Review', secondary: [], needsReview: !count || count.needsReview,
  }
}
