import Stage from '../stage/Stage.jsx'
import { sceneAt } from '../stage/script.js'
import { Section } from '../ui/kit.jsx'

const EVENTS = `{
  "displayWidthPoints" : 1728,
  "displayHeightPoints" : 1004,
  "events" : [
    { "t" : 4.238, "type" : "mouseMoved", "x" : 612.4, "y" : 381.0 },
    { "t" : 4.246, "type" : "mouseMoved", "x" : 618.9, "y" : 379.7 },
    { "t" : 4.301, "type" : "mouseDown",  "x" : 621.0, "y" : 379.1 },
    { "t" : 4.388, "type" : "mouseUp",    "x" : 621.0, "y" : 379.1 },
    { "t" : 5.902, "type" : "keyDown",    "x" : 621.0, "y" : 379.1 }
  ]
}`

const LAYERS = [
  ['Wallpaper', 'procedural mesh gradient, optionally blurred'],
  ['Capture', 'rounded corners, padded into the canvas'],
  ['Shadow', 'soft drop shadow behind the plate'],
  ['Camera', 'scale + focus, clamped in bounds'],
  ['Cursor', 'arrow or hand sprite, constant size'],
  ['Caption', 'text rasterised through Core Text'],
]

const STILL = { scale: 1, fx: 0.5, fy: 0.5 }
const NOWHERE = { x: -1, y: -1 }

export default function Pipeline() {
  return (
    <Section
      id="how"
      tc="00:12"
      eyebrow="How it works"
      title={
        <>
          Record raw.
          <br />
          Re-render everything.
        </>
      }
      lede="Most screen recorders bake their effects into the file as they capture. This one writes down what happened instead, and applies the effects at the very end — so every decision stays reversible for as long as you keep the recording."
    >
      <div className="grid gap-5 lg:grid-cols-3">
        {/* 1 — the master */}
        <article className="rv card flex flex-col overflow-hidden p-0">
          <div className="border-b border-white/8 px-5 py-3">
            <span className="font-mono text-xs text-azure-glow/80">master.mov</span>
          </div>
          <div className="p-5">
            <h3 className="display-tight text-xl font-bold">A pristine capture</h3>
            <p className="mt-2.5 text-[0.95rem] leading-relaxed text-muted">
              ScreenCaptureKit writes the display — or one window, cropped from the display so its
              chrome renders normally — at full resolution, with the system cursor hidden. Nothing is
              drawn on top of it, then or ever.
            </p>
          </div>
          <div className="mt-auto overflow-hidden rounded-b-2xl border-t border-white/8 bg-black">
            <Stage raw scene={sceneAt(0)} camera={STILL} cursor={NOWHERE} />
          </div>
        </article>

        {/* 2 — the log */}
        <article className="rv card flex flex-col overflow-hidden p-0" style={{ '--rv-d': '80ms' }}>
          <div className="border-b border-white/8 px-5 py-3">
            <span className="font-mono text-xs text-azure-glow/80">events.json</span>
          </div>
          <div className="p-5">
            <h3 className="display-tight text-xl font-bold">Everything you did</h3>
            <p className="mt-2.5 text-[0.95rem] leading-relaxed text-muted">
              A <code className="font-mono text-[0.85em] text-paper/80">CGEventTap</code> logs every
              move, click and keystroke, stamped on the mach host clock and anchored to the first
              delivered frame — so the log and the picture agree to the millisecond.
            </p>
          </div>
          <pre className="mt-auto overflow-x-auto border-t border-white/8 bg-pit px-5 py-4 font-mono text-[0.68rem] leading-[1.7] text-paper/70">
            <code>{EVENTS}</code>
          </pre>
        </article>

        {/* 3 — the render */}
        <article className="rv card flex flex-col overflow-hidden p-0" style={{ '--rv-d': '160ms' }}>
          <div className="border-b border-white/8 px-5 py-3">
            <span className="font-mono text-xs text-azure-glow/80">one Metal pass</span>
          </div>
          <div className="p-5">
            <h3 className="display-tight text-xl font-bold">Rebuilt on the GPU</h3>
            <p className="mt-2.5 text-[0.95rem] leading-relaxed text-muted">
              At preview and at export, a single fragment shader composes the whole frame. Preview
              and export run the same compositor, so what you scrub through is what lands on disk.
            </p>
          </div>
          <ol className="mt-auto border-t border-white/8 bg-pit p-3">
            {LAYERS.map(([name, detail], i) => (
              <li
                key={name}
                className="flex items-baseline gap-3 rounded-lg px-2.5 py-[0.45rem]"
                style={{ background: `rgba(255,255,255,${0.02 + i * 0.012})` }}
              >
                <span className="font-mono text-[0.65rem] text-faint">{i + 1}</span>
                <span className="text-sm font-medium">{name}</span>
                <span className="ml-auto hidden text-right text-[0.72rem] text-faint sm:block lg:hidden xl:block">
                  {detail}
                </span>
              </li>
            ))}
          </ol>
        </article>
      </div>

      <div className="rv mt-5 grid gap-5 sm:grid-cols-3">
        {[
          [
            'Change your mind later',
            'Padding, corner radius, wallpaper, zoom strength, cursor size — all of it is a number in a JSON file, not a pixel in a video.',
          ],
          [
            'The original survives',
            'Recordings live in ~/Movies/MyDemoStudio and are only ever referenced. Projects never move or rewrite them.',
          ],
          [
            'Anything can drive it',
            'Because the edit is data, an AI agent can make the same edits you would — and the open project reloads them live.',
          ],
        ].map(([title, body]) => (
          <div key={title} className="card card-hover p-6">
            <h4 className="display-tight font-bold">{title}</h4>
            <p className="mt-2 text-[0.92rem] leading-relaxed text-muted">{body}</p>
          </div>
        ))}
      </div>
    </Section>
  )
}
