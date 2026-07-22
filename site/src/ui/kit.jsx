import { useCopy } from '../lib/fx.js'

export const REPO = 'https://github.com/Prot10/MyDemoStudio'

export const Section = ({ id, tc, eyebrow, title, lede, children, className = '' }) => (
  <section id={id} className={`relative mx-auto max-w-6xl px-6 py-20 sm:py-28 ${className}`}>
    {(eyebrow || title) && (
      <header className="rv mb-14 max-w-3xl">
        {eyebrow && (
          <p className="tech mb-5 flex items-center gap-3 text-faint">
            {tc && <span className="text-azure-glow/70">{tc}</span>}
            <span className="h-px w-8 bg-white/15" />
            {eyebrow}
          </p>
        )}
        {title && <h2 className="display text-[clamp(2.1rem,5.2vw,3.6rem)] font-extrabold">{title}</h2>}
        {lede && <p className="mt-5 text-lg leading-relaxed text-muted">{lede}</p>}
      </header>
    )}
    {children}
  </section>
)

export const Card = ({ className = '', children }) => (
  <div className={`card card-hover p-6 ${className}`}>{children}</div>
)

export const Key = ({ children }) => (
  <kbd className="inline-flex min-w-7 items-center justify-center rounded-md border border-white/12 bg-white/6 px-2 py-1 font-mono text-[0.72rem] font-medium text-paper/90 shadow-[0_1px_0_rgb(255_255_255/.06)_inset]">
    {children}
  </kbd>
)

export const Pill = ({ children, tone = 'neutral' }) => {
  const tones = {
    neutral: 'border-white/12 bg-white/5 text-muted',
    live: 'border-record/35 bg-record/10 text-record',
    blue: 'border-azure-glow/30 bg-azure-glow/10 text-azure-glow',
  }
  return (
    <span className={`tech inline-flex items-center gap-2 rounded-full border px-3 py-1.5 ${tones[tone]}`}>
      {children}
    </span>
  )
}

export const Button = ({ href, variant = 'primary', children, ...rest }) => {
  const base =
    'group inline-flex items-center gap-2.5 rounded-full px-6 py-3.5 text-[0.95rem] font-semibold transition-all duration-200'
  const styles = {
    primary: 'brand-grad text-white shadow-[0_10px_36px_-12px_rgb(107_76_219/.9)] hover:brightness-110 hover:-translate-y-0.5',
    ghost: 'border border-white/14 bg-white/4 text-paper hover:border-white/28 hover:bg-white/8',
  }
  return (
    <a href={href} className={`${base} ${styles[variant]}`} {...rest}>
      {children}
    </a>
  )
}

export function Code({ code, lang = 'sh', label, id = 'code' }) {
  const [copied, copy] = useCopy()
  return (
    <div className="card overflow-hidden">
      <div className="flex items-center justify-between border-b border-white/8 px-4 py-2.5">
        <span className="tech text-faint">{label ?? lang}</span>
        <button
          type="button"
          onClick={() => copy(code, id)}
          className="tech rounded-md px-2.5 py-1 text-faint transition-colors hover:bg-white/8 hover:text-paper"
        >
          {copied === id ? 'copied' : 'copy'}
        </button>
      </div>
      {/* Wraps rather than scrolls: a config snippet clipped mid-path reads as
          broken, and these are meant to be read as much as copied. */}
      <pre
        className="px-4 py-4 font-mono text-[0.8rem] leading-relaxed text-paper/85"
        style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}
      >
        <code>{code}</code>
      </pre>
    </div>
  )
}

/* Timecode formatting — the page's structural unit. */
export const tc = (seconds) => {
  const m = Math.floor(seconds / 60)
  const s = Math.floor(seconds % 60)
  return `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`
}
