import { promises as fs } from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)
const HDL_EXTENSIONS = new Set(['.sv', '.svh', '.v', '.vh'])

const toPosix = (value) => value.split(path.sep).join('/')

const childNodes = (node) =>
  Array.isArray(node?.children) ? node.children.filter((child) => child && typeof child === 'object') : []

function walk(node, visitor, ancestors = []) {
  if (!node || typeof node !== 'object') return
  visitor(node, ancestors)
  const nextAncestors = [...ancestors, node]
  for (const child of childNodes(node)) walk(child, visitor, nextAncestors)
}

function findAll(node, predicate) {
  const result = []
  walk(node, (candidate, ancestors) => {
    if (typeof predicate === 'string' ? candidate.tag === predicate : predicate(candidate, ancestors)) {
      result.push(candidate)
    }
  })
  return result
}

function findFirst(node, predicate) {
  let result = null
  walk(node, (candidate, ancestors) => {
    if (!result && (typeof predicate === 'string' ? candidate.tag === predicate : predicate(candidate, ancestors))) {
      result = candidate
    }
  })
  return result
}

function leaves(node) {
  const result = []
  walk(node, (candidate) => {
    if (Number.isInteger(candidate.start) && Number.isInteger(candidate.end)) result.push(candidate)
  })
  return result.sort((a, b) => a.start - b.start || a.end - b.end)
}

function nodeRange(node) {
  const tokens = leaves(node)
  if (!tokens.length) return null
  return {
    start: Math.min(...tokens.map((token) => token.start)),
    end: Math.max(...tokens.map((token) => token.end)),
  }
}

function sourceSlice(buffer, node) {
  const range = nodeRange(node)
  return range ? buffer.subarray(range.start, range.end).toString('utf8') : ''
}

function lineAt(buffer, byteOffset) {
  let line = 1
  for (let index = 0; index < Math.min(byteOffset, buffer.length); index += 1) {
    if (buffer[index] === 10) line += 1
  }
  return line
}

function splitTopLevel(text, separator = ',') {
  const parts = []
  let start = 0
  let round = 0
  let square = 0
  let curly = 0
  let inString = false
  let escaped = false
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index]
    if (inString) {
      if (escaped) escaped = false
      else if (char === '\\') escaped = true
      else if (char === '"') inString = false
      continue
    }
    if (char === '"') inString = true
    else if (char === '(') round += 1
    else if (char === ')') round = Math.max(0, round - 1)
    else if (char === '[') square += 1
    else if (char === ']') square = Math.max(0, square - 1)
    else if (char === '{') curly += 1
    else if (char === '}') curly = Math.max(0, curly - 1)
    else if (char === separator && round === 0 && square === 0 && curly === 0) {
      parts.push(text.slice(start, index).trim())
      start = index + 1
    }
  }
  parts.push(text.slice(start).trim())
  return parts.filter(Boolean)
}

function findBalancedGroup(text, openIndex, open = '(', close = ')') {
  if (openIndex < 0 || text[openIndex] !== open) return null
  let depth = 0
  let inString = false
  let escaped = false
  for (let index = openIndex; index < text.length; index += 1) {
    const char = text[index]
    if (inString) {
      if (escaped) escaped = false
      else if (char === '\\') escaped = true
      else if (char === '"') inString = false
      continue
    }
    if (char === '"') inString = true
    else if (char === open) depth += 1
    else if (char === close) {
      depth -= 1
      if (depth === 0) return { start: openIndex, end: index + 1, body: text.slice(openIndex + 1, index) }
    }
  }
  return null
}

function topLevelAssignmentIndex(text) {
  let round = 0
  let square = 0
  let curly = 0
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index]
    if (char === '(') round += 1
    else if (char === ')') round -= 1
    else if (char === '[') square += 1
    else if (char === ']') square -= 1
    else if (char === '{') curly += 1
    else if (char === '}') curly -= 1
    else if (
      char === '=' && round === 0 && square === 0 && curly === 0 &&
      text[index - 1] !== '=' && text[index + 1] !== '='
    ) return index
  }
  return -1
}

function identifiersAtTopLevel(text) {
  const result = []
  let square = 0
  let round = 0
  for (let index = 0; index < text.length;) {
    const char = text[index]
    if (char === '[') { square += 1; index += 1; continue }
    if (char === ']') { square -= 1; index += 1; continue }
    if (char === '(') { round += 1; index += 1; continue }
    if (char === ')') { round -= 1; index += 1; continue }
    if (/[A-Za-z_$]/.test(char)) {
      const match = text.slice(index).match(/^[A-Za-z_$][A-Za-z0-9_$]*/)
      if (match) {
        if (square === 0 && round === 0) result.push({ value: match[0], index })
        index += match[0].length
        continue
      }
    }
    if (char === '\\') {
      const match = text.slice(index).match(/^\\[^\s,;()]+/)
      if (match) {
        if (square === 0 && round === 0) result.push({ value: match[0], index })
        index += match[0].length
        continue
      }
    }
    index += 1
  }
  return result
}

