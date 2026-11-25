import { useEffect, useState } from 'react'

export function useAnimationClock(maxStep: number, initialStep = 0, loopStart: number | null = null) {
  const [step, setStep] = useState(initialStep)
  const [playing, setPlaying] = useState(false)
  const [speed, setSpeed] = useState(1)

  useEffect(() => {
    setStep((value) => Math.min(value, maxStep))
  }, [maxStep])

  useEffect(() => {
    if (!playing) return
    const timer = window.setInterval(() => {
      setStep((value) => {
        if (value >= maxStep) {
          if (loopStart !== null) return Math.max(0, Math.min(maxStep, loopStart))
          setPlaying(false)
          return maxStep
        }
        return value + 1
      })
    }, 850 / speed)
    return () => window.clearInterval(timer)
  }, [loopStart, maxStep, playing, speed])

  const reset = () => { setPlaying(false); setStep(initialStep) }
  const move = (next: number) => { setPlaying(false); setStep(Math.max(0, Math.min(maxStep, next))) }
  return { step, maxStep, playing, speed, setPlaying, setSpeed, reset, move }
}

interface Props {
  step: number
  maxStep: number
  playing: boolean
  speed: number
  cycleLabel: string
  onPlayingChange: (value: boolean) => void
  onSpeedChange: (value: number) => void
  onStepChange: (value: number) => void
  onReset: () => void
}

export default function AnimationControls({ step, maxStep, playing, speed, cycleLabel, onPlayingChange, onSpeedChange, onStepChange, onReset }: Props) {
  return <div className="animation-controls" aria-label="动画控制">
    <div className="animation-buttons">
      <button onClick={onReset}>重置</button>
      <button onClick={() => onStepChange(step - 1)} disabled={step === 0}>← 单步</button>
      <button className="primary" onClick={() => onPlayingChange(!playing)}>{playing ? '暂停' : '播放'}</button>
      <button onClick={() => onStepChange(step + 1)} disabled={step === maxStep}>单步 →</button>
    </div>
    <label className="animation-timeline"><span>{cycleLabel}</span><input type="range" name="animation-timeline" aria-label={`${cycleLabel} ${step} / ${maxStep}`} min={0} max={maxStep} value={step} onChange={(event) => onStepChange(Number(event.target.value))} /><b>{step} / {maxStep}</b></label>
    <div className="animation-speed" aria-label="播放速度">{[0.5, 1, 2].map((value) => <button key={value} className={speed === value ? 'active' : ''} onClick={() => onSpeedChange(value)}>{value}×</button>)}</div>
  </div>
}
