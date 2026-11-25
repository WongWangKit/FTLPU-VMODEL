import { useEffect, useRef, useState } from 'react'
import type { ConfigurationFrontendStage } from '../types'

interface Props {
  stage: ConfigurationFrontendStage
  variantName: string
  instanceCount: number | null
  onOpenPipeline?: () => void
}

const statusText = (status: string) => status.split('-').map((part) => part[0]?.toUpperCase() + part.slice(1)).join(' ')

export default function FrontendStagePopover({ stage, variantName, instanceCount, onOpenPipeline }: Props) {
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

  const specs = stage.specs ?? []
  return <div
    ref={rootRef}
    className={`frontend-stage-popover ${open ? 'is-open' : ''} ${pinned ? 'is-pinned' : ''}`}
    onMouseEnter={() => { cancelClose(); if (!suppressReopen.current) setOpen(true) }}
    onMouseLeave={() => { suppressReopen.current = false; scheduleClose() }}
    onFocusCapture={() => { cancelClose(); if (!suppressReopen.current) setOpen(true) }}
    onBlurCapture={(event) => { if (!event.currentTarget.contains(event.relatedTarget as Node | null)) { suppressReopen.current = false; scheduleClose() } }}
  >
    <button
      type="button"
      className="frontend-stage-trigger nodrag nopan"
      aria-label={stage.pipeline ? `进入 ${stage.name} 流水线层级` : `${stage.name} parameters`}
      aria-expanded={open}
      onClick={(event) => {
        event.stopPropagation()
        if (stage.pipeline && onOpenPipeline) {
          suppressReopen.current = true
          setOpen(false)
          setPinned(false)
          onOpenPipeline()
          return
        }
        suppressReopen.current = false
        setPinned((current) => {
          const next = !current
          setOpen(next)
          return next
        })
      }}
    ><strong>{stage.name}</strong>{stage.pipeline && <span className="frontend-stage-detail-affordance">进入流水线层级</span>}</button>
    <div className="frontend-stage-tooltip" role={pinned ? 'dialog' : 'tooltip'} aria-label={`${stage.name} parameter preview`} onClick={(event) => event.stopPropagation()}>
      <header><span>FRONTEND BLOCK</span>{pinned && <button type="button" onClick={() => close(true)} aria-label="关闭模块参数预览">×</button>}</header>
      <strong>{stage.name}</strong>
      <div><small>FUNCTION</small><b>{stage.role}</b></div>
      <div><small>FRONTEND PATH</small><b>{variantName}</b></div>
      <div className="frontend-stage-parameters">
        <small>PARAMETERS</small>
        {specs.length ? specs.map((item) => <dl key={`${item.label}:${item.value}`} data-status={item.status}><dt>{item.label}</dt><dd>{item.value}</dd></dl>) : <i>No static parameter is exposed for this semantic stage.</i>}
      </div>
      <div><small>INSTANCES</small><b>{instanceCount == null ? 'Defined path · not active-integrated' : `×${instanceCount} / FU`}</b></div>
      <em>{statusText(stage.status)}</em>
    </div>
  </div>
}