function bracketGroups(text) {
  const result = []
  for (let index = 0; index < text.length; index += 1) {
    if (text[index] !== '[') continue
    const group = findBalancedGroup(text, index, '[', ']')
    if (!group) continue
    result.push({ ...group, raw: text.slice(group.start, group.end) })
    index = group.end - 1
  }
  return result
}

function parseParameterParts(text) {
  const normalized = text
    .replace(/^\s*(parameter|localparam)\b/, '')
    .replace(/;\s*$/, '')
    .trim()
  const parameters = []
  for (const part of splitTopLevel(normalized)) {
    const assignment = topLevelAssignmentIndex(part)
    const left = (assignment >= 0 ? part.slice(0, assignment) : part).trim()
    const value = assignment >= 0 ? part.slice(assignment + 1).trim() : null
    const ids = identifiersAtTopLevel(left)
    const name = ids.at(-1)?.value
    if (!name || ['parameter', 'localparam', 'integer', 'int', 'logic', 'bit'].includes(name)) continue
    parameters.push({ name, default: value, raw: part.trim(), resolvedDefault: null })
  }
  return parameters
}

function parseModuleParameters(headerText) {
  const hashIndex = headerText.indexOf('#')
  if (hashIndex < 0) return []
  const openIndex = headerText.indexOf('(', hashIndex)
  const group = findBalancedGroup(headerText, openIndex)
  if (!group) return []
  return splitTopLevel(group.body).flatMap((part) => parseParameterParts(part))
}

function replaceVerilogLiterals(expression) {
  let invalid = false
  let result = expression.replace(/(\d+)?'([sS])?([bBoOdDhH])([0-9a-fA-F_xXzZ?]+)/g, (_, width, signed, base, digits) => {
    if (/[xXzZ?]/.test(digits)) { invalid = true; return '0' }
    const radix = { b: 2, o: 8, d: 10, h: 16 }[base.toLowerCase()]
    const value = Number.parseInt(digits.replaceAll('_', ''), radix)
    return Number.isFinite(value) ? String(value) : '0'
  })
  result = result.replace(/'([01xXzZ])/g, (_, digit) => {
    if (!/[01]/.test(digit)) invalid = true
    return digit === '1' ? '1' : '0'
  })
  return { result, invalid }
}

