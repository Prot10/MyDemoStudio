/* The app being recorded.

   A small deploy console, built so that every click target is a detail you
   genuinely cannot read until the camera pushes in — which is the whole
   argument for auto-zoom. Everything is positioned in percentages of the
   captured frame so the pointer script can address it by coordinate, and sized
   in `em` where 1em = 1cqw, so it scales with the stage. */

import { memo } from 'react'

const NAV = [
  { id: 'overview', label: 'Overview' },
  { id: 'environments', label: 'Environments' },
  { id: 'releases', label: 'Releases' },
  { id: 'logs', label: 'Logs' },
]

const REGIONS = ['us-east-1', 'eu-central-1', 'ap-south-1']

const LOG = [
  ['12:04:18', 'Resolved 4 services from northwind.yaml'],
  ['12:04:19', 'Image digest sha256:9f2c…a417 verified'],
  ['12:04:21', 'Health probe /readyz responded in 42 ms'],
]

const Abs = ({ l, t, w, h, className = '', style, children }) => (
  <div
    className={className}
    style={{
      position: 'absolute',
      left: `${l}%`,
      top: `${t}%`,
      width: w != null ? `${w}%` : undefined,
      height: h != null ? `${h}%` : undefined,
      ...style,
    }}
  >
    {children}
  </div>
)

