import { Key, Section } from '../ui/kit.jsx'

/* A still of the editor, drawn rather than screenshotted so it stays sharp and
   stays honest — the lanes, names and durations match what the app writes into
   a .mdsproj document. */

const SPAN = 26 // seconds shown
const pct = (s) => `${(s / SPAN) * 100}%`

const LANES = [
  {
    name: 'Video',
    kind: 'main',
    clips: [
      { start: 0, len: 10, label: 'Recording 19.04.35', tone: 'brand', badge: '1.0×' },
      { start: 10, len: 8, label: 'Recording 20.07.40', tone: 'brand', badge: '2.0×', selected: true },
      { start: 18, len: 5.4, label: 'dashboard.png', tone: 'still', badge: 'Ken Burns' },
    ],
  },
  {
    name: 'Overlays',
    kind: 'overlay',
    clips: [
      { start: 0.5, len: 3, label: 'Kosmico demo', tone: 'text' },
      { start: 12.4, len: 6.2, label: 'Webcam', tone: 'text' },
    ],
  },
  {
    name: 'Voiceover',
    kind: 'audio',
    clips: [{ start: 3.8, len: 9.6, label: 'voiceover-1784672012.wav', tone: 'audio', wave: true }],
  },
  {
    name: 'Music',
    kind: 'audio',
    clips: [{ start: 0, len: 23.4, label: 'bed.m4a', tone: 'audio', wave: true, quiet: true }],
  },
]

const TONES = {
  brand: 'bg-[linear-gradient(135deg,rgba(107,76,219,.85),rgba(59,155,245,.75))] text-white',
  still: 'bg-[linear-gradient(135deg,rgba(255,138,61,.7),rgba(240,68,122,.6))] text-white',
  text: 'bg-white/12 text-paper',
  audio: 'bg-[rgba(18,194,180,.22)] text-[#8ff0e6]',
}

const Wave = ({ quiet }) => (
  <svg viewBox="0 0 200 24" preserveAspectRatio="none" className="absolute inset-x-2 bottom-1 h-3 opacity-55">
    {Array.from({ length: 64 }, (_, i) => {
      const h = quiet
        ? 3 + ((i * 37) % 7)
        : 3 + ((i * 53) % 19) * (0.6 + 0.4 * Math.sin(i / 3.1))
      return (
        <rect key={i} x={i * 3.1} y={12 - h / 2} width="1.5" height={Math.max(1.5, h)} fill="currentColor" rx="0.7" />
      )
    })}
  </svg>
)

const SHORTCUTS = [
  [['Space'], 'Play or pause'],
  [['⌘', 'B'], 'Split at the playhead'],
  [['⌘', 'Z'], 'Undo'],
  [['⇧', '⌘', 'Z'], 'Redo'],
  [['⇧', '⌘', 'C'], 'Copy a clip’s look'],
  [['⇧', '⌘', 'V'], 'Paste it onto another'],
  [['⌥', '⌘', 'I'], 'Show or hide the inspector'],
  [['⇧', '⌘', 'M'], 'Connect an AI agent'],
]

const INSPECTOR = [
  ['Speed', '2.00×'],
  ['Volume', '100%'],
  ['Fade in / out', '0.0s / 0.4s'],
  ['Zoom', '1.6× · follow'],
  ['Padding', '6.8%'],
  ['Wallpaper', 'Nebula'],
]