function evaluateExpression(expression, variables = {}) {
  if (!expression) return null
  const literalResult = replaceVerilogLiterals(expression.replaceAll('_', ''))
  if (literalResult.invalid) return null
  let normalized = literalResult.result
  const entries = Object.entries(variables)
    .filter(([, value]) => Number.isFinite(value))
    .sort(([left], [right]) => right.length - left.length)
  for (const [name, value] of entries) {
    const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    normalized = normalized.replace(new RegExp(`(?<![A-Za-z0-9_$])${escaped}(?![A-Za-z0-9_$])`, 'g'), String(value))
  }
  let previous
  do {
    previous = normalized
    normalized = normalized.replace(/\$clog2\s*\(\s*([0-9.]+)\s*\)/g, (_, value) =>
      String(Math.ceil(Math.log2(Number(value)))))
  } while (normalized !== previous)
  normalized = normalized.replace(/\bunsigned\s*'\s*\(([^()]*)\)/g, '($1)')
  if (/[A-Za-z_$]/.test(normalized)) return null
  if (!/^[0-9+\-*/%<>=!&|^~()?:.\s]+$/.test(normalized)) return null
  try {
    const value = Function(`"use strict"; return Number(${normalized});`)()
    return Number.isFinite(value) ? value : null
  } catch {
    return null
  }
}

function resolveParameterValues(parameters, inherited = {}) {
  const values = { ...inherited }
  for (let pass = 0; pass < parameters.length + 2; pass += 1) {
    let changed = false
    for (const parameter of parameters) {
      if (Number.isFinite(parameter.resolvedDefault)) continue
      const value = evaluateExpression(parameter.default, values)
      if (value !== null) {
        parameter.resolvedDefault = value
        values[parameter.name] = value
        changed = true
      }
    }
    if (!changed) break
  }
  return values
}

function dimensionWidth(raw, variables) {
  const body = raw.slice(1, -1).trim()
  const colonParts = splitTopLevel(body, ':')
  if (colonParts.length === 1) {
    const count = evaluateExpression(colonParts[0], variables)
    return count === null ? null : Math.max(0, count)
  }
  if (colonParts.length === 2) {
    const left = evaluateExpression(colonParts[0], variables)
    const right = evaluateExpression(colonParts[1], variables)
    return left === null || right === null ? null : Math.abs(left - right) + 1
  }
  return null
}

function parsePort(node, buffer, moduleVariables) {
  const range = nodeRange(node)
  const raw = sourceSlice(buffer, node).replace(/,\s*$/, '').trim()
  const directionMatch = raw.match(/\b(input|output|inout|ref)\b/)
  const direction = directionMatch?.[1] ?? 'unknown'
  const leftOfDefault = raw.slice(0, topLevelAssignmentIndex(raw) >= 0 ? topLevelAssignmentIndex(raw) : raw.length)
  const ids = identifiersAtTopLevel(leftOfDefault)
  const reserved = new Set(['input', 'output', 'inout', 'ref', 'wire', 'tri', 'logic', 'reg', 'bit', 'signed', 'unsigned', 'var', 'const'])
  const portIdentifier = [...ids].reverse().find((item) => !reserved.has(item.value))
  const name = portIdentifier?.value ?? `unnamed_port_${range?.start ?? 0}`
  const groups = bracketGroups(leftOfDefault)
  const packedDimensions = groups.filter((group) => group.start < (portIdentifier?.index ?? leftOfDefault.length)).map((group) => group.raw)
  const unpackedDimensions = groups.filter((group) => group.start > (portIdentifier?.index ?? leftOfDefault.length)).map((group) => group.raw)
  let width = 1
  for (const dimension of packedDimensions) {
    const value = dimensionWidth(dimension, moduleVariables)
    if (value === null) { width = null; break }
    width *= value
  }
  const directionEnd = directionMatch ? directionMatch.index + directionMatch[0].length : 0
  const nameIndex = portIdentifier?.index ?? leftOfDefault.length
  let dataType = leftOfDefault.slice(directionEnd, nameIndex)
  for (const dimension of packedDimensions) dataType = dataType.replace(dimension, ' ')
  dataType = dataType.trim().replace(/\s+/g, ' ') || 'implicit logic'
  return {
    name,
    direction,
    width,
    widthExpression: packedDimensions.length ? packedDimensions.join(' ') : '1',
    dataType,
    packedDimensions,
    unpackedDimensions,
    raw,
    line: range ? lineAt(buffer, range.start) : null,
  }
}

function parseParameterOverrides(typeText) {
  const hash = typeText.indexOf('#')
  if (hash < 0) return []
  const group = findBalancedGroup(typeText, typeText.indexOf('(', hash))
  if (!group) return []
  return splitTopLevel(group.body).map((part, index) => {
    const named = part.match(/^\.\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*\(([\s\S]*)\)$/)
    return named
      ? { name: named[1], value: named[2].trim(), positionalIndex: null }
      : { name: null, value: part.trim(), positionalIndex: index }
  })
}

function classifyConnection(expression) {
  const value = expression.trim()
  if (!value) return 'unconnected'
  if (/^(\d+)?'[sS]?[bBoOdDhH][0-9a-fA-F_xXzZ?]+$/.test(value) || /^\d+$/.test(value) || /^'[01xXzZ]$/.test(value)) return 'constant'
  if (value.startsWith('{') && value.endsWith('}')) return 'concatenation'
  if (/^[A-Za-z_$\\][A-Za-z0-9_$\\]*(\s*\[[^\]]+\])?$/.test(value)) return 'signal'
  return 'expression'
}

function parseConnections(gateText, gateLine = null) {
  const open = gateText.indexOf('(')
  const group = findBalancedGroup(gateText, open)
  if (!group) return []
  let searchOffset = 0
  return splitTopLevel(group.body).map((part, index) => {
    const partOffset = group.body.indexOf(part, searchOffset)
    if (partOffset >= 0) searchOffset = partOffset + part.length
    const named = part.match(/^\.\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*(?:\(([\s\S]*)\))?$/)
    const port = named?.[1] ?? null
    const expression = named ? (named[2] === undefined ? port : named[2].trim()) : part.trim()
    return {
      port,
      expression,
      kind: classifyConnection(expression),
      positionalIndex: named ? null : index,
      direction: 'unknown',
      width: null,
      widthExpression: null,
      connectedModule: null,
      line: gateLine === null || partOffset < 0
        ? gateLine
        : gateLine + group.body.slice(0, partOffset).split(/\r?\n/).length - 1,
    }
  })
}

function parseContinuousAssignments(moduleText, moduleLine, relativeFile) {
  const assignments = []
  const pattern = /\bassign\s+([^=;]+?)\s*=\s*([^;]+);/g
  for (const match of moduleText.matchAll(pattern)) {
    const offset = match.index ?? 0
    assignments.push({
      id: `${relativeFile}:${moduleLine + moduleText.slice(0, offset).split(/\r?\n/).length - 1}:${assignments.length}`,
      left: match[1].replace(/\s+/g, ' ').trim(),
      right: match[2].replace(/\s+/g, ' ').trim(),
      expression: match[0].replace(/\s+/g, ' ').trim(),
      file: relativeFile,
      line: moduleLine + moduleText.slice(0, offset).split(/\r?\n/).length - 1,
      kind: 'continuous',
    })
  }
  return assignments
}

