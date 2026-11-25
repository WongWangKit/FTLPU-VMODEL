export type IsaFu = 'MEM' | 'MXM' | 'VXM' | 'SXM'
export const isaCatalogReviewedAt = '2026-11-25'
export type IsaRepository = 'VMODEL' | 'CMODEL' | 'SOFTWARE'
export type IsaStatus = 'MATCH' | 'PARTIAL' | 'NOT_IMPLEMENTED' | 'NOT_INTEGRATED' | 'UNVERIFIED'

export interface IsaEvidence {
  repo: IsaRepository
  path: string
  line: number
  symbol: string
  detail: string
}

export interface IsaField {
  name: string
  bits: string
  width: number
  signed: boolean
  meaning: string
  choices?: { value: string; label: string }[]
  evidence: IsaEvidence[]
}

export interface IsaInstruction {
  id: string
  fu: IsaFu
  name: string
  kind: string
  width: string
  opcode: string
  status: IsaStatus
  version: string
  summary: string
  path: string[]
  fields: IsaField[]
  evidence: IsaEvidence[]
  example?: { word: string; source: string; meaning: string }
  caution?: string
}

const rtl = (path: string, line: number, symbol: string, detail: string): IsaEvidence => ({ repo: 'VMODEL', path, line, symbol, detail })
const cmodel = (path: string, line: number, symbol: string, detail: string): IsaEvidence => ({ repo: 'CMODEL', path, line, symbol, detail })
const software = (path: string, line: number, symbol: string, detail: string): IsaEvidence => ({ repo: 'SOFTWARE', path, line, symbol, detail })
const memDecode = rtl('rtl/core/lpu_isa_decode.sv', 11, 'lpu_mem_instruction_decode', 'MEM64 位域和合法性判断')
const memPkg = rtl('rtl/core/lpu_pkg.sv', 188, 'MEM_READ / MEM_WRITE', 'MEM opcode 枚举')
const memCodec = cmodel('include/ftlpu/core/instruction_codec.hpp', 210, 'encode_mem_instruction', 'CModel 原生 MEM 编码')
const memSoftware = software('compiler/src/Target/CommandBinary.cpp', 852, 'encode_mem_instruction', '编译器调用 MEM 编码器')
const memTb = rtl('sim/tb/lpu_mem_isa_compat_tb.sv', 138, 'make_instruction', 'Testbench 以字段参数构造真实 READ / WRITE 输入；页面字值由该函数计算')
const memField = (name: string, bits: string, width: number, meaning: string, signed = false): IsaField => {
  const lineByName: Record<string, [number, number]> = {
    '高位保留': [17, 252], preserve_stream: [16, 241], '保留': [18, 252],
    address: [15, 240], map_stream: [14, 239], stream: [13, 238], opcode: [12, 237],
  }
  const [rtlLine, cmodelLine] = lineByName[name]
  return { name, bits, width, signed, meaning, evidence: [
    rtl('rtl/core/lpu_isa_decode.sv', rtlLine, 'lpu_mem_instruction_decode', `${name} 在 RTL 中的位段与检查`),
    cmodel('include/ftlpu/core/instruction_codec.hpp', cmodelLine, 'encode_mem_instruction', `${name} 在 CModel 编码中的对应位置`),
  ] }
}
const memFields: IsaField[] = [
  memField('高位保留', '[63:32]', 32, '必须为 0'),
  memField('preserve_stream', '[31]', 1, 'WRITE 可保留流；READ 必须为 0'),
  memField('保留', '[30:28]', 3, '必须为 0'),
  memField('address', '[27:15]', 13, 'MEM SRAM 行地址，单位：Row（CModel 编码器按 SRAM depth rows 限幅）'),
  memField('map_stream', '[14:9]', 6, '映射流编号，单位：Stream'),
  memField('stream', '[8:3]', 6, '数据流编号，单位：Stream'),
  memField('opcode', '[2:0]', 3, 'READ=0、WRITE=1、GATHER=3、SCATTER=4'),
]
const mxmPkg = rtl('rtl/mxm/icu/lpu_mxm_isa_pkg.sv', 23, 'lpu_mxm_isa_pkg', '五个队列分别定义原生 payload，队列身份决定操作')
const mxmMacro = rtl('rtl/mxm/icu/lpu_mxm_macro_decoder_core.sv', 208, 'lpu_mxm_macro_decoder_core', '128-bit packed-v1 Control 合法性')
const mxmField = (name: string, bits: string, width: number, meaning: string, evidence = mxmPkg): IsaField => ({ name, bits, width, signed: false, meaning, evidence: [evidence] })
const mxmChoiceField = (name: string, bits: string, width: number, meaning: string, choices: IsaField['choices'], evidence = mxmPkg): IsaField => ({
  ...mxmField(name, bits, width, meaning, evidence), choices,
})
const vxmPkg = rtl('rtl/core/lpu_pkg.sv', 54, 'VXM_Q*_INSTRUCTION_WIDTH', 'Q0–Q7 原生宽度依队列变化')
const vxmDecode = rtl('rtl/vxm/lpu_vxm_local_decoder.sv', 61, 'lpu_vxm_local_decoder', '依 LOCAL_QUEUE 解码 opcode 与 operand source')
const vxmField = (name: string, bits: string, width: number, meaning: string): IsaField => ({ name, bits, width, signed: false, meaning, evidence: [vxmDecode] })
const sxmNative = rtl('rtl/sxm/lpu_sxm_native_subsystem.sv', 4, 'lpu_sxm_native_subsystem', '正式 Program 入口；Target 5/6 分别写入 CTRL/EXEC 事件表')
const sxmCalendar = rtl('rtl/sxm/lpu_sxm_native_issue_calendar.sv', 1, 'lpu_sxm_native_issue_calendar', '每个事件依次写入 128-bit payload 和 64-bit timing word')
const sxmBatch = rtl('rtl/sxm/lpu_sxm_subsystem.sv', 12, 'lpu_sxm_subsystem', '独立 typed batch WriteTap 路径，不是正式 Program 入口')
const sxmField = (name: string, bits: string, width: number, meaning: string, line: number): IsaField => ({ name, bits, width, signed: false, meaning, evidence: [rtl('rtl/sxm/lpu_sxm_native_subsystem.sv', line, 'lpu_sxm_native_subsystem', `${name} 原生位段接线`)] })
const sxmCmodel = cmodel('include/ftlpu/sxm/instruction.hpp', 11, 'SxmInstruction', 'CModel typed 指令枚举')
const sxmSoftware = software('runtime/src/runtime/macro_bitstream.cpp', 741, 'encode_sxm_macro_bitstream', 'Software 侧 SXM Macro 编码入口；正式 RTL 路径尚未对齐')

