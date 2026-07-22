import { useState } from 'react'
import Stage, { ASPECTS, WALLPAPERS } from '../stage/Stage.jsx'
import { useTake } from '../lib/useTake.js'
import { Section } from '../ui/kit.jsx'

const Slider = ({ label, value, min, max, step, onChange, format }) => (
  <label className="block">
    <span className="mb-2 flex items-baseline justify-between">
      <span className="text-sm text-muted">{label}</span>
      <span className="font-mono text-xs tabular-nums text-faint">{format(value)}</span>
    </span>
    <input
      type="range"
      className="slider"
      min={min}
      max={max}
      step={step}
      value={value}
      onChange={(e) => onChange(Number(e.target.value))}
    />
  </label>
)

const Segmented = ({ options, value, onChange }) => (
  <div className="flex rounded-xl border border-white/10 bg-white/4 p-1">
    {options.map(([key, label]) => (
      <button
        key={key}
        type="button"
        onClick={() => onChange(key)}
        className={`flex-1 rounded-lg px-2 py-2 text-xs font-medium transition-colors ${
          value === key ? 'bg-white/12 text-paper' : 'text-faint hover:text-paper/75'
        }`}
      >
        {label}
      </button>
    ))}
  </div>
)

/* The shape the app actually persists, with the keys it actually uses. */
const lookJSON = (look, zoomScale) =>
  `"defaultLook" : {
  "aspect"                : "${look.aspect}",
  "background"            : { "kind" : "wallpaper", "wallpaperIndex" : ${look.wallpaper} },
  "paddingFraction"       : ${look.padding.toFixed(3)},
  "cornerRadiusFraction"  : ${look.corner.toFixed(3)},
  "shadowOpacity"         : ${look.shadow.toFixed(2)},
  "zoomEnabled"           : ${zoomScale > 1.001},
  "zoomScale"             : ${zoomScale.toFixed(2)},
  "cursorScale"           : ${look.cursorScale.toFixed(1)},
  "captionsEnabled"       : ${Boolean(look.caption)}
}`

export default function Look() {
  const [look, setLook] = useState({
    padding: 0.068,
    corner: 0.018,
    shadow: 0.45,
    cursorScale: 2.4,
    wallpaper: 0,
    aspect: 'wide',
    caption: null,
  })
  const [zoomScale, setZoomScale] = useState(1.9)
  const set = (k) => (v) => setLook((l) => ({ ...l, [k]: v }))
  const take = useTake({ zoomScale })

  return (
    <Section
      id="look"
      tc="00:40"
      eyebrow="The look"
      title="Every value is a dial, not a decision"
      lede="Set it on the project and it applies to every clip; set it on one clip and that clip overrides the rest. Drag anything below — the frame is composited live, exactly as the export would be."
    >
      <div className="grid gap-6 lg:grid-cols-[1.55fr_1fr]">
        <div ref={take.hostRef} className="rv card flex flex-col overflow-hidden p-0">
          <div className="flex items-center justify-between border-b border-white/8 px-5 py-3">
            <span className="tech text-faint">Preview</span>
            <span className="font-mono text-[0.7rem] text-faint">
              {ASPECTS[look.aspect].label} · {take.camera.scale.toFixed(2)}×
            </span>
          </div>

          <div className="flex flex-1 items-center justify-center bg-pit p-4" style={{ minHeight: '18rem' }}>
            <Stage
              className="rounded-xl"
              maxHeight="30rem"
              scene={take.scene}
              camera={take.camera}
              cursor={take.cursor}
              pressed={take.pressed}
              look={look}
            />
          </div>

          {/* Every dial above is one of these numbers. Nothing is baked in. */}
          <pre className="overflow-x-auto border-t border-white/8 px-5 py-4 font-mono text-[0.7rem] leading-[1.75] text-faint">
            <code>{lookJSON(look, zoomScale)}</code>
          </pre>
        </div>

        <div className="rv card space-y-6 p-6" style={{ '--rv-d': '90ms' }}>
          <div>
            <p className="tech mb-3 text-faint">Wallpaper</p>
            <div className="grid grid-cols-4 gap-2">
              {WALLPAPERS.map((w, i) => (
                <button
                  key={w.name}
                  type="button"
                  title={w.name}
                  onClick={() => set('wallpaper')(i)}
                  className={`h-12 rounded-xl border-2 transition-all ${
                    look.wallpaper === i ? 'border-paper scale-[1.04]' : 'border-white/10 hover:border-white/30'
                  }`}
                  style={{ background: w.css }}
                >
                  <span className="sr-only">{w.name}</span>
                </button>
              ))}
            </div>
          </div>

          <div>
            <p className="tech mb-3 text-faint">Aspect</p>
            <Segmented
              options={Object.entries(ASPECTS).map(([k, v]) => [k, v.label])}
              value={look.aspect}
              onChange={set('aspect')}
            />
          </div>

          <div className="space-y-5">
            <Slider
              label="Padding"
              value={look.padding}
              min={0}
              max={0.16}
              step={0.002}
              onChange={set('padding')}
              format={(v) => `${(v * 100).toFixed(1)}%`}
            />
            <Slider
              label="Corner radius"
              value={look.corner}
              min={0}
              max={0.05}
              step={0.001}
              onChange={set('corner')}
              format={(v) => `${(v * 100).toFixed(1)}%`}
            />
            <Slider
              label="Shadow"
              value={look.shadow}
              min={0}
              max={0.9}
              step={0.01}
              onChange={set('shadow')}
              format={(v) => v.toFixed(2)}
            />
            <Slider
              label="Zoom"
              value={zoomScale}
              min={1}
              max={2.6}
              step={0.05}
              onChange={setZoomScale}
              format={(v) => `${v.toFixed(2)}×`}
            />
            <Slider
              label="Cursor size"
              value={look.cursorScale}
              min={1}
              max={5}
              step={0.1}
              onChange={set('cursorScale')}
              format={(v) => `${v.toFixed(1)}×`}
            />
          </div>

          <button
            type="button"
            onClick={() => set('caption')(look.caption ? null : 'Pick a region')}
            className={`flex w-full items-center justify-between rounded-xl border px-4 py-3 text-sm transition-colors ${
              look.caption
                ? 'border-azure-glow/40 bg-azure-glow/10 text-paper'
                : 'border-white/10 bg-white/4 text-muted hover:border-white/20'
            }`}
          >
            Burned-in captions
            <span className="tech">{look.caption ? 'on' : 'off'}</span>
          </button>

          <p className="text-[0.8rem] leading-relaxed text-faint">
            Captions come from on-device transcription with SpeechAnalyzer, then get rasterised into
            the frame — no separate subtitle file to lose.
          </p>
        </div>
      </div>
    </Section>
  )
}
