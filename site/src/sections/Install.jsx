import { Button, Code, Key, REPO, Section } from '../ui/kit.jsx'

const BUILD = `git clone https://github.com/Prot10/MyDemoStudio.git
cd MyDemoStudio

# one-off: the shader compiler
xcodebuild -downloadComponent MetalToolchain

xcodebuild -project MyDemoStudio.xcodeproj \\
  -scheme MyDemoStudio -configuration Release \\
  -allowProvisioningUpdates build`

const STEPS = [
  {
    title: 'Build it',
    body: 'There is no signed release yet, so you build it yourself. Two commands, once.',
  },
  {
    title: 'Move it to /Applications',
    body: 'Run it from a stable path. macOS ties permission grants to where the app lives, so moving it later means granting again.',
  },
  {
    title: 'Grant three permissions',
    body: 'Screen Recording and Accessibility are required; Camera and Microphone only if you want a webcam bubble or a voiceover. Screen Recording takes effect after a relaunch — the app has a button that does it for you.',
  },
]

const REQUIREMENTS = [
  ['macOS', '26 or later'],
  ['Xcode', '26'],
  ['Extra', 'Metal Toolchain component'],
  ['Licence', 'AGPL-3.0'],
]

export default function Install() {
  return (
    <Section
      id="get"
      tc="01:56"
      eyebrow="Get it"
      title="Free, and it stays that way"
      lede="MyDemoStudio exists because a polished demo video should not cost a subscription. It is open source, runs entirely on your machine, and sends nothing anywhere."
    >
      <div className="grid gap-5 lg:grid-cols-[1.1fr_1fr]">
        <div className="rv">
          <Code code={BUILD} label="terminal" id="build" />
          <div className="mt-5 grid grid-cols-2 gap-3 sm:grid-cols-4">
            {REQUIREMENTS.map(([k, v]) => (
              <div key={k} className="card p-4">
                <p className="tech text-faint">{k}</p>
                <p className="mt-1.5 text-[0.92rem] font-medium">{v}</p>
              </div>
            ))}
          </div>
        </div>

        <ol className="rv space-y-3" style={{ '--rv-d': '80ms' }}>
          {STEPS.map((s, i) => (
            <li key={s.title} className="card flex gap-4 p-5">
              <span className="mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-full border border-white/12 font-mono text-[0.7rem] text-muted">
                {i + 1}
              </span>
              <div>
                <h3 className="display-tight font-bold">{s.title}</h3>
                <p className="mt-1.5 text-[0.9rem] leading-relaxed text-muted">{s.body}</p>
              </div>
            </li>
          ))}
        </ol>
      </div>

      {/* validation */}
      <div className="rv mt-5 card p-6 sm:p-8">
        <div className="grid gap-8 lg:grid-cols-[1fr_1.1fr]">
          <div>
            <h3 className="display-tight text-xl font-bold">It proves itself headlessly</h3>
            <p className="mt-3 text-[0.95rem] leading-relaxed text-muted">
              The render pipeline is validated by rendering real files and reading the pixels and audio
              samples back out — no GUI, no clicking. There is also a stability run that resizes the
              window, drags the split dividers and hammers edit / undo / split / seek against a live
              editor for sixty rounds.
            </p>
            <div className="mt-5 flex flex-wrap items-center gap-2 text-[0.85rem] text-faint">
              Set <Key>MDS_SELFTEST</Key> and launch the binary directly.
            </div>
          </div>
          <div className="space-y-2">
            {[
              ['algo', 'zoom and cursor maths, instant, no recording'],
              ['timeline', 'multi-clip render and export'],
              ['editor', 'editor glue, undo, autosave'],
              ['1', 'the full record → export loop, needs permissions'],
            ].map(([flag, what]) => (
              <div key={flag} className="flex items-baseline gap-4 rounded-lg border border-white/8 bg-pit px-4 py-3">
                <code className="shrink-0 font-mono text-[0.78rem] text-azure-glow/85">
                  MDS_SELFTEST={flag}
                </code>
                <span className="text-[0.82rem] text-faint">{what}</span>
              </div>
            ))}
          </div>
        </div>
      </div>

      <div className="rv mt-5 flex flex-wrap items-center gap-3">
        <Button href={REPO}>
          View the source
          <span className="transition-transform duration-200 group-hover:translate-x-0.5">→</span>
        </Button>
        <Button href={`${REPO}/tree/main/docs`} variant="ghost">
          Read the docs
        </Button>
      </div>
    </Section>
  )
}
