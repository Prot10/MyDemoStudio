import { REPO } from '../ui/kit.jsx'

const STACK = ['Swift 6.2', 'SwiftUI', 'ScreenCaptureKit', 'Metal', 'AVFoundation', 'SpeechAnalyzer', 'MCP']

const LINKS = [
  ['Docs', `${REPO}/tree/main/docs`],
  ['Roadmap', `${REPO}/blob/main/ROADMAP.md`],
  ['Changelog', `${REPO}/blob/main/CHANGELOG.md`],
  ['Contributing', `${REPO}/blob/main/CONTRIBUTING.md`],
  ['Issues', `${REPO}/issues`],
]

const SUPPORT = [
  ['Star it on GitHub', REPO],
  ['PayPal', 'https://paypal.me/andreaprotani99'],
  ['Buy me a coffee', 'https://buymeacoffee.com/prot10'],
]

export default function Footer() {
  return (
    <footer className="relative border-t border-white/8 bg-pit">
      {/* the ticker: what comes out the other end */}
      <div className="overflow-hidden border-b border-white/8 py-4">
        <div className="ticker-track">
          {[0, 1].map((dup) => (
            <div key={dup} className="flex shrink-0 items-center" aria-hidden={dup === 1}>
              {STACK.concat(['4K', '1080p', '720p', 'MP4', 'MOV', 'GIF', '16:9', '9:16', '1:1']).map((word) => (
                <span key={word} className="flex items-center">
                  <span className="tech px-6 text-faint">{word}</span>
                  <span className="h-1 w-1 rounded-full bg-white/12" />
                </span>
              ))}
            </div>
          ))}
        </div>
      </div>

      <div className="mx-auto max-w-6xl px-6 py-14">
        <div className="grid gap-10 sm:grid-cols-2 lg:grid-cols-4">
          <div className="lg:col-span-2">
            <a href="#top" className="flex items-center gap-2.5">
              <img src="./icon-256.png" alt="" width="32" height="32" className="rounded-lg" />
              <span className="display-tight text-lg font-bold">MyDemoStudio</span>
            </a>
            <p className="mt-4 max-w-sm text-[0.9rem] leading-relaxed text-faint">
              A native macOS screen recorder that re-renders your capture into a finished product demo.
              Built by Andrea Protani, alongside MyMacCleaner and MyTripPlanner.
            </p>
          </div>

          <nav>
            <p className="tech mb-4 text-faint">Project</p>
            <ul className="space-y-2.5">
              {LINKS.map(([label, href]) => (
                <li key={label}>
                  <a href={href} className="text-[0.9rem] text-muted transition-colors hover:text-paper">
                    {label}
                  </a>
                </li>
              ))}
            </ul>
          </nav>

          <nav>
            <p className="tech mb-4 text-faint">Support</p>
            <ul className="space-y-2.5">
              {SUPPORT.map(([label, href]) => (
                <li key={label}>
                  <a href={href} className="text-[0.9rem] text-muted transition-colors hover:text-paper">
                    {label}
                  </a>
                </li>
              ))}
            </ul>
          </nav>
        </div>

        <div className="mt-12 flex flex-wrap items-center justify-between gap-4 border-t border-white/8 pt-6">
          <p className="text-[0.8rem] text-faint">AGPL-3.0 · runs entirely on your machine</p>
          <p className="text-[0.8rem] text-faint">
            Not affiliated with Screen Studio or Apple.
          </p>
        </div>
      </div>
    </footer>
  )
}
