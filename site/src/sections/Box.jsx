import { Section } from '../ui/kit.jsx'

/* Bento — the capture side of the app. Each tile carries a small drawn figure
   rather than an icon, because what differs between these features is shape:
   a window versus a circle versus a waveform. */

const Tile = ({ className = '', title, children, figure }) => (
  <div className={`card card-hover flex flex-col overflow-hidden p-0 ${className}`}>
    <div className="flex-1 p-6">
      <h3 className="display-tight text-lg font-bold">{title}</h3>
      <p className="mt-2.5 text-[0.92rem] leading-relaxed text-muted">{children}</p>
    </div>
    {figure && <div className="border-t border-white/8 bg-pit px-6 py-5">{figure}</div>}
  </div>
)

const WindowPicker = () => (
  <div className="space-y-1.5">
    {[
      ['Entire display', '3456 × 2008', false],
      ['Xcode — MyDemoStudio.xcodeproj', '1712 × 1042', true],
      ['Safari — Pricing', '1440 × 900', false],
    ].map(([name, size, on]) => (
      <div
        key={name}
        className={`flex items-center gap-3 rounded-lg px-3 py-2 text-[0.78rem] ${
          on ? 'bg-white/10 text-paper' : 'text-faint'
        }`}
      >
        <span className={`h-2.5 w-3.5 shrink-0 rounded-[2px] border ${on ? 'border-azure-glow bg-azure-glow/30' : 'border-white/20'}`} />
        <span className="truncate">{name}</span>
        <span className="ml-auto shrink-0 font-mono text-[0.65rem]">{size}</span>
      </div>
    ))}
  </div>
)

const Bubble = () => (
  <div className="relative h-20 overflow-hidden rounded-lg brand-grad">
    <span className="absolute left-3 bottom-3 h-14 w-14 rounded-full border-2 border-white/70 bg-[radial-gradient(circle_at_40%_35%,#f0c9a8,#8c5a3c)] shadow-[0_6px_18px_rgba(0,0,0,.4)]" />
    <span className="absolute right-3 top-3 tech text-white/70">bottom leading · 20%</span>
  </div>
)

const Waveform = () => (
  <svg viewBox="0 0 240 40" className="h-12 w-full text-[#12c2b4]" preserveAspectRatio="none">
    {Array.from({ length: 78 }, (_, i) => {
      const h = 4 + ((i * 47) % 26) * (0.45 + 0.55 * Math.abs(Math.sin(i / 5.4)))
      return <rect key={i} x={i * 3.1} y={20 - h / 2} width="1.6" height={h} rx="0.8" fill="currentColor" />
    })}
  </svg>
)

const Sfx = () => (
  <div className="flex items-end gap-1.5">
    {[3, 7, 14, 22, 13, 6, 3, 5, 11, 19, 26, 15, 7, 3].map((h, i) => (
      <span
        key={i}
        className="w-full rounded-sm bg-gradient-to-t from-record/25 to-record/80"
        style={{ height: `${h * 1.6}px` }}
      />
    ))}
  </div>
)

const CaptionPill = () => (
  <div className="flex h-12 items-center justify-center rounded-lg bg-black/50">
    <span className="rounded-full bg-black/80 px-3.5 py-1.5 text-[0.82rem] font-bold text-white">
      pick a region
    </span>
  </div>
)

const Formats = () => (
  <div className="grid grid-cols-3 gap-2">
    {[
      ['MP4', 'plays everywhere'],
      ['MOV', 'QuickTime'],
      ['GIF', '16 fps, no audio'],
    ].map(([f, d]) => (
      <div key={f} className="rounded-lg border border-white/8 bg-white/4 px-3 py-2.5">
        <p className="display-tight font-bold">{f}</p>
        <p className="mt-0.5 text-[0.65rem] leading-tight text-faint">{d}</p>
      </div>
    ))}
  </div>
)

export default function Box() {
  return (
    <Section
      id="box"
      tc="00:26"
      eyebrow="Capture"
      title="Record once, with everything you need on the take"
      lede="Picture, voice, face and sound all land in the same package, timestamped against the same clock."
    >
      <div className="grid gap-5 md:grid-cols-2 lg:grid-cols-3">
        <Tile
          className="rv lg:col-span-2"
          title="The whole screen, or one window"
          figure={<WindowPicker />}
        >
          Pick a display or a single app window. Windows are captured as a crop of the display, so
          traffic lights, shadows and rounded corners render the way they actually look — no macOS
          share pill, no missing chrome.
        </Tile>

        <Tile className="rv" title="Webcam bubble" figure={<Bubble />}>
          A circular camera overlay in any corner, at any size. Center-cropped and mirrored, with a
          ring, composited by the same shader as everything else.
        </Tile>

        <Tile className="rv" title="Voiceover" figure={<Waveform />}>
          Record the mic while you capture, or play the timeline back and talk over it afterwards —
          the take lands at the playhead as an audio clip.
        </Tile>

        <Tile className="rv" title="Clicks and keystrokes" figure={<Sfx />}>
          Soft synthesised click and key sounds, mixed into the export at the exact moments the event
          log says they happened. Off by default, one toggle away.
        </Tile>

        <Tile className="rv" title="Captions, on device" figure={<CaptionPill />}>
          SpeechAnalyzer transcribes the voiceover locally and the text is rasterised straight into
          the frame. Nothing leaves the machine, nothing to upload.
        </Tile>

        <Tile className="rv md:col-span-2 lg:col-span-3" title="Export" figure={<Formats />}>
          4K, 1080p or 720p — resolutions are caps applied to the editing canvas, so they never upscale
          past what you recorded. Choose 16:9, 9:16, 1:1 or the original aspect, and save it wherever
          you want.
        </Tile>
      </div>
    </Section>
  )
}
