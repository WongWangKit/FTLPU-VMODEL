import semanticMetadata from '../../data/interface-semantics.json'

export interface InterfaceSemanticPresentation {
  semanticId: string | null
  displayName: string
  classification: string | null
  confidence: string | null
  evidence: string | null
}

interface AliasRecord {
  semantic_id: string
  interface_id: string
  display_name: string
  classification: string
  confidence: string
  evidence: string
}

const aliases = semanticMetadata.aliases as AliasRecord[]

function wildcardMatches(pattern: string, value: string) {
  const expression = pattern.split('*').map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*')
  return new RegExp(`^${expression}$`).test(value)
}

function conciseFallback(name: string) {
  return name
    .replace(/^\s*[WE]:\s*/i, '')
    .replace(/\s*\(RTL name\)\s*/gi, '')
    .replace(/\s*·\s*(west|east)\s*$/i, '')
    .replace(/\s+/g, ' ')
    .trim()
}

export function interfaceSemanticPresentation(id: string, currentName: string): InterfaceSemanticPresentation {
  const alias = aliases.find((item) => wildcardMatches(item.interface_id, id))
  if (!alias) return { semanticId: null, displayName: conciseFallback(currentName), classification: null, confidence: null, evidence: null }
  return {
    semanticId: alias.semantic_id,
    displayName: alias.display_name,
    classification: alias.classification,
    confidence: alias.confidence,
    evidence: alias.evidence,
  }
}
