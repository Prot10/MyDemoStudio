import RecordedApp from './RecordedApp.jsx'

/* The composited frame.

   This is the same order of operations the Metal pass runs: wallpaper, then the
   capture inset by the padding fraction with rounded corners and a drop shadow,
   then the camera transform, then the cursor on top at a fixed size, then the
   caption. Getting the order right is what makes it read as the product rather
   than as a picture of the product. */

export const WALLPAPERS = [
  {
    name: 'Nebula',
    css: `radial-gradient(120% 130% at 8% 6%, #7b5cf0 0%, transparent 55%),
          radial-gradient(110% 120% at 96% 24%, #2f9bf7 0%, transparent 58%),
          radial-gradient(120% 110% at 12% 98%, #d059c9 0%, transparent 52%),
          linear-gradient(135deg, #5b3fd4 0%, #3f7ae8 55%, #2f9bf7 100%)`,
  },
  {
    name: 'Ember',
    css: `radial-gradient(120% 130% at 10% 4%, #ff8a3d 0%, transparent 55%),
          radial-gradient(110% 120% at 94% 30%, #f0447a 0%, transparent 56%),
          radial-gradient(120% 110% at 20% 98%, #7a2ea8 0%, transparent 54%),
          linear-gradient(135deg, #e8563f 0%, #d3357a 60%, #8b2fa8 100%)`,
  },
  {
    name: 'Fathom',
    css: `radial-gradient(120% 130% at 6% 10%, #12c2b4 0%, transparent 52%),
          radial-gradient(110% 120% at 92% 18%, #2f6ff7 0%, transparent 58%),
          radial-gradient(120% 110% at 30% 100%, #0f3f8f 0%, transparent 56%),
          linear-gradient(135deg, #0e9c98 0%, #1a5fd0 60%, #123a86 100%)`,
  },
  {
    name: 'Graphite',
    css: `radial-gradient(120% 130% at 12% 8%, #4a4f63 0%, transparent 55%),
          radial-gradient(110% 120% at 92% 26%, #2b2f3d 0%, transparent 58%),
          linear-gradient(135deg, #33374a 0%, #1c1f2b 60%, #101219 100%)`,
  },
]

const Cursor = ({ x, y, scale, pressed }) => (
  <div
    className="pointer-events-none absolute"
    style={{
      left: `${x * 100}%`,
      top: `${y * 100}%`,
      width: `${1.55 * scale}%`,
      transform: `scale(${pressed ? 0.88 : 1})`,
      transformOrigin: '12% 8%',
      transition: 'transform 120ms ease-out',
      filter: 'drop-shadow(0 2px 5px rgb(0 0 0 / .45))',
    }}
  >
    <svg viewBox="0 0 12 19" className="block w-full h-auto">
      <path d="M1 1 L1 15.2 L4.6 11.9 L7 17.8 L9.4 16.8 L7.1 11.2 L11.6 11.2 Z" fill="#fff" stroke="#101018" strokeWidth="1.1" strokeLinejoin="round" />
    </svg>
  </div>
)

export const ASPECTS = {
  wide: { label: '16:9', ratio: 16 / 9 },
  vertical: { label: '9:16', ratio: 9 / 16 },
  square: { label: '1:1', ratio: 1 },
}

const CONTENT_RATIO = 16 / 10

export default function Stage({
  scene,
  camera,
  cursor,
  pressed = false,
  look,
  raw = false,
  maxHeight,
  className = '',
}) {
  const {
    padding = 0.068,
    corner = 0.018,
    shadow = 0.45,
    cursorScale = 2.4,
    wallpaper = 0,
    aspect = 'wide',
    caption = null,
  } = look ?? {}

  const canvasRatio = (ASPECTS[aspect] ?? ASPECTS.wide).ratio
  const heightLimited = canvasRatio > CONTENT_RATIO

  const z = raw ? 1 : camera.scale
  const fx = raw ? 0.5 : camera.fx
  const fy = raw ? 0.5 : camera.fy

  const pad = raw ? 0 : padding
  const rad = raw ? 0 : corner
  const sx = 0.5 + (cursor.x - fx) * z
  const sy = 0.5 + (cursor.y - fy) * z

  return (
    <div
      className={`relative overflow-hidden ${className}`}
      style={{
        aspectRatio: String(canvasRatio),
        containerType: 'inline-size',
        /* Cap the height by capping the width — setting max-height directly would
           fight aspect-ratio and squash the frame. */
        width: maxHeight ? `min(100%, calc(${maxHeight} * ${canvasRatio}))` : '100%',
        transition: 'aspect-ratio 400ms ease, background 500ms ease, width 400ms ease',
        background: raw ? '#000' : WALLPAPERS[wallpaper % WALLPAPERS.length].css,
        transition: 'background 500ms ease',
      }}
    >
      {/* the capture, inset by the padding fraction */}
      <div className="absolute inset-0 flex items-center justify-center">
        <div
          className="relative overflow-hidden"
          style={{
            ...(heightLimited
              ? { height: `${100 - pad * 200}%`, width: 'auto' }
              : { width: `${100 - pad * 200}%`, height: 'auto' }),
            aspectRatio: String(CONTENT_RATIO),
            borderRadius: `${rad * 100}cqw`,
            boxShadow: raw ? 'none' : `0 ${2.2 + shadow * 2}cqw ${4 + shadow * 8}cqw rgb(0 0 0 / ${shadow})`,
            transition: 'height 320ms ease, width 320ms ease, border-radius 320ms ease, box-shadow 320ms ease',
          }}
        >
          {/* camera: scale about the focus point, then recentre it */}
          <div
            className="absolute inset-0"
            style={{
              transformOrigin: '0 0',
              transform: `translate(${(0.5 - z * fx) * 100}%, ${(0.5 - z * fy) * 100}%) scale(${z})`,
              willChange: 'transform',
            }}
          >
            <RecordedApp scene={scene} />
          </div>

          {/* cursor rides on top at a constant size, as in the compositor */}
          {sx > -0.1 && sx < 1.1 && sy > -0.1 && sy < 1.1 && (
            <Cursor x={sx} y={sy} scale={cursorScale} pressed={pressed} />
          )}
        </div>
      </div>

      {/* caption pill */}
      {caption && !raw && (
        <div
          className="absolute left-1/2 -translate-x-1/2 rounded-[1.6cqw] bg-black/72 font-semibold text-white"
          style={{ bottom: '7%', padding: '1.1cqw 2.4cqw', fontSize: '3.1cqw', letterSpacing: '-0.01em' }}
        >
          {caption}
        </div>
      )}
    </div>
  )
}