function compactGenerateContext(text) {
  const first = text.split(/\bbegin\b/)[0].replace(/\s+/g, ' ').trim()
  return first.length > 220 ? `${first.slice(0, 217)}...` : first
}

function leadingComment(source, moduleStart) {
  const before = source.slice(0, moduleStart)
  const lines = before.split(/\r?\n/)
  while (lines.length && !lines.at(-1).trim()) lines.pop()
  const collected = []
  while (lines.length && collected.length < 16) {
    const line = lines.at(-1)
    const trimmed = line.trim()
    if (trimmed.startsWith('//') || trimmed.startsWith('/*') || trimmed.startsWith('*') || trimmed.endsWith('*/')) {
      collected.unshift(lines.pop())
    } else break
  }
  const text = collected
    .join('\n')
    .replace(/^\s*\/\/+\s?/gm, '')
    .replace(/^\s*\/\*+\s?/gm, '')
    .replace(/^\s*\*\/?\s?/gm, '')
    .trim()
  if (!text || /copyright|license/i.test(text)) return null
  return text
}

function parseModule(node, buffer, relativeFile, globalConstants) {
  const range = nodeRange(node)
  const moduleLine = range ? lineAt(buffer, range.start) : 1
  const header = childNodes(node).find((child) => child.tag === 'kModuleHeader') ?? findFirst(node, 'kModuleHeader')
  const headerTokens = leaves(header)
  const moduleTokenIndex = headerTokens.findIndex((token) => token.tag === 'module')
  const nameToken = headerTokens.slice(moduleTokenIndex + 1).find((token) => token.tag === 'SymbolIdentifier')
  const name = nameToken?.text ?? `unnamed_module_${range?.start ?? 0}`
  const headerText = sourceSlice(buffer, header)
  const parameters = parseModuleParameters(headerText)
  const moduleVariables = resolveParameterValues(parameters, globalConstants)
  const ports = findAll(header, 'kPortDeclaration').map((portNode) => parsePort(portNode, buffer, moduleVariables))
  const instances = []
  walk(node, (candidate, ancestors) => {
    if (candidate.tag !== 'kInstantiationBase') return
    const typeNode = childNodes(candidate).find((child) => child.tag === 'kInstantiationType') ?? findFirst(candidate, 'kInstantiationType')
    const typeTokens = leaves(typeNode)
    const typeName = typeTokens.find((token) => token.tag === 'SymbolIdentifier')?.text
    if (!typeName) return
    const gateNodes = findAll(candidate, 'kGateInstance')
    const typeText = sourceSlice(buffer, typeNode)
    const parameterOverrides = parseParameterOverrides(typeText)
    const reversedAncestors = [...ancestors].reverse()
    const generateAncestor = reversedAncestors.find((ancestor) =>
      ['kLoopGenerateConstruct', 'kConditionalGenerateConstruct'].includes(ancestor.tag))
      ?? reversedAncestors.find((ancestor) => ancestor.tag === 'kGenerateBlock')
    for (const gateNode of gateNodes) {
      const gateRange = nodeRange(gateNode)
      const gateText = sourceSlice(buffer, gateNode)
      const instanceName = leaves(gateNode).find((token) => token.tag === 'SymbolIdentifier')?.text
      if (!instanceName) continue
      instances.push({
        id: `${name}.${instanceName}@${gateRange?.start ?? instances.length}`,
        name: instanceName,
        moduleName: typeName,
        line: gateRange ? lineAt(buffer, gateRange.start) : null,
        sourceFile: relativeFile,
        parameterOverrides,
        connections: parseConnections(gateText, gateRange ? lineAt(buffer, gateRange.start) : null),
        generated: Boolean(generateAncestor),
        generateContext: generateAncestor ? compactGenerateContext(sourceSlice(buffer, generateAncestor)) : null,
        unresolved: false,
      })
    }
  })
  const sourceText = buffer.toString('utf8')
  const moduleText = range ? sourceText.slice(range.start, range.end) : ''
  const comment = range ? leadingComment(sourceText, range.start) : null
  return {
    id: `${name}@${relativeFile}:${range ? lineAt(buffer, range.start) : 1}`,
    name,
    file: relativeFile,
    line: moduleLine,
    endLine: range ? lineAt(buffer, range.end) : 1,
    parameters,
    ports,
    instances,
    assignments: parseContinuousAssignments(moduleText, moduleLine, relativeFile),
    description: comment
      ? { text: comment, source: 'rtl-comment', status: 'source-backed' }
      : { text: '', source: 'none', status: 'needs-confirmation' },
  }
}

