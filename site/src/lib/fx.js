import { useEffect, useState } from 'react'

/* Reveals anything carrying `.rv` once, on first intersection. One observer for
   the whole document rather than one per element. */
export function useReveal() {
  useEffect(() => {
    const els = document.querySelectorAll('.rv:not(.rv-in)')
    if (!els.length) return
    if (!('IntersectionObserver' in window)) {
      els.forEach((el) => el.classList.add('rv-in'))
      return
    }
    const io = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (!e.isIntersecting) continue
          e.target.classList.add('rv-in')
          io.unobserve(e.target)
        }
      },
      { rootMargin: '0px 0px -8% 0px', threshold: 0.12 },
    )
    els.forEach((el) => io.observe(el))
    return () => io.disconnect()
  })
}

/* Which section the reader is in, and how far down the page they are.
   Feeds the timecode rail: the page is scrubbed like a timeline. */
export function usePlayhead(ids) {
  const [state, setState] = useState({ active: ids[0], progress: 0 })

  useEffect(() => {
    let raf = 0
    const measure = () => {
      raf = 0
      const doc = document.documentElement
      const max = doc.scrollHeight - window.innerHeight
      const progress = max > 0 ? Math.min(1, Math.max(0, window.scrollY / max)) : 0
      const line = window.innerHeight * 0.38
      let active = ids[0]
      for (const id of ids) {
        const el = document.getElementById(id)
        if (el && el.getBoundingClientRect().top <= line) active = id
      }
      setState((prev) => (prev.active === active && Math.abs(prev.progress - progress) < 0.002 ? prev : { active, progress }))
    }
    const onScroll = () => {
      if (!raf) raf = requestAnimationFrame(measure)
    }
    measure()
    window.addEventListener('scroll', onScroll, { passive: true })
    window.addEventListener('resize', onScroll)
    return () => {
      window.removeEventListener('scroll', onScroll)
      window.removeEventListener('resize', onScroll)
      if (raf) cancelAnimationFrame(raf)
    }
  }, [ids])

  return state
}

export function useCopy() {
  const [copied, setCopied] = useState('')
  const copy = (text, key = 'x') => {
    navigator.clipboard?.writeText(text).then(() => {
      setCopied(key)
      setTimeout(() => setCopied(''), 1600)
    })
  }
  return [copied, copy]
}
