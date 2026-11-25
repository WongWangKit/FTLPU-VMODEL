import type { RawConnection } from '../types'
import { signalSemanticPresentation } from '../lib/signal-presentation'

interface Props {
  semanticName: string
  sourceName: string
  destinationName: string
  rawConnections: RawConnection[]
  status: string
  pinned: boolean
  onClose: () => void
  onOpenDetail: () => void
}

export default function InterfaceEvidenceTooltip({ semanticName, sourceName, destinationName, rawConnections, status, pinned, onClose, onOpenDetail }: Props) {
  return <div className="interface-evidence-tooltip" role={pinned ? 'dialog' : 'tooltip'} aria-label={`${semanticName} interface preview`} onClick={(event) => event.stopPropagation()}>
    <header><span>SEMANTIC INTERFACE</span>{pinned && <button type="button" onClick={onClose} aria-label="关闭接口预览">×</button>}</header>
    <strong>{semanticName}</strong>
    <div className="interface-tooltip-flow"><small>FLOW</small><b>{sourceName} → {destinationName}</b></div>
    <div className="interface-tooltip-signals">
      <small>SEMANTIC SIGNAL PREVIEW</small>
      {rawConnections.length ? rawConnections.slice(0, 8).map((raw) => { const signal = signalSemanticPresentation(raw); return <div className="interface-tooltip-signal" key={raw.id} title={`RTL: ${signal.rtlName}`}><b>{signal.displayName}</b><code>{signal.rtlName}</code></div> }) : <i>No directly bound raw signal in the current WIP snapshot.</i>}
      {rawConnections.length > 8 && <i>其余信号请在 Bus Detail 中查看。</i>}
    </div>
    <em>{status}</em>
    <button type="button" className="interface-tooltip-open" onClick={onOpenDetail}>查看接口详情 →</button>
  </div>
}