async function parseVeribleFile(veribleExecutable, absoluteFile, relativeFile) {
  let stdout = ''
  let stderr = ''
  let processError = null
  try {
    const result = await execFileAsync(veribleExecutable, ['--export_json', '--printtree', absoluteFile], {
      windowsHide: true,
      maxBuffer: 128 * 1024 * 1024,
      encoding: 'utf8',
    })
    stdout = result.stdout
    stderr = result.stderr
  } catch (error) {
    processError = error
    stdout = error.stdout ?? ''
    stderr = error.stderr ?? error.message ?? ''
  }
  let payload
  try {
    payload = JSON.parse(stdout)
  } catch {
    return {
      tree: null,
      errors: [{ code: 'VERIBLE_JSON', severity: 'error', file: relativeFile, line: null, message: stderr || 'Verible did not return CST JSON.' }],
    }
  }
  const entry = Object.values(payload)[0]
  const errors = []
  if (Array.isArray(entry?.errors)) {
    for (const error of entry.errors) {
      errors.push({
        code: 'VERIBLE_SYNTAX',
        severity: 'warning',
        file: relativeFile,
        line: error.line ?? null,
        message: error.message ?? JSON.stringify(error),
      })
    }
  }
  if (processError && !entry?.tree) {
    errors.push({ code: 'VERIBLE_PROCESS', severity: 'error', file: relativeFile, line: null, message: stderr.trim() || processError.message })
  }
  return { tree: entry?.tree ?? null, errors }
}

async function listHdlFiles(directory) {
  const result = []
  async function visit(current) {
    const entries = await fs.readdir(current, { withFileTypes: true })
    for (const entry of entries) {
      const fullPath = path.join(current, entry.name)
      if (entry.isDirectory()) await visit(fullPath)
      else if (entry.isFile() && HDL_EXTENSIONS.has(path.extname(entry.name).toLowerCase())) result.push(fullPath)
    }
  }
  await visit(directory)
  return result.sort((left, right) => left.localeCompare(right))
}

