import { useEffect, useState } from 'react'
import { REPO } from './kit.jsx'

const LINKS = [
  ['How it works', '#how'],
  ['The look', '#look'],
  ['Editor', '#editor'],
  ['Agents', '#agents'],
  ['Get it', '#get'],
]

export default function Nav() {
  const [stuck, setStuck] = useState(false)
  const [open, setOpen] = useState(false)

  useEffect(() => {
    const onScroll = () => setStuck(window.scrollY > 24)
    onScroll()
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [])

  return (
    <nav
      className={`fixed inset-x-0 top-0 z-50 transition-colors duration-300 ${
        stuck ? 'border-b border-white/8 bg-void/78 backdrop-blur-xl' : 'border-b border-transparent'
      }`}
    >
      <div className="mx-auto flex max-w-6xl items-center gap-6 px-6 py-4">
        <a href="#top" className="flex items-center gap-2.5 font-semibold">
          <img src="./icon-256.png" alt="" width="28" height="28" className="rounded-[0.5rem]" />
          <span className="display-tight text-[1.05rem]">MyDemoStudio</span>
        </a>

        <div className="ml-auto hidden items-center gap-1 md:flex">
          {LINKS.map(([label, href]) => (
            <a
              key={href}
              href={href}
              className="rounded-full px-3.5 py-2 text-sm text-muted transition-colors hover:bg-white/6 hover:text-paper"
            >
              {label}
            </a>
          ))}
        </div>

        <a
          href={REPO}
          className="ml-auto inline-flex items-center gap-2 rounded-full border border-white/14 bg-white/5 px-4 py-2 text-sm font-medium transition-colors hover:border-white/28 hover:bg-white/9 md:ml-0"
        >
          <svg viewBox="0 0 16 16" width="15" height="15" fill="currentColor" aria-hidden="true">
            <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.4 7.4 0 0 1 2-.27c.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z" />
          </svg>
          GitHub
        </a>

        <button
          type="button"
          onClick={() => setOpen((v) => !v)}
          aria-label="Menu"
          aria-expanded={open}
          className="rounded-full border border-white/14 bg-white/5 px-3 py-2 text-sm md:hidden"
        >
          {open ? '×' : '≡'}
        </button>
      </div>

      {open && (
        <div className="border-t border-white/8 bg-void/95 px-6 pb-5 backdrop-blur-xl md:hidden">
          {LINKS.map(([label, href]) => (
            <a
              key={href}
              href={href}
              onClick={() => setOpen(false)}
              className="block border-b border-white/6 py-3.5 text-sm text-muted last:border-0"
            >
              {label}
            </a>
          ))}
        </div>
      )}
    </nav>
  )
}
