import { useEffect, useMemo, useRef, useState } from 'react'
import { buildTrack, createPlanner } from './zoom.js'
import { CLICKS, DURATION, WAYPOINTS, sceneAt } from '../stage/script.js'

const reduced = () =>
  typeof window !== 'undefined' && window.matchMedia('(prefers-reduced-motion: reduce)').matches

/**
 * Plays the synthetic take and returns everything the stage needs for one frame.
 * Pauses when the stage scrolls out of view, and holds still on a mid-take frame
 * when the visitor has asked for reduced motion.
 */
export function useTake({ zoomScale = 1.9, playing = true } = {}) {
    const track = useMemo(() => buildTrack(WAYPOINTS, DURATION), [])
  const planner = useMemo(() => createPlanner(track, CLICKS, zoomScale), [track, zoomScale])

  const hostRef = useRef(null)
  const [t, setT] = useState(0)
  const [visible, setVisible] = useState(true)

  useEffect(() => {
    const el = hostRef.current
    if (!el || typeof IntersectionObserver === 'undefined') return
    const io = new IntersectionObserver(([e]) => setVisible(e.isIntersecting), { threshold: 0.15 })
    io.observe(el)
    return () => io.disconnect()
  }, [])

  useEffect(() => {
    if (reduced()) {
      setT(4.2) // a held frame, mid push-in
      return
    }
    if (!playing || !visible) return
    let raf = 0
    let start = 0
    const tick = (now) => {
      if (!start) start = now
      setT(((now - start) / 1000) % DURATION)
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [playing, visible])

  const camera = planner.at(t)
  const cursor = planner.cursorAt(t)
  const pressed = CLICKS.some((c) => t >= c && t < c + 0.13)

  return {
    hostRef,
    t,
    duration: DURATION,
    camera,
    cursor,
    pressed,
    scene: sceneAt(t),
    segments: planner.segments,
    zoomed: camera.scale > 1.02,
  }
}