async function parseFilelist(filelistPath, projectRoot, visited = new Set()) {
  const result = { files: [], includeDirectories: [], defines: [], nestedFilelists: [], warnings: [] }
  const absolute = path.resolve(filelistPath)
  if (visited.has(absolute)) return result
  visited.add(absolute)
  let text
  try { text = await fs.readFile(absolute, 'utf8') }
  catch (error) {
    result.warnings.push({ code: 'FILELIST_READ', severity: 'warning', file: toPosix(path.relative(projectRoot, absolute)), line: null, message: error.message })
    return result
  }
  const base = path.dirname(absolute)
  const tokens = text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#') && !line.startsWith('//'))
    .flatMap((line) => line.match(/"[^"]*"|'[^']*'|\S+/g) ?? [])
    .map((token) => token.replace(/^['"]|['"]$/g, ''))
  for (let index = 0; index < tokens.length; index += 1) {
    const token = tokens[index]
    if (token === '-f' || token === '-F') {
      const nested = tokens[++index]
      if (!nested) continue
      const nestedPath = path.resolve(base, nested)
      result.nestedFilelists.push(toPosix(path.relative(projectRoot, nestedPath)))
      const nestedResult = await parseFilelist(nestedPath, projectRoot, visited)
      for (const key of ['files', 'includeDirectories', 'defines', 'nestedFilelists', 'warnings']) result[key].push(...nestedResult[key])
    } else if (/^-f/.test(token) && token.length > 2) {
      const nestedPath = path.resolve(base, token.slice(2).replace(/^=/, ''))
      result.nestedFilelists.push(toPosix(path.relative(projectRoot, nestedPath)))
      const nestedResult = await parseFilelist(nestedPath, projectRoot, visited)
      for (const key of ['files', 'includeDirectories', 'defines', 'nestedFilelists', 'warnings']) result[key].push(...nestedResult[key])
    } else if (token.startsWith('+incdir+')) {
      result.includeDirectories.push(...token.slice(8).split('+').map((item) => toPosix(path.relative(projectRoot, path.resolve(base, item)))))
    } else if (token.startsWith('+define+')) {
      result.defines.push(...token.slice(8).split('+'))
    } else if (token.startsWith('-I')) {
      const item = token.length > 2 ? token.slice(2) : tokens[++index]
      if (item) result.includeDirectories.push(toPosix(path.relative(projectRoot, path.resolve(base, item))))
    } else if (token.startsWith('-D')) {
      const item = token.length > 2 ? token.slice(2) : tokens[++index]
      if (item) result.defines.push(item)
    } else if (HDL_EXTENSIONS.has(path.extname(token).toLowerCase())) {
      result.files.push(toPosix(path.relative(projectRoot, path.resolve(projectRoot, token))))
    }
  }
  result.files = [...new Set(result.files)]
  result.includeDirectories = [...new Set(result.includeDirectories)]
  result.defines = [...new Set(result.defines)]
  return result
}

async function mapLimit(items, limit, mapper) {
  const output = new Array(items.length)
  let next = 0
  const workers = Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, async () => {
    while (true) {
      const index = next
      next += 1
      if (index >= items.length) return
      output[index] = await mapper(items[index], index)
    }
  })
  await Promise.all(workers)
  return output
}

function extractGlobalParameters(tree, buffer, relativeFile) {
  const values = []
  const packageNode = findFirst(tree, (node) => node.tag === 'kPackageDeclaration')
  const packageName = packageNode
    ? leaves(packageNode).find((token) => token.tag === 'SymbolIdentifier')?.text ?? path.basename(relativeFile, path.extname(relativeFile))
    : path.basename(relativeFile, path.extname(relativeFile))
  for (const node of findAll(tree, (candidate) => /ParamDeclaration/.test(candidate.tag ?? ''))) {
    const range = nodeRange(node)
    for (const parameter of parseParameterParts(sourceSlice(buffer, node))) {
      values.push({
        ...parameter,
        packageName,
        sourceFile: relativeFile,
        line: range ? lineAt(buffer, range.start) : 1,
      })
    }
  }
  return values
}

function resolveGlobalConstants(parameters) {
  const working = parameters.map((parameter) => ({ ...parameter }))
  const values = {}
  for (let pass = 0; pass < working.length + 2; pass += 1) {
    let changed = false
    for (const parameter of working) {
      if (Number.isFinite(parameter.resolvedDefault)) continue
      const value = evaluateExpression(parameter.default, values)
      if (value !== null) {
        parameter.resolvedDefault = value
        if (!(parameter.name in values)) values[parameter.name] = value
        values[`${parameter.packageName}::${parameter.name}`] = value
        changed = true
      }
    }
    if (!changed) break
  }
  return values
}

function reachableDefinitionCount(name, moduleMap, visited = new Set()) {
  if (visited.has(name) || !moduleMap.has(name)) return 0
  visited.add(name)
  let count = 1
  for (const instance of moduleMap.get(name).instances) count += reachableDefinitionCount(instance.moduleName, moduleMap, visited)
  return count
}

function buildHierarchy(top, moduleMap, maxDepth, maxNodes, warnings) {
  const nodes = []
  const edges = []
  let truncated = false
  const rootDefinition = moduleMap.get(top)
  if (!rootDefinition) return { top, nodes, edges, truncated }
  const root = {
    id: `instance:${top}`,
    path: top,
    name: top,
    moduleName: top,
    parentId: null,
    depth: 0,
    line: rootDefinition.line,
    sourceFile: rootDefinition.file,
    generated: false,
    generateContext: null,
    unresolved: false,
    definitionId: rootDefinition.id,
  }
  nodes.push(root)
  function expand(parentNode, definition, depth, stack) {
    if (depth >= maxDepth) {
      warnings.push({ code: 'HIERARCHY_DEPTH_LIMIT', severity: 'warning', file: definition.file, line: definition.line, message: `Hierarchy stopped at depth ${maxDepth} below ${parentNode.path}.` })
      return
    }
    const nameCounts = new Map()
    for (const instance of definition.instances) {
      if (nodes.length >= maxNodes) { truncated = true; return }
      const seen = nameCounts.get(instance.name) ?? 0
      nameCounts.set(instance.name, seen + 1)
      const displayName = seen ? `${instance.name}#${seen + 1}` : instance.name
      const pathSuffix = instance.generated ? `${displayName}[*]` : displayName
      const instancePath = `${parentNode.path}.${pathSuffix}`
      const childDefinition = moduleMap.get(instance.moduleName)
      const childNode = {
        id: `instance:${instancePath}`,
        path: instancePath,
        name: displayName,
        moduleName: instance.moduleName,
        parentId: parentNode.id,
        depth: depth + 1,
        line: instance.line,
        sourceFile: instance.sourceFile,
        generated: instance.generated,
        generateContext: instance.generateContext,
        unresolved: !childDefinition,
        definitionId: childDefinition?.id ?? null,
        templateId: instance.id,
      }
      nodes.push(childNode)
      edges.push({
        id: `edge:${instancePath}`,
        source: parentNode.id,
        target: childNode.id,
        instanceName: displayName,
        moduleName: instance.moduleName,
        generated: instance.generated,
        connections: instance.connections,
      })
      if (childDefinition) {
        if (stack.has(instance.moduleName)) {
          warnings.push({ code: 'HIERARCHY_RECURSION', severity: 'warning', file: instance.sourceFile, line: instance.line, message: `Recursive instantiation stopped at ${instancePath}.` })
        } else {
          expand(childNode, childDefinition, depth + 1, new Set([...stack, instance.moduleName]))
        }
      }
    }
  }
  expand(root, rootDefinition, 0, new Set([top]))
  if (truncated) warnings.push({ code: 'HIERARCHY_NODE_LIMIT', severity: 'warning', file: rootDefinition.file, line: rootDefinition.line, message: `Hierarchy was limited to ${maxNodes} symbolic instance nodes.` })
  return { top, nodes, edges, truncated }
}

export function hierarchyForTop(modules, top, options = {}) {
  const moduleMap = new Map()
  for (const module of modules) if (!moduleMap.has(module.name)) moduleMap.set(module.name, module)
  const warnings = []
  const hierarchy = buildHierarchy(top, moduleMap, options.maxDepth ?? 14, options.maxNodes ?? 3000, warnings)
  return { hierarchy, warnings }
}

async function gitInformation(projectRoot) {
  try {
    const [{ stdout: head }, { stdout: status }] = await Promise.all([
      execFileAsync('git', ['rev-parse', 'HEAD'], { cwd: projectRoot, windowsHide: true, encoding: 'utf8' }),
      execFileAsync('git', ['status', '--short', '--branch'], { cwd: projectRoot, windowsHide: true, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 }),
    ])
    return { head: head.trim(), status: status.trim(), available: true }
  } catch (error) {
    return { head: null, status: null, available: false, error: error.message }
  }
}

async function veribleVersion(executable) {
  try {
    const { stdout, stderr } = await execFileAsync(executable, ['--version'], { windowsHide: true, encoding: 'utf8' })
    return (stdout || stderr).trim()
  } catch (error) {
    return error.stdout?.trim() || error.stderr?.trim() || 'unknown'
  }
}

export async function parseProject(config, progress = () => {}) {
  const projectRoot = path.resolve(config.projectRoot)
  const sourceRoot = path.resolve(projectRoot, config.sourceDirectory ?? 'rtl')
  const filelistPath = path.resolve(projectRoot, config.filelist ?? 'sim/filelist.f')
  const veribleExecutable = path.resolve(config.veribleExecutable)
  const [projectStat, sourceStat, veribleStat] = await Promise.all([
    fs.stat(projectRoot), fs.stat(sourceRoot), fs.stat(veribleExecutable),
  ])
  if (!projectStat.isDirectory() || !sourceStat.isDirectory() || !veribleStat.isFile()) throw new Error('Project root, RTL source directory, or Verible executable is invalid.')

  progress({ phase: 'inventory', completed: 0, total: 1, message: 'Reading filelist and RTL inventory' })
  const [filelist, absoluteFiles, git, parserVersion] = await Promise.all([
    parseFilelist(filelistPath, projectRoot),
    listHdlFiles(sourceRoot),
    gitInformation(projectRoot),
    veribleVersion(veribleExecutable),
  ])
  const filelistSet = new Set(filelist.files)
  const relativeFiles = absoluteFiles.map((file) => toPosix(path.relative(projectRoot, file)))
  const parseResults = await mapLimit(absoluteFiles, config.parseConcurrency ?? 4, async (absoluteFile, index) => {
    const relativeFile = relativeFiles[index]
    progress({ phase: 'parse', completed: index, total: absoluteFiles.length, message: `Parsing ${relativeFile}` })
    const buffer = await fs.readFile(absoluteFile)
    const hash = crypto.createHash('sha256').update(buffer).digest('hex')
    const parsed = await parseVeribleFile(veribleExecutable, absoluteFile, relativeFile)
    return { absoluteFile, relativeFile, buffer, hash, ...parsed }
  })
  progress({ phase: 'model', completed: absoluteFiles.length, total: absoluteFiles.length, message: 'Building architecture model' })

  const warnings = [...filelist.warnings]
  const globalParameters = []
  for (const result of parseResults) {
    warnings.push(...result.errors)
    if (result.tree) globalParameters.push(...extractGlobalParameters(result.tree, result.buffer, result.relativeFile))
  }
  const globalConstants = resolveGlobalConstants(globalParameters)
  const resolvedGlobalParameters = globalParameters.map((parameter) => ({
    ...parameter,
    resolvedDefault: evaluateExpression(parameter.default, globalConstants),
  }))
  const modules = []
  for (const result of parseResults) {
    if (!result.tree) continue
    for (const moduleNode of findAll(result.tree, 'kModuleDeclaration')) {
      modules.push(parseModule(moduleNode, result.buffer, result.relativeFile, globalConstants))
    }
  }
  const moduleMap = new Map()
  for (const module of modules) {
    if (moduleMap.has(module.name)) {
      warnings.push({ code: 'DUPLICATE_MODULE', severity: 'warning', file: module.file, line: module.line, message: `Duplicate definition of ${module.name}; hierarchy uses the first definition.` })
    } else moduleMap.set(module.name, module)
  }
  for (const module of modules) {
    for (const instance of module.instances) {
      const child = moduleMap.get(instance.moduleName)
      instance.unresolved = !child
      for (const connection of instance.connections) {
        const port = connection.port
          ? child?.ports.find((candidate) => candidate.name === connection.port)
          : child?.ports[connection.positionalIndex]
        connection.direction = port?.direction ?? 'unknown'
        connection.width = port?.width ?? null
        connection.widthExpression = port?.widthExpression ?? null
        connection.connectedModule = module.name
      }
      if (!child) warnings.push({ code: 'UNRESOLVED_MODULE', severity: 'warning', file: instance.sourceFile, line: instance.line, message: `${module.name}.${instance.name} instantiates unresolved module ${instance.moduleName}.` })
    }
    if (!module.description.text) {
      const inputs = module.ports.filter((port) => port.direction === 'input').length
      const outputs = module.ports.filter((port) => port.direction === 'output').length
      module.description.text = `待确认：RTL 结构显示 ${inputs} 个输入、${outputs} 个输出，并包含 ${module.instances.length} 个子模块实例模板。该说明仅来自结构计数，未推断功能。`
    }
  }
  const instantiated = new Set(modules.flatMap((module) => module.instances.map((instance) => instance.moduleName)))
  const topCandidates = modules
    .filter((module) => !instantiated.has(module.name))
    .map((module) => ({
      name: module.name,
      file: module.file,
      line: module.line,
      reachableDefinitions: reachableDefinitionCount(module.name, moduleMap),
      inPrimaryFilelist: filelistSet.has(module.file),
    }))
    .sort((left, right) => right.reachableDefinitions - left.reachableDefinitions || Number(right.inPrimaryFilelist) - Number(left.inPrimaryFilelist) || left.name.localeCompare(right.name))
  const autoTop = topCandidates[0]?.name ?? modules[0]?.name ?? null
  const selectedTop = moduleMap.has(config.preferredTop) ? config.preferredTop : autoTop
  const hierarchy = selectedTop
    ? buildHierarchy(selectedTop, moduleMap, config.hierarchyMaxDepth ?? 14, config.hierarchyMaxNodes ?? 3000, warnings)
    : { top: null, nodes: [], edges: [], truncated: false }
  const instanceTemplateCount = modules.reduce((count, module) => count + module.instances.length, 0)
  const portCount = modules.reduce((count, module) => count + module.ports.length, 0)
  const unresolvedInstanceCount = modules.reduce((count, module) => count + module.instances.filter((instance) => instance.unresolved).length, 0)
  const generatedTemplateCount = modules.reduce((count, module) => count + module.instances.filter((instance) => instance.generated).length, 0)
  const snapshot = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    project: {
      name: 'LPU RTL Architecture Explorer',
      projectRoot,
      sourceDirectory: toPosix(path.relative(projectRoot, sourceRoot)),
      filelist: toPosix(path.relative(projectRoot, filelistPath)),
      statusNote: config.projectStatusNote ?? null,
      git,
    },
    configuration: {
      parser: 'Verible CST export + structure modeler',
      parserVersion,
      veribleExecutable,
      filelistFiles: filelist.files,
      includeDirectories: filelist.includeDirectories,
      defines: filelist.defines,
      nestedFilelists: filelist.nestedFilelists,
      sourceFilesNotInPrimaryFilelist: relativeFiles.filter((file) => !filelistSet.has(file)),
      generateHandling: 'Generate instances are extracted as symbolic instance templates and marked [*]; loop expansion is not claimed.',
      conditionalCompilation: 'Primary filelist, includes, and defines are recorded; VCS compile validation is reported separately.',
      globalParameters: resolvedGlobalParameters,
    },
    summary: {
      sourceFileCount: relativeFiles.length,
      primaryFilelistRtlFileCount: relativeFiles.filter((file) => filelistSet.has(file)).length,
      definitionCount: modules.length,
      instanceTemplateCount,
      unresolvedInstanceCount,
      generatedTemplateCount,
      portCount,
      autoTop,
      selectedTop,
      topCandidateCount: topCandidates.length,
      hierarchyNodeCount: hierarchy.nodes.length,
      hierarchyEdgeCount: hierarchy.edges.length,
    },
    topCandidates,
    modules,
    hierarchy,
    warnings,
    sourceFiles: parseResults.map((result) => ({
      file: result.relativeFile,
      sha256: result.hash,
      inPrimaryFilelist: filelistSet.has(result.relativeFile),
      parsed: Boolean(result.tree),
      diagnosticCount: result.errors.length,
    })),
  }
  progress({ phase: 'complete', completed: absoluteFiles.length, total: absoluteFiles.length, message: 'Architecture snapshot complete' })
  return snapshot
}

export async function writeSnapshot(snapshot, outputPath) {
  await fs.mkdir(path.dirname(outputPath), { recursive: true })
  const temporary = `${outputPath}.${process.pid}.tmp`
  await fs.writeFile(temporary, `${JSON.stringify(snapshot, null, 2)}\n`, 'utf8')
  await fs.rename(temporary, outputPath)
}