export default function Editor() {
  return (
    <Section
      id="editor"
      tc="01:04"
      eyebrow="The editor"
      title="A timeline that cuts, not a filter that ships"
      lede="Projects assemble clips from the library alongside imported video, images and sound. Imported files are copied into the project, so an edit never breaks when you move the original."
    >
      <div className="rv card overflow-hidden p-0">
        <div className="flex flex-col gap-0 lg:flex-row">
          {/* timeline */}
          <div className="flex min-w-0 flex-1 flex-col p-5 sm:p-6">
            {/* ruler */}
            <div className="relative mb-2 ml-[5.25rem] h-5 border-b border-white/8">
              {Array.from({ length: 7 }, (_, i) => i * 4).map((s) => (
                <span key={s} className="absolute top-0 flex flex-col items-start" style={{ left: pct(s) }}>
                  <span className="font-mono text-[0.6rem] text-faint">
                    0:{String(s).padStart(2, '0')}
                  </span>
                </span>
              ))}
            </div>

            <div className="relative">
              {/* playhead */}
              <span
                className="pointer-events-none absolute -top-7 bottom-0 z-20 ml-[5.25rem] w-px bg-record"
                style={{ left: pct(12.4) }}
              >
                <span className="absolute -left-[0.3rem] -top-1 h-2 w-2 rotate-45 bg-record" />
              </span>

              {LANES.map((lane) => (
                <div key={lane.name} className="mb-1.5 flex items-stretch gap-3">
                  <div className="flex w-[4.5rem] shrink-0 flex-col justify-center">
                    <span className="truncate text-[0.78rem] font-medium">{lane.name}</span>
                    <span className="tech text-[0.55rem] text-faint">{lane.kind}</span>
                  </div>
                  <div
                    className="relative flex-1 rounded-lg bg-white/3"
                    style={{ height: lane.kind === 'audio' ? '2.6rem' : '3.1rem' }}
                  >
                    {lane.clips.map((c) => (
                      <div
                        key={c.label + c.start}
                        className={`absolute inset-y-0 overflow-hidden rounded-lg ${TONES[c.tone]} ${
                          c.selected ? 'ring-2 ring-paper ring-offset-2 ring-offset-panel' : ''
                        }`}
                        style={{ left: pct(c.start), width: pct(c.len) }}
                      >
                        <span className="absolute inset-x-2 top-1.5 truncate text-[0.7rem] font-medium">
                          {c.label}
                        </span>
                        {c.badge && (
                          <span className="absolute right-1.5 bottom-1.5 rounded bg-black/30 px-1.5 py-0.5 font-mono text-[0.58rem]">
                            {c.badge}
                          </span>
                        )}
                        {c.wave && <Wave quiet={c.quiet} />}
                        {c.selected && (
                          <>
                            <span className="absolute inset-y-1 left-1 w-1 rounded-full bg-paper/80" />
                            <span className="absolute inset-y-1 right-1 w-1 rounded-full bg-paper/80" />
                          </>
                        )}
                      </div>
                    ))}
                  </div>
                </div>
              ))}
            </div>

            <p className="mt-auto pt-6 text-[0.82rem] leading-relaxed text-faint">
              Speeding a clip up shortens that clip without moving the ones after it. Close gaps on the
              track when you want the timeline to tighten up.
            </p>
          </div>

          {/* inspector */}
          <aside className="w-full shrink-0 border-t border-white/8 bg-pit p-5 sm:p-6 lg:w-72 lg:border-l lg:border-t-0">
            <p className="tech mb-4 text-faint">Clip inspector</p>
            <p className="display-tight mb-1 font-bold">Recording 20.07.40</p>
            <p className="mb-5 font-mono text-[0.7rem] text-faint">10.0s → 18.0s</p>
            <dl className="space-y-3">
              {INSPECTOR.map(([k, v]) => (
                <div key={k} className="flex items-baseline justify-between gap-3 border-b border-white/6 pb-2.5">
                  <dt className="text-[0.82rem] text-muted">{k}</dt>
                  <dd className="font-mono text-[0.75rem] tabular-nums">{v}</dd>
                </div>
              ))}
            </dl>
            <p className="mt-5 text-[0.78rem] leading-relaxed text-faint">
              A per-clip look overrides the project default, so one clip can be zoomed and padded while
              the next stays plain.
            </p>
          </aside>
        </div>
      </div>

      <div className="mt-5 grid gap-5 lg:grid-cols-[1fr_1fr]">
        <div className="rv card p-6">
          <h3 className="display-tight text-lg font-bold">What you can do to a clip</h3>
          <ul className="mt-4 space-y-2.5 text-[0.92rem] leading-relaxed text-muted">
            {[
              'Drag to move it, drag either edge to trim it.',
              'Split at the playhead, ripple delete, close gaps on the track.',
              'Set speed from 0.25× to 4×, volume, and fades on both ends.',
              'Drop in videos, images with a Ken Burns move, and sounds.',
              'Add title cards on an overlay track.',
              'Play the timeline and record a webcam or voiceover take over it — the take lands at the playhead.',
              'Copy one clip’s look, volume, fades and placement onto another, or push a look onto every clip at once.',
            ].map((line) => (
              <li key={line} className="flex gap-3">
                <span className="mt-2 h-1 w-1 shrink-0 rounded-full bg-azure-glow" />
                {line}
              </li>
            ))}
          </ul>
        </div>

        <div className="rv card p-6" style={{ '--rv-d': '80ms' }}>
          <h3 className="display-tight text-lg font-bold">Shortcuts</h3>
          <dl className="mt-4 space-y-2.5">
            {SHORTCUTS.map(([keys, label]) => (
              <div key={label} className="flex items-center justify-between gap-4 border-b border-white/6 pb-2.5 last:border-0">
                <dt className="text-[0.9rem] text-muted">{label}</dt>
                <dd className="flex shrink-0 gap-1">
                  {keys.map((k) => (
                    <Key key={k}>{k}</Key>
                  ))}
                </dd>
              </div>
            ))}
          </dl>
        </div>
      </div>
    </Section>
  )
}