function RecordedApp({ scene }) {
  return (
    <div
      className="absolute inset-0 overflow-hidden bg-[#14151d] text-[#e8e9f2]"
      style={{ containerType: 'inline-size' }}
    >
      <div className="absolute inset-0" style={{ fontSize: '1cqw' }}>
        {/* title bar */}
        <Abs l={0} t={0} w={100} h={7} className="bg-[#1c1d27] border-b border-white/6" />
        <Abs l={2.2} t={2.4} className="flex gap-[0.8em]">
          {['#ff5f57', '#febc2e', '#28c840'].map((c) => (
            <span
              key={c}
              className="block rounded-full"
              style={{ width: '1.15em', height: '1.15em', background: c }}
            />
          ))}
        </Abs>
        <Abs l={40} t={2.1} className="text-white/35" style={{ fontSize: '1.45em' }}>
          northwind · production
        </Abs>

        {/* sidebar */}
        <Abs l={0} t={7} w={26} h={93} className="bg-[#0e0f16] border-r border-white/6" />
        <Abs l={5} t={11.5} className="flex items-center" style={{ gap: '0.7em' }}>
          <span className="brand-grad block rounded-[0.35em]" style={{ width: '2em', height: '2em' }} />
          <span className="font-semibold" style={{ fontSize: '1.7em' }}>
            Northwind
          </span>
        </Abs>

        {NAV.map((item, i) => {
          const active = scene.nav === item.id
          return (
            <Abs
              key={item.id}
              l={4}
              t={22.5 + i * 11.5}
              w={19}
              h={7.6}
              className={`flex items-center rounded-[0.55em] transition-colors duration-200 ${
                active ? 'bg-white/10 text-white' : 'text-white/45'
              }`}
              style={{ paddingLeft: '1.4em', gap: '0.9em' }}
            >
              <span
                className={`block rounded-[0.2em] ${active ? 'bg-azure-glow' : 'bg-white/25'}`}
                style={{ width: '1.05em', height: '1.05em' }}
              />
              <span style={{ fontSize: '1.5em' }}>{item.label}</span>
            </Abs>
          )
        })}

        <Abs l={4} t={88} w={19} h={7} className="flex items-center rounded-[0.55em] bg-white/4" style={{ paddingLeft: '1.4em', gap: '0.8em' }}>
          <span className="block rounded-full bg-[#28c840]" style={{ width: '0.85em', height: '0.85em' }} />
          <span className="text-white/40" style={{ fontSize: '1.25em' }}>
            All systems normal
          </span>
        </Abs>

        {/* main pane */}
        <Abs l={30} t={12.5} className="tech text-white/30" style={{ fontSize: '1.15em', letterSpacing: '0.18em' }}>
          ENVIRONMENT
        </Abs>
        <Abs l={30} t={16.5} className="font-semibold" style={{ fontSize: '3.1em', letterSpacing: '-0.02em' }}>
          Deploy
        </Abs>

        {/* region */}
        <Abs l={30} t={30.4} className="text-white/50" style={{ fontSize: '1.5em' }}>
          Region
        </Abs>
        <Abs
          l={50}
          t={27.6}
          w={22}
          h={8.4}
          className={`flex items-center justify-between rounded-[0.6em] border transition-colors duration-200 ${
            scene.dropdown ? 'border-azure-glow/70 bg-[#1e2030]' : 'border-white/12 bg-[#1a1b25]'
          }`}
          style={{ paddingLeft: '1.3em', paddingRight: '1.3em' }}
        >
          <span style={{ fontSize: '1.5em' }}>{scene.region}</span>
          <span className="text-white/35" style={{ fontSize: '1.2em' }}>
            ▾
          </span>
        </Abs>

        {scene.dropdown && (
          <Abs
            l={50}
            t={37.2}
            w={22}
            h={19.8}
            className="rounded-[0.6em] border border-white/12 bg-[#1e2030] overflow-hidden"
            style={{ boxShadow: '0 1.2em 3em rgb(0 0 0 / .55)' }}
          >
            {REGIONS.map((r) => (
              <div
                key={r}
                className={`flex items-center ${r === 'eu-central-1' ? 'bg-white/8' : ''}`}
                style={{ height: '33.33%', paddingLeft: '1.3em', fontSize: '1.5em' }}
              >
                {r}
              </div>
            ))}
          </Abs>
        )}

        {/* auto-rollback */}
        <Abs l={30} t={54.2} className="text-white/50" style={{ fontSize: '1.5em' }}>
          Auto-rollback
        </Abs>
        <Abs
          l={80}
          t={52.8}
          w={9}
          h={5.6}
          className={`rounded-full transition-colors duration-300 ${
            scene.rollback ? 'bg-azure-glow' : 'bg-white/14'
          }`}
        >
          <span
            className="absolute rounded-full bg-white transition-all duration-300"
            style={{
              width: '2.1em',
              height: '2.1em',
              top: '50%',
              transform: 'translateY(-50%)',
              left: scene.rollback ? 'calc(100% - 2.45em)' : '0.35em',
            }}
          />
        </Abs>

        {/* log */}
        <Abs
          l={30}
          t={63}
          w={62}
          h={11}
          className="rounded-[0.6em] border border-white/8 bg-[#0f1017] overflow-hidden"
          style={{ padding: '1em 1.2em' }}
        >
          {LOG.map(([time, line]) => (
            <div key={time} className="flex text-white/40" style={{ fontSize: '1.15em', gap: '1em', lineHeight: 1.85 }}>
              <span className="font-mono text-white/25">{time}</span>
              <span className="truncate">{line}</span>
            </div>
          ))}
        </Abs>

        {/* deploy */}
        <Abs
          l={76}
          t={76}
          w={17}
          h={8}
          className={`flex items-center justify-center rounded-[0.6em] font-semibold transition-all duration-200 ${
            scene.deploy > 0 ? 'bg-white/12 text-white/55' : 'brand-grad text-white'
          }`}
          style={{ fontSize: '1.5em' }}
        >
          {scene.deploy > 0 ? (scene.deploy >= 1 ? 'Deployed' : 'Deploying…') : 'Deploy'}
        </Abs>

        <Abs l={30} t={87.5} w={62} h={1.3} className="rounded-full bg-white/8 overflow-hidden">
          <span
            className="brand-grad absolute inset-y-0 left-0 rounded-full"
            style={{ width: `${scene.deploy * 100}%`, transition: 'width 120ms linear' }}
          />
        </Abs>
        <Abs l={30} t={91} className="text-white/30" style={{ fontSize: '1.15em' }}>
          {scene.deploy > 0
            ? `${Math.round(scene.deploy * 4)} of 4 services · ${scene.region}`
            : `4 services queued · ${scene.region}`}
        </Abs>
      </div>
    </div>
  )
}

/* Re-renders 60 times a second otherwise; the captured app only changes on a click. */
export default memo(RecordedApp, (a, b) => {
  const x = a.scene
  const y = b.scene
  return (
    x.nav === y.nav &&
    x.dropdown === y.dropdown &&
    x.region === y.region &&
    x.rollback === y.rollback &&
    Math.round(x.deploy * 8) === Math.round(y.deploy * 8)
  )
})

export { REGIONS }
