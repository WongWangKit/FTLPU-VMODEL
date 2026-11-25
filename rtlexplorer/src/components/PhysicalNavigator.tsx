import type { PhysicalFunctionalBlock, PhysicalRegion } from '../types'

interface Props {
  regions: PhysicalRegion[]
  blocks: PhysicalFunctionalBlock[]
  selectedBlockId: string | null
  query: string
  onSelectBlock: (id: string) => void
}

function statusLabel(status: PhysicalFunctionalBlock['placementStatus']) {
  if (status === 'rtl-confirmed') return 'RTL'
  if (status === 'architecture-inferred') return 'INFERRED'
  if (status === 'reference-manual') return 'MANUAL'
  return 'REVIEW'
}

export default function PhysicalNavigator({ regions, blocks, selectedBlockId, query, onSelectBlock }: Props) {
  const needle = query.trim().toLowerCase()
  return (
    <div className="physical-navigator">
      {regions.slice().sort((a, b) => a.order - b.order).map((region) => {
        const regionBlocks = blocks
          .filter((block) => block.regionId === region.id)
          .filter((block) => !needle || `${block.displayName} ${block.kind} ${block.definitionNames.join(' ')}`.toLowerCase().includes(needle))
          .sort((a, b) => a.order - b.order)
        if (!regionBlocks.length && needle) return null
        return (
          <section key={region.id} className={`physical-nav-region region-${region.id}`}>
            <div className="physical-nav-region-title">
              <span>{region.name}</span>
              <small className={`evidence-dot status-${region.placementStatus}`} title={region.basis} />
            </div>
            <div className="physical-nav-blocks">
              {regionBlocks.map((block) => (
                <button key={block.id} className={`${selectedBlockId === block.id ? 'active' : ''} ${!block.enabledByDefault ? 'inactive' : ''}`} onClick={() => onSelectBlock(block.id)}>
                  <span className={`physical-kind kind-${block.kind}`}>{block.shortName}</span>
                  <span><strong>{block.displayName}</strong><small>{block.instanceCountExpression}</small></span>
                  <b className={`status-pill status-${block.placementStatus}`}>{statusLabel(block.placementStatus)}</b>
                </button>
              ))}
            </div>
          </section>
        )
      })}
      <div className="physical-nav-note">
        <strong>功能拓扑 ≠ Floorplan</strong>
        <p>左右位置表达硬件组织和数据流。数量、参数和映射来自当前 RTL；后端坐标未包含在快照中。</p>
      </div>
    </div>
  )
}
