import { useMemo } from 'react'
import type { HierarchyNode, ModuleDefinition } from '../types'

interface Props {
  nodes: HierarchyNode[]
  modules: Map<string, ModuleDefinition>
  selectedId: string | null
  expanded: Set<string>
  matchedIds: Set<string>
  legacyIds: Set<string>
  onSelect: (id: string) => void
  onToggle: (id: string) => void
}

export default function HierarchyTree({ nodes, modules, selectedId, expanded, matchedIds, legacyIds, onSelect, onToggle }: Props) {
  const { roots, children } = useMemo(() => {
    const childMap = new Map<string, HierarchyNode[]>()
    const rootNodes: HierarchyNode[] = []
    for (const node of nodes) {
      if (!node.parentId) rootNodes.push(node)
      else childMap.set(node.parentId, [...(childMap.get(node.parentId) ?? []), node])
    }
    return { roots: rootNodes, children: childMap }
  }, [nodes])

  const renderNode = (node: HierarchyNode) => {
    const childNodes = children.get(node.id) ?? []
    const isExpanded = expanded.has(node.id)
    const definition = modules.get(node.moduleName)
    return (
      <li key={node.id} className="tree-item">
        <div className={`tree-row ${selectedId === node.id ? 'selected' : ''} ${matchedIds.has(node.id) ? 'matched' : ''} ${legacyIds.has(node.id) ? 'legacy' : ''}`}>
          <button
            className="tree-toggle"
            aria-label={isExpanded ? '折叠' : '展开'}
            disabled={!childNodes.length}
            onClick={() => onToggle(node.id)}
          >
            {childNodes.length ? (isExpanded ? '−' : '+') : '·'}
          </button>
          <button className="tree-label" onClick={() => onSelect(node.id)} title={node.path}>
            <span className="tree-instance">{node.name}</span>
            <span className="tree-module">{node.moduleName}</span>
          </button>
          {node.generated && <span className="tag generated">GEN</span>}
          {legacyIds.has(node.id) && <span className="tag legacy">AUX</span>}
          {node.unresolved && <span className="tag unresolved">BOX</span>}
          {definition && <span className="tree-count">{definition.instances.length}</span>}
        </div>
        {childNodes.length > 0 && isExpanded && <ul>{childNodes.map(renderNode)}</ul>}
      </li>
    )
  }

  return <ul className="hierarchy-tree">{roots.map(renderNode)}</ul>
}