export const isaInstructions: IsaInstruction[] = [
  ...([['READ', '0', '从 MEM 向数据流读取；READ 禁止 preserve_stream。'], ['WRITE', '1', '把数据流写入 MEM；可使用 preserve_stream。'], ['GATHER', '3', 'RTL 识别该 opcode，但 implemented_o=0。'], ['SCATTER', '4', 'RTL 识别该 opcode，但 implemented_o=0。']] as const).map(([name, opcode, summary]) => ({
    id: `mem-${name.toLowerCase()}`, fu: 'MEM' as const, name, kind: 'Native MEM64', width: '64 bit（有效低 32 bit）', opcode, status: (Number(opcode) < 2 ? 'PARTIAL' : 'NOT_IMPLEMENTED') as IsaStatus, version: 'CURRENT · local workspace', summary,
    path: ['MEM64 instruction', 'lpu_mem_instruction_decode', 'READ / WRITE issue', 'MEM execution'], fields: memFields, evidence: [memPkg, memDecode, memCodec, memSoftware, name === 'READ' ? rtl('sim/tb/lpu_mem_isa_compat_tb.sv', 155, 'make_instruction', 'READ 字段构造实例') : memTb],
    example: name === 'READ' ? { word: '0x0000000000028018', source: 'sim/tb/lpu_mem_isa_compat_tb.sv:155', meaning: 'READ · stream=3 · address=5 Row' } : name === 'WRITE' ? { word: '0x000000000002a639', source: 'sim/tb/lpu_mem_isa_compat_tb.sv:138', meaning: 'WRITE · stream=7 · map_stream=19 · address=5 Row' } : undefined,
    caution: Number(opcode) < 2 ? '三端均有编码入口；系统级兼容未由本页测试证明。READ1D/2D/3D 属于更高层控制或展开，不能直接等同该 opcode。' : 'RTL implemented_o=0；CModel 对象存在不代表硬件可执行。',
  })),
  { id: 'mxm-load', fu: 'MXM', name: 'LOAD', kind: 'Frontend queue payload', width: '2 bit', opcode: '由 LOAD 队列决定', status: 'PARTIAL', version: 'CURRENT · local workspace', summary: '选择权重缓冲和矩阵/列装载模式；一次 launch 对应一个 beat。', path: ['MXM LOAD queue', 'Macro/native frontend', 'load controller'], fields: [
    mxmChoiceField('weight_buffer', '[1]', 1, '选择写入的权重双缓冲', [{ value: '0', label: '权重 Buffer 0' }, { value: '1', label: '权重 Buffer 1' }]),
    mxmChoiceField('column_mode', '[0]', 1, '装载模式', [{ value: '0', label: 'MATRIX' }, { value: '1', label: 'COLUMN' }]),
  ], evidence: [mxmPkg, mxmMacro] },
  { id: 'mxm-compute', fu: 'MXM', name: 'COMPUTE', kind: 'Frontend queue payload', width: '7 bit', opcode: '由 COMPUTE 队列决定', status: 'PARTIAL', version: 'CURRENT · local workspace', summary: '选择 activation stream 与权重缓冲，发射一次计算 beat。', path: ['MXM COMPUTE queue', 'Macro/native frontend', 'compute issue', 'SC array'], fields: [
    mxmField('activation_stream', '[6:1]', 6, '激活流编号，单位：Stream'),
    mxmChoiceField('weight_buffer', '[0]', 1, '选择计算时读取的权重双缓冲', [{ value: '0', label: '权重 Buffer 0' }, { value: '1', label: '权重 Buffer 1' }]),
  ], evidence: [mxmPkg, mxmMacro] },
  { id: 'mxm-dequant', fu: 'MXM', name: 'DEQUANT', kind: 'Frontend queue payload', width: '1 bit', opcode: '由 DEQUANT 队列决定', status: 'PARTIAL', version: 'CURRENT · local workspace', summary: '选择反量化读取的参数 Bank；独立于权重缓冲选择。', path: ['MXM DEQUANT queue', 'Macro/native frontend', 'dequant issue'], fields: [
    mxmChoiceField('param_buffer', '[0]', 1, '选择反量化读取的参数 Bank（scale / zero）', [{ value: '0', label: '参数 Bank 0' }, { value: '1', label: '参数 Bank 1' }], rtl('rtl/mxm/lpu_mxm_weight_dequant_pipe.sv', 154, 'param_scale_q / param_zero_q', '以 param_buffer_i 索引参数 Bank 读取 scale 与 zero')),
  ], evidence: [mxmPkg, mxmMacro] },
  { id: 'mxm-param', fu: 'MXM', name: 'PARAM LOAD', kind: 'Frontend queue payload', width: '1 bit', opcode: '由 PARAM LOAD 队列决定', status: 'PARTIAL', version: 'CURRENT · local workspace', summary: '选择写入参数的 Bank；独立于权重缓冲选择。', path: ['MXM PARAM LOAD queue', 'Macro/native frontend', 'parameter load'], fields: [
    mxmChoiceField('param_buffer', '[0]', 1, '选择装载参数写入的 Bank（scale / zero）', [{ value: '0', label: '参数 Bank 0' }, { value: '1', label: '参数 Bank 1' }], rtl('rtl/mxm/lpu_mxm_weight_dequant_pipe.sv', 127, 'param_scale_q / param_zero_q', '以 param_write_buffer_i 索引参数 Bank 写入 scale 与 zero')),
  ], evidence: [mxmPkg, mxmMacro] },
  { id: 'mxm-backend', fu: 'MXM', name: 'BACKEND', kind: 'Backend queue payload', width: '3 + ceil(log2(ACCUMULATOR_DEPTH)) bit；默认 13 bit', opcode: 'DIRECT_OUT=0 / STORE=1 / ACC_STORE=2 / ACC_OUT=3', status: 'PARTIAL', version: 'CURRENT · local workspace', summary: '选择累加器地址、存储/输出操作和输出格式。输出格式为 FP32 或 BF16，不是 FP16。', path: ['MXM BACKEND queue', 'backend decode', 'accumulator / output'], fields: [
    mxmChoiceField('out_bf16', '[12]', 1, '输出格式位；仅 DIRECT_OUT / ACC_OUT 可置 1，STORE / ACC_STORE 必须为 0', [{ value: '0', label: '输出 FP32' }, { value: '1', label: '输出 BF16' }], rtl('rtl/mxm/lpu_mxm_backend_isa_pkg.sv', 20, 'backend_fields_legal', 'BF16 只允许输出类 opcode；输出流水线按 bf16_i 转换')),
    mxmChoiceField('address', '[11:2]', 10, '默认深度 1024 的累加器地址；最低位选择 Bank', [{ value: 'address[0]=0', label: '累加器 Bank 0' }, { value: 'address[0]=1', label: '累加器 Bank 1' }], rtl('rtl/mxm/lpu_mxm_backend_column.sv', 85, 'g_bank', '地址最低位选择 Bank；其余位作为 Bank 行地址')),
    mxmChoiceField('opcode', '[1:0]', 2, 'Backend 操作码', [{ value: '0', label: 'DIRECT_OUT：当前结果直接输出' }, { value: '1', label: 'STORE：当前结果写入 Bank' }, { value: '2', label: 'ACC_STORE：与 Bank 数据相加后写回' }, { value: '3', label: 'ACC_OUT：与 Bank 数据相加后输出' }], rtl('rtl/mxm/lpu_mxm_backend_isa_pkg.sv', 4, 'DIRECT_OUT / STORE / ACC_STORE / ACC_OUT', '2-bit Backend opcode 枚举')),
  ], evidence: [rtl('rtl/mxm/lpu_mxm_backend_isa_pkg.sv', 3, 'lpu_mxm_backend_isa_pkg', 'Backend 编码和合法性'), mxmPkg], caution: '图中位号只对应默认 ACCUMULATOR_DEPTH=1024；参数改变后 address/out_bf16 位号随之改变。' },
  { id: 'vxm-q0', fu: 'VXM', name: 'Q0', kind: 'Local queue word', width: '6 bit', opcode: '[2:0]；0–5 基础运算，6/7 依 stage 限制', status: 'NOT_INTEGRATED', version: 'CURRENT · standalone RTL', summary: '链首或中间 stage 的局部运算；输入来源由链位置解释。', path: ['VXM local queue Q0', 'local decoder', 'stage control'], fields: [vxmField('rhs', '[5]', 1, '右操作数来源位，链首与中间 stage 解释不同'), vxmField('lhs', '[4:3]', 2, '左操作数来源码'), vxmField('opcode', '[2:0]', 3, '局部运算码')], evidence: [vxmPkg, vxmDecode], caution: '顶层当前未接入本地 VXM issue；本页展示独立 RTL 译码格式。' },
  { id: 'vxm-odd', fu: 'VXM', name: 'Q1 / Q5', kind: 'Local queue word', width: '5 bit', opcode: '[2:0]', status: 'NOT_INTEGRATED', version: 'CURRENT · standalone RTL', summary: '奇数局部队列格式，保留位由队列位置检查。', path: ['VXM Q1/Q5 queue', 'local decoder', 'stage control'], fields: [vxmField('rhs', '[4:3]', 2, '右操作数来源码'), vxmField('opcode', '[2:0]', 3, '局部运算码')], evidence: [vxmPkg, vxmDecode] },
  { id: 'vxm-even', fu: 'VXM', name: 'Q2 / Q4 / Q6', kind: 'Local queue word', width: '7 bit', opcode: '[2:0]', status: 'NOT_INTEGRATED', version: 'CURRENT · standalone RTL', summary: '可作为链首的局部 stage，含左右操作数来源码。', path: ['VXM Q2/Q4/Q6 queue', 'local decoder', 'stage control'], fields: [vxmField('rhs', '[6:5]', 2, '右操作数来源码'), vxmField('lhs', '[4:3]', 2, '左操作数来源码；中间 stage 必须为 0'), vxmField('opcode', '[2:0]', 3, '局部运算码')], evidence: [vxmPkg, vxmDecode] },
  { id: 'vxm-log', fu: 'VXM', name: 'Q3 / Q7', kind: 'Local queue word', width: '6 bit', opcode: '[2:0] + bit[5] LOG 扩展', status: 'NOT_INTEGRATED', version: 'CURRENT · standalone RTL', summary: '奇数 stage 可用特定 LOG 扩展码。', path: ['VXM Q3/Q7 queue', 'local decoder', 'stage control'], fields: [vxmField('LOG extension', '[5]', 1, '仅特定 6-bit LOG 编码合法'), vxmField('rhs', '[4:3]', 2, '右操作数来源码'), vxmField('opcode', '[2:0]', 3, '局部运算码')], evidence: [vxmPkg, vxmDecode] },
  { id: 'vxm-global', fu: 'VXM', name: 'GLOBAL CONFIG', kind: 'Global queue configuration', width: '15 bit', opcode: '配置字；非局部 ALU opcode', status: 'NOT_INTEGRATED', version: 'CURRENT · standalone RTL', summary: '为局部队列配置数据流方向、链长度、有效宽度及左右操作数格式。', path: ['VXM global config queue', 'shadow write / safe commit', 'row distribution', 'tile execution'], fields: [
    vxmField('flow_direction', '[14]', 1, '数据流方向'), vxmField('chain_length', '[13:12]', 2, '链长度编码'), vxmField('active_width', '[11:10]', 2, '有效宽度编码'), vxmField('compute_dtype', '[9:8]', 2, '计算数据类型'), vxmField('lhs_read_bits', '[7:6]', 2, '左操作数读取宽度编码'), vxmField('lhs_dtype', '[5:4]', 2, '左操作数数据类型'), vxmField('rhs_read_bits', '[3:2]', 2, '右操作数读取宽度编码'), vxmField('rhs_dtype', '[1:0]', 2, '右操作数数据类型'),
  ].map((field) => ({ ...field, evidence: [rtl('rtl/core/lpu_pkg.sv', 81, 'vxm_global_config_t', '15-bit packed struct；声明顺序决定字段位置'), rtl('rtl/vxm/lpu_vxm_global_config.sv', 26, 'lpu_vxm_global_config', '配置写入 shadow，safe 时 commit 生效')] })), evidence: [rtl('rtl/core/lpu_pkg.sv', 43, 'VXM_GLOBAL_CONFIG_WIDTH', '全局配置字宽 15 bit'), rtl('rtl/vxm/lpu_vxm_global_config.sv', 26, 'lpu_vxm_global_config', 'write/commit 逻辑')], caution: '此配置字不是局部队列操作码。全局控制器可独立核查，但顶层 local/global issue 当前没有正式接通。' },
  { id: 'sxm-native-ctrl', fu: 'SXM', name: 'NATIVE CTRL', kind: 'Program Target 5 · calendar event', width: '128-bit payload + 64-bit timing', opcode: 'Target Kind 5 · local index 0', status: 'PARTIAL', version: 'CURRENT · native RTL', summary: 'R6 Outer Local 为每个 Hemisphere 的 CTRL 表装载事件；到指定绝对周期发射控制字。', path: ['Program Target 5', 'R6 Outer Local', 'CTRL calendar', 'ROW core'], fields: [
    sxmField('ctrl_data', 'payload[127:0]', 128, '传给 ROW 核心的控制数据', 148),
    sxmField('ctrl_op', 'timing[33:32]', 2, '控制操作码，来自 timing word auxiliary 低 2 位', 145),
    sxmField('ctrl_ctx', 'timing[34]', 1, '控制上下文选择', 146),
    sxmField('ctrl_index', 'timing[37:35]', 3, '控制索引', 147),
    { name: 'schedule_cycle', bits: 'timing[31:0]', width: 32, signed: false, meaning: '事件发射的绝对周期；错过截止周期会报错，不会重试', evidence: [sxmCalendar] },
  ], evidence: [sxmNative, sxmCalendar, rtl('rtl/program_load/lpu_program_load_pkg.sv', 56, 'PROGRAM_TARGET_SXM_TRANSPOSE', 'Target Kind 5')], caution: '当前状态只表示正式 RTL 路径已接入。CMODEL main 尚未实现同一 ROW Program，三端语义未完成联合对齐；SXM QCTL 也尚未接入。' },
  { id: 'sxm-native-exec', fu: 'SXM', name: 'NATIVE EXEC', kind: 'Program Target 6 · calendar event', width: '128-bit payload + 64-bit timing', opcode: 'Target Kind 6 · local index 0', status: 'PARTIAL', version: 'CURRENT · native RTL', summary: 'EXEC 表按绝对周期向 ROW 核心发射 CAP、P 和 RUN 信号；高位 payload[127:81] 必须为 0。', path: ['Program Target 6', 'R6 Outer Local', 'EXEC calendar', 'ROW CAP / P / RUN'], fields: [
    sxmField('CAP', 'payload[11:0]', 12, 'CAP valid / context / tile / group / row', 149),
    sxmField('P', 'payload[31:12]', 20, 'P valid / context / destination / source / row / paired / branch / sequence', 154),
    sxmField('RUN valid', 'payload[35:32]', 4, 'T=4 时，每位对应一个 ROW 的 RUN 有效信号', 162),
    sxmField('RUN parameters', 'payload[80:36]', 45, 'RUN context / delay / interval / count / sequence', 163),
    { name: 'schedule_cycle', bits: 'timing[31:0]', width: 32, signed: false, meaning: '事件发射的绝对周期；错过截止周期会报错，不会重试', evidence: [sxmCalendar] },
  ], evidence: [sxmNative, sxmCalendar, rtl('rtl/program_load/lpu_program_load_pkg.sv', 57, 'PROGRAM_TARGET_SXM_PERMUTE', 'Target Kind 6')], caution: '正式 RTL 已接入，VCS 五场景 2787 检查通过；CMODEL main 的 ROW Program 尚未实现，未做 CModel 联合对齐。' },
  ...(['ShiftSelect', 'Distribute', 'Transpose', 'Permute'] as const).map((name) => ({ id: `sxm-${name.toLowerCase()}`, fu: 'SXM' as const, name, kind: 'CModel typed instruction', width: 'CModel typed API；非 native ROW 位宽', opcode: 'typed enum；不声明硬件 opcode', status: 'UNVERIFIED' as IsaStatus, version: 'CURRENT · CModel-clock typed API', summary: `${name} 是旧 CModel typed SXM 指令类型；与当前 RTL 的 native ROW Program 尚未完成等价对齐。`, path: ['Software/CModel typed API', 'CModel batch/FIFO path', 'native ROW Program equivalence: unverified'], fields: [], evidence: [sxmCmodel, sxmBatch, sxmSoftware], caution: '不能把 C++ 枚举值或 Software Macro 编码直接解释成 native ROW 的位域；CMODEL main 尚未实现 ROW Program。' })),
]

export const isaVersions = [
  { repo: 'VMODEL' as const, root: 'FTLPU-VMODEL-DEV local snapshot', branch: 'main', head: '2cbaa104090c6df099894559794c0f981d4aafda', state: '当前本地权威工作区；有未提交修改，文件内容可能新于 HEAD' },
  { repo: 'CMODEL' as const, root: 'FTLPU-CMODEL local snapshot', branch: '无 .git', head: '本地目录无法提供 SHA', state: '当前 CModel 权威目录；仅能标记 local snapshot' },
  { repo: 'SOFTWARE' as const, root: 'FTLPU-SOFTWARE local snapshot', branch: '无 .git', head: '本地目录无法提供 SHA', state: '本地源码目录；默认 CMake 依赖相邻 CModel，不能当成 clock 构建已验证' },
]
