import { useState } from 'react'
import Stage from '../stage/Stage.jsx'
import { useTake } from '../lib/useTake.js'
import { DURATION } from '../stage/script.js'
import { Button, Pill, REPO } from '../ui/kit.jsx'

const frames = (t) => {
  const m = Math.floor(t / 60)
  const s = Math.floor(t % 60)
  const f = Math.floor((t % 1) * 30)
  return `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}:${String(f).padStart(2, '0')}`
}

export default function Hero() {
  const [raw, setRaw] = useState(false)
  const take = useTake({ zoomScale: 1.9 })

  return (
    <header className="relative overflow-hidden pt-32 pb-20 sm:pt-40">
      {/* one slow light, sitting where the stage will be */}
      <div className="pointer-events-none absolute inset-x-0 -top-40 h-[38rem] opacity-55">
        <div className="aurora mx-auto h-full w-[75rem] max-w-[110vw] rounded-full bg-[radial-gradient(closest-side,rgba(107,76,219,.55),rgba(59,155,245,.18),transparent)] blur-3xl" />
      </div>

      <div className="relative mx-auto max-w-6xl px-6">
        <div className="max-w-4xl">
          <div className="line-mask" style={{ '--ld': '0ms' }}>
            <span>
              <Pill tone="live">
                <span className="rec-dot h-2 w-2 rounded-full bg-record" />
                Free · open source · macOS 26
              </Pill>
            </span>
          </div>

          <h1 className="display mt-7 text-[clamp(2.5rem,6.2vw,4.6rem)] font-extrabold">
            <span className="line-mask" style={{ '--ld': '90ms' }}>
              <span>Press record.</span>
            </span>
            <span className="line-mask" style={{ '--ld': '200ms' }}>
              <span className="brand-text">Get the polished cut.</span>
            </span>
          </h1>

          <div className="line-mask mt-7" style={{ '--ld': '340ms' }}>
            <span>
              <p className="max-w-2xl text-lg leading-relaxed text-muted sm:text-xl">
                MyDemoStudio keeps a pristine master of your screen alongside every cursor move, click
                and keystroke — then rebuilds the finished video from both. The camera follows your
                pointer, the backdrop is a mesh gradient, the cursor glides. Your recording is never
                touched.
              </p>
            </span>
          </div>

          <div className="line-mask mt-9" style={{ '--ld': '440ms' }}>
            <span>
              <div className="flex flex-wrap items-center gap-3">
                <Button href={`${REPO}#build`}>
                  Build it from source
                  <span className="transition-transform duration-200 group-hover:translate-x-0.5">→</span>
                </Button>
                <Button href="#how" variant="ghost">
                  How it works
                </Button>
              </div>
            </span>
          </div>
        </div>

        {/* ---- the stage ------------------------------------------------- */}
        <div ref={take.hostRef} className="rv mt-16" style={{ '--rv-d': '120ms' }}>
          <div className="rounded-[1.4rem] border border-white/10 bg-panel p-2 shadow-[0_40px_120px_-40px_rgba(0,0,0,.9)] sm:p-3">
            <Stage
              className="rounded-[0.9rem]"
              scene={take.scene}
              camera={take.camera}
              cursor={take.cursor}
              pressed={take.pressed}
              raw={raw}
              look={{ wallpaper: 0, caption: null }}
            />

            {/* transport */}
            <div className="mt-3 flex flex-wrap items-center gap-x-5 gap-y-3 px-2 pb-1 sm:px-3">
              <span className="flex items-center gap-2.5">
                <span className="rec-dot h-2.5 w-2.5 rounded-full bg-record" />
                <span className="font-mono text-xs tabular-nums text-paper/80">{frames(take.t)}</span>
                <span className="font-mono text-xs text-faint">/ {frames(DURATION)}</span>
              </span>

              {/* auto-zoom lane — the planner's own envelope, drawn live */}
              <span className="flex min-w-[13rem] flex-1 items-center gap-3">
                <span className="tech shrink-0 text-faint">auto-zoom</span>
                <span className="relative h-1.5 flex-1 rounded-full bg-white/8">
                  {take.segments.map((s) => (
                    <span
                      key={s.rampInStart}
                      className="absolute inset-y-0 rounded-full transition-colors duration-200"
                      style={{
                        left: `${(s.rampInStart / DURATION) * 100}%`,
                        width: `${((s.rampOutEnd - s.rampInStart) / DURATION) * 100}%`,
                        background:
                          take.t >= s.rampInStart && take.t <= s.rampOutEnd
                            ? 'linear-gradient(90deg,#6b4cdb,#3b9bf5)'
                            : 'rgba(255,255,255,.16)',
                      }}
                    />
                  ))}
                  <span
                    className="absolute -top-1 h-3.5 w-px bg-paper/70"
                    style={{ left: `${(take.t / DURATION) * 100}%` }}
                  />
                </span>
                <span className="font-mono text-xs tabular-nums text-faint">
                  {take.camera.scale.toFixed(2)}×
                </span>
              </span>

              {/* raw vs polished */}
              <span className="flex rounded-full border border-white/12 bg-white/4 p-0.5">
                {[
                  ['Raw capture', true],
                  ['Re-rendered', false],
                ].map(([label, isRaw]) => (
                  <button
                    key={label}
                    type="button"
                    onClick={() => setRaw(isRaw)}
                    className={`tech rounded-full px-3 py-1.5 transition-colors ${
                      raw === isRaw ? 'bg-white/12 text-paper' : 'text-faint hover:text-paper/70'
                    }`}
                  >
                    {label}
                  </button>
                ))}
              </span>
            </div>
          </div>

          <p className="mt-4 text-center text-sm text-faint">
            Not a video. The camera above is running the app's own zoom planner on a synthetic click
            track — {take.zoomed ? 'holding' : 'idle'} at {take.camera.scale.toFixed(2)}×.
          </p>
        </div>
      </div>
    </header>
  )
}
