import { useEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react'
import type { RawConnection } from '../types'
import InterfaceEvidenceTooltip from './InterfaceEvidenceTooltip'

interface Props {
  className: string
  style?: CSSProperties
  ariaLabel: string
  children: ReactNode
  semanticName: string
  sourceName: string
  destinationName: string
  rawConnections: RawConnection[]
  status: string
  onOpenDetail: () => void
  dataAttributes?: Record<string, string | number | undefined>
}

export default function InteractiveInterfaceLabel({ className, style, ariaLabel, children, semanticName, sourceName, destinationName, rawConnections, status, onOpenDetail, dataAttributes = {} }: Props) {
  const [open, setOpen] = useState(false)
  const [pinned, setPinned] = useState(false)
  const rootRef = useRef<HTMLDivElement>(null)
  const closeTimer = useRef<number | null>(null)
  const suppressReopen = useRef(false)

  const cancelClose = () => {
    if (closeTimer.current !== null) window.clearTimeout(closeTimer.current)
    closeTimer.current = null
  }
  const close = (suppressUntilLeave = false) => {
    cancelClose()
    suppressReopen.current = suppressUntilLeave
    setOpen(false)
    setPinned(false)
  }
  const scheduleClose = () => {
    cancelClose()
    if (pinned) return
    closeTimer.current = window.setTimeout(() => setOpen(false), 240)
  }

  useEffect(() => {
    const onPointerDown = (event: PointerEvent) => {
      if (pinned && rootRef.current && !rootRef.current.contains(event.target as Node)) close(false)
    }
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape' && open) close(true)
    }
    document.addEventListener('pointerdown', onPointerDown)
    document.addEventListener('keydown', onKeyDown)
    return () => {
      cancelClose()
      document.removeEventListener('pointerdown', onPointerDown)
      document.removeEventListener('keydown', onKeyDown)
    }
  }, [open, pinned])

  return <div
    ref={rootRef}
    className={`${className} interface-popover-anchor ${open ? 'is-open' : ''} ${pinned ? 'is-pinned' : ''}`}
    style={style}
    onMouseEnter={() => { cancelClose(); if (!suppressReopen.current) setOpen(true) }}
    onMouseLeave={() => { suppressReopen.current = false; scheduleClose() }}
    onFocusCapture={() => { cancelClose(); if (!suppressReopen.current) setOpen(true) }}
    onBlurCapture={(event) => { if (!event.currentTarget.contains(event.relatedTarget as Node | null)) { suppressReopen.current = false; scheduleClose() } }}
    {...dataAttributes}
  >
    <button
      type="button"
      className="interface-popover-trigger"
      aria-label={ariaLabel}
      aria-expanded={open}
      onClick={(event) => {
        event.stopPropagation()
        suppressReopen.current = false
        setPinned((current) => {
          const next = !current
          setOpen(next)
          return next
        })
      }}
    >{children}</button>
    <InterfaceEvidenceTooltip semanticName={semanticName} sourceName={sourceName} destinationName={destinationName} rawConnections={rawConnections} status={status} pinned={pinned} onClose={() => close(true)} onOpenDetail={onOpenDetail} />
  </div>
}
