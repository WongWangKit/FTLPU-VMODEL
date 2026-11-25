import type { RawConnection } from '../types'

export interface SignalSemanticPresentation {
  displayName: string
  objectLabel: string
  rtlName: string
  meaning: string
  semanticMeaning: string
  groupAlias: string
  matchedRule: boolean
}

interface SemanticRule {
  pattern: RegExp
  suffix: string | ((name: string) => string)
  meaning: (objectLabel: string) => string
  groupAlias: string
}

const directionSuffix = /_(?:i|o|w|q)$/i

const channelAliases: Array<{ pattern: RegExp; label: string }> = [
  { pattern: /^(?:command_write|program_cmd_write)/, label: 'Command Descriptor Write' },
  { pattern: /^(?:loader_transaction|ctrl_load_txn)/, label: 'Program Load Transaction' },
  { pattern: /^(?:instruction_dma_command|dma_cmd|ctrl_dma_cmd|ddr_read_req|program_ddr_read_req)/, label: 'Program DDR Read Request' },
  { pattern: /^config_enqueue/, label: 'Image Context Enqueue' },
  { pattern: /^config_dequeue/, label: 'Image Context Dequeue' },
  { pattern: /^(?:dma_rsp|dma_response|response|ddr_read_rsp|program_ddr_read_rsp)/, label: 'External Program Response' },
  { pattern: /^(?:reassembler_word|reasm_rsp)/, label: 'Reassembly Response' },
  { pattern: /^word_enqueue/, label: 'Reassembled Word FIFO Enqueue' },
  { pattern: /^(?:word_dequeue|load_word)/, label: 'Reassembled Word FIFO Dequeue' },
  { pattern: /^prime_enqueue/, label: 'Deferred PRIME Enqueue' },
  { pattern: /^prime_dequeue/, label: 'Deferred PRIME Dequeue' },
  { pattern: /^(?:distributor_input|input|load_distribute|load_record|distributor_record|endpoint_load)/, label: 'Distributor Input' },
  { pattern: /^(?:distributor_west|west_load|west)/, label: 'West Program Branch' },
  { pattern: /^(?:distributor_east|east_load|east)/, label: 'East Program Branch' },
  { pattern: /^(?:west_commit|cluster_commit.*west)/, label: 'West Program Commit' },
  { pattern: /^(?:east_commit|cluster_commit.*east)/, label: 'East Program Commit' },
  { pattern: /^fetch_word/, label: 'Fetched Macro Word' },
  { pattern: /^word_fifo/, label: 'Macro Word FIFO' },
  { pattern: /^context_fifo/, label: 'Macro Context FIFO' },
  { pattern: /^scheduler_issue/, label: 'Scheduler Issue' },
  { pattern: /^fifo_dequeue/, label: 'Queue FIFO Dequeue' },
  { pattern: /^fifo_enqueue/, label: 'Queue FIFO Enqueue' },
  { pattern: /^local_mem_issue/, label: 'MEM Local Issue' },
]

const semanticRules: SemanticRule[] = [
  { pattern: /(?:^|_)valid$/, suffix: 'Valid', meaning: (object) => `${object}：发送方声明当前拍的数据、请求或控制记录有效。`, groupAlias: 'Handshake' },
  { pattern: /(?:^|_)ready$/, suffix: 'Ready', meaning: (object) => `${object}：接收方声明当前拍可以接受该传输；拉低时形成背压。`, groupAlias: 'Handshake' },
  { pattern: /(?:^|_)(?:strb|strobe)$/, suffix: 'Segment Strobe / Mask', meaning: (object) => `${object}：标识 128-bit Program Word 中有效的 32-bit 段。`, groupAlias: 'Word Strobe / Mask' },
  { pattern: /(?:^|_)(?:keep|byte_mask)$/, suffix: 'Byte-valid Mask', meaning: (object) => `${object}：标识当前总线拍中哪些返回字节有效。`, groupAlias: 'Word Strobe / Mask' },
  { pattern: /(?:^|_)last$/, suffix: 'Last', meaning: (object) => `${object}：标识当前事务、图像或 Program Word 序列的最后一拍。`, groupAlias: 'Program Word Payload' },
  { pattern: /(?:^|_)scope$/, suffix: 'Scope', meaning: (object) => `${object}：独立选择 EAST、WEST 或 BOTH；BOTH 在 Distributor 内展开为两个端点握手。`, groupAlias: 'Scope / 13-bit Destination / iMEM Address' },
  { pattern: /(?:^|_)destination$/, suffix: '13-bit Destination', meaning: (object) => `${object}：编码 Endpoint Hemisphere[12]、FU Kind[11:8] 与 Local Target Index[7:0]。`, groupAlias: 'Scope / 13-bit Destination / iMEM Address' },
  { pattern: /(?:^|_)(?:imem_address|imem_addr)$/, suffix: 'iMEM Address', meaning: (object) => `${object}：给出目标 FU 局部指令存储的地址。`, groupAlias: 'Scope / 13-bit Destination / iMEM Address' },
  { pattern: /(?:^|_)(?:hemisphere|target_kind|target|queue_id|queue)$/, suffix: 'Legacy Route Field', meaning: (object) => `${object}：兼容旧快照命名；当前 Program Load 主契约使用独立 Scope 与 13-bit Destination。`, groupAlias: 'Legacy Routing / Needs Review' },
  { pattern: /(?:^|_)(?:source_address|address|addr)$/, suffix: 'Address', meaning: (object) => `${object}：给出本次读取、写入或路由使用的地址。`, groupAlias: 'Address / Transfer Metadata' },
  { pattern: /(?:^|_)(?:byte_count|length)$/, suffix: 'Length', meaning: (object) => `${object}：给出本次程序读取或图像片段的字节长度。`, groupAlias: 'Address / Transfer Metadata' },
  { pattern: /(?:^|_)(?:data|payload|word_data)$/, suffix: (name) => /word/.test(name) ? 'Program Word Data' : 'Data / Payload', meaning: (object) => `${object}：承载该通道的实际数据内容。`, groupAlias: 'Program Word Payload' },
  { pattern: /(?:^|_)(?:fault|conflict)$/, suffix: (name) => /conflict/.test(name) ? 'Conflict' : 'Fault', meaning: (object) => `${object}：报告异常、冲突或协议错误状态。`, groupAlias: 'Control / Status' },
  { pattern: /(?:^|_)error$/, suffix: 'Error', meaning: (object) => `${object}：报告本次事务或提交操作的错误结果。`, groupAlias: 'Control / Status' },
  { pattern: /(?:^|_)status$/, suffix: 'Status', meaning: (object) => `${object}：返回当前操作、队列或接口状态。`, groupAlias: 'Control / Status' },
  { pattern: /(?:^|_)(?:control|opcode)$/, suffix: (name) => /control/.test(name) ? 'Program Load Control' : 'Opcode', meaning: (object) => `${object}：控制当前操作类型；Program Load Control 与 FU 指令编码属于不同语义域。`, groupAlias: 'Command / Instruction' },
  { pattern: /(?:^|_)(?:instruction|issue_instruction)$/, suffix: 'Instruction Payload', meaning: (object) => `${object}：承载送往本地队列、调度器或执行单元的指令内容。`, groupAlias: 'Command / Instruction' },
  { pattern: /(?:^|_)(?:cycle|schedule_cycle|issue_cycle)$/, suffix: 'Issue Cycle', meaning: (object) => `${object}：给出指令计划进入执行阶段的周期。`, groupAlias: 'Schedule / Timing' },
  { pattern: /(?:^|_)(?:id|dma_id|response_id)$/, suffix: 'Transaction ID', meaning: (object) => `${object}：关联外部请求与返回响应。`, groupAlias: 'Address / Transfer Metadata' },
]

