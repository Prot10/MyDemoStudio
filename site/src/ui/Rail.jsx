import { useMemo } from 'react'
import { usePlayhead } from '../lib/fx.js'

/* The page is a timeline, so its navigation is a ruler.

   Each section is a marker at its own timecode and the reader's scroll position
   is the playhead. It only appears where there is room for it to sit outside the
   text column. */
export default function Rail({ marks }) {
  const ids = useMemo(() => marks.map((m) => m.id), [marks])
  const { active, progress } = usePlayhead(ids)

  return (
    <aside
      aria-hidden="true"
      className="pointer-events-none fixed left-4 top-1/2 z-40 hidden -translate-y-1/2 xl:block 2xl:left-8"
    >
      <div className="relative flex flex-col gap-7 pl-5">
        <span className="absolute left-0 top-1 bottom-1 w-px bg-white/10" />
        <span
          className="absolute left-0 top-1 w-px bg-gradient-to-b from-violet-glow to-azure-glow transition-[height] duration-150"
          style={{ height: `calc(${progress * 100}% - 2px)` }}
        />
        {marks.map((m) => {
          const on = active === m.id
          return (
            <a
              key={m.id}
              href={`#${m.id}`}
              className="pointer-events-auto group relative flex items-center gap-3"
            >
              <span
                className={`-ml-[1.375rem] h-px transition-all duration-300 ${
                  on ? 'w-4 bg-azure-glow' : 'w-2 bg-white/20 group-hover:w-3.5 group-hover:bg-white/45'
                }`}
              />
              <span
                className={`font-mono text-[0.65rem] tabular-nums transition-colors duration-300 ${
                  on ? 'text-paper' : 'text-faint group-hover:text-muted'
                }`}
              >
                {m.tc}
              </span>
              {/* The label sits outside the flow so the rail keeps a fixed,
                  narrow footprint and never crowds the content column. */}
              <span
                className={`absolute left-full ml-2 hidden whitespace-nowrap text-[0.7rem] transition-opacity duration-300 2xl:block ${
                  on ? 'text-muted opacity-100' : 'opacity-0 group-hover:opacity-60'
                }`}
              >
                {m.label}
              </span>
            </a>
          )
        })}
      </div>
    </aside>
  )
}