function humanizeRtlName(name: string) {
  const normalized = name
    .replace(/^(?:u_[a-z0-9]+_)+/i, '')
    .replace(directionSuffix, '')
    .replace(/_/g, ' ')
    .replace(/\bimem\b/gi, 'iMEM')
    .replace(/\bdma\b/gi, 'DMA')
    .replace(/\bfifo\b/gi, 'FIFO')
  return normalized.replace(/\b\w/g, (character) => character.toUpperCase())
}

function normalizeFallbackGroup(groupName?: string) {
  const lower = groupName?.trim().toLowerCase() ?? ''
  if (/handshake|valid|ready/.test(lower)) return 'Handshake'
  if (/strobe|strb|keep|mask/.test(lower)) return 'Word Strobe / Mask'
  if (/scope|destination/.test(lower)) return 'Scope / 13-bit Destination / iMEM Address'
  if (/route|target|address|queue/.test(lower)) return 'Address / Transfer Metadata'
  if (/fault|status|control|error/.test(lower)) return 'Control / Status'
  if (/instruction|command|issue/.test(lower)) return 'Command / Instruction'
  if (/data|payload|word/.test(lower)) return 'Program Word Payload'
  return groupName || 'Unclassified / Needs Review'
}

function semanticBase(identity: string, rule: SemanticRule) {
  return identity.replace(rule.pattern, '').replace(/_+$/, '')
}

function channelLabel(identity: string, rule: SemanticRule | undefined, fallbackGroup?: string) {
  const base = rule ? semanticBase(identity, rule) : identity
  const alias = channelAliases.find((item) => item.pattern.test(base) || item.pattern.test(identity))
  if (alias) return alias.label
  const fallback = fallbackGroup?.trim()
  if (fallback && !/^(handshake|valid|ready|data|payload|control|status|fault)$/i.test(fallback)) return fallback
  const readable = humanizeRtlName(base)
  return readable || 'Interface'
}

export function signalSemanticPresentation(raw: RawConnection, fallbackGroup?: string): SignalSemanticPresentation {
  const rtlName = raw.signalName
  const identity = raw.signalName.toLowerCase().replace(directionSuffix, '')
  const rule = semanticRules.find((item) => item.pattern.test(identity))
  const objectLabel = channelLabel(identity, rule, fallbackGroup ?? raw.signalGroup?.name)
  if (!rule) {
    const meaning = '当前没有可确认的共享语义规则；请结合 RTL 原名、端点和源码位置查看。'
    return {
      displayName: humanizeRtlName(rtlName),
      objectLabel,
      rtlName,
      meaning,
      semanticMeaning: meaning,
      groupAlias: normalizeFallbackGroup(fallbackGroup ?? raw.signalGroup?.name),
      matchedRule: false,
    }
  }
  const suffix = typeof rule.suffix === 'function' ? rule.suffix(identity) : rule.suffix
  const meaning = rule.meaning(objectLabel)
  return {
    displayName: `${objectLabel} ${suffix}`.replace(/\s+/g, ' ').trim(),
    objectLabel,
    rtlName,
    meaning,
    semanticMeaning: meaning,
    groupAlias: rule.groupAlias,
    matchedRule: true,
  }
}

export function signalGroupOrder(name: string) {
  const index = ['Handshake', 'Program Word Payload', 'Word Strobe / Mask', 'Scope / 13-bit Destination / iMEM Address', 'Address / Transfer Metadata', 'Command / Instruction', 'Schedule / Timing', 'Control / Status', 'Legacy Routing / Needs Review', 'Unclassified / Needs Review'].indexOf(name)
  return index < 0 ? 99 : index
}
