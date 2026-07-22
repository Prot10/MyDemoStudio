/* A faithful port of the app's ZoomPlanner (MyDemoStudio/Render/ZoomPlanner.swift).
   The hero is not an animation of the feature — it runs the feature's own maths on a
   synthetic event track, so the easing you see in the browser is the easing you get
   in an export. Keep the constants below in sync with the Swift. */

export const PRE_ROLL = 0.15
export const RAMP_IN = 0.75
export const HOLD_AFTER = 1.6
export const RAMP_OUT = 0.9
export const MERGE_GAP = 3.5
export const FOLLOW_TAU = 0.3

const smootherstep = (x) => {
  const t = Math.min(1, Math.max(0, x))
  return t * t * t * (t * (t * 6 - 15) + 10)
}

const lerp = (a, b, f) => a + (b - a) * f

/* Heavily damped follow path, resampled at a fixed timestep. Irregular sample
   spacing is what makes a naive EMA teleport, so we resample first. */
function damp(raw, tau = FOLLOW_TAU) {
  if (raw.length < 2) return raw
  const dt = 1 / 120
  const alpha = 1 - Math.exp(-dt / tau)
  const out = []
  let cur = { x: raw[0].x, y: raw[0].y }
  let idx = 0
  for (let t = raw[0].t; t <= raw[raw.length - 1].t; t += dt) {
    while (idx < raw.length - 2 && raw[idx + 1].t < t) idx += 1
    const a = raw[idx]
    const b = raw[Math.min(idx + 1, raw.length - 1)]
    const span = b.t - a.t
    const f = span > 0 ? Math.min(1, Math.max(0, (t - a.t) / span)) : 0
    const target = { x: lerp(a.x, b.x, f), y: lerp(a.y, b.y, f) }
    cur = { x: cur.x + (target.x - cur.x) * alpha, y: cur.y + (target.y - cur.y) * alpha }
    out.push({ t, x: cur.x, y: cur.y })
  }
  return out
}

function sampleAt(path, t) {
  if (!path.length) return { x: 0.5, y: 0.5 }
  if (t <= path[0].t) return path[0]
  if (t >= path[path.length - 1].t) return path[path.length - 1]
  let lo = 0
  let hi = path.length - 1
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1
    if (path[mid].t <= t) lo = mid
    else hi = mid
  }
  const a = path[lo]
  const b = path[hi]
  const span = b.t - a.t
  const f = span > 0 ? (t - a.t) / span : 0
  return { x: lerp(a.x, b.x, f), y: lerp(a.y, b.y, f) }
}

/* Clusters clicks into zoom segments, exactly like the planner:
   preRoll before the first click, a ramp in, a hold that stretches to the last
   click of the cluster, then a slow ramp out. Overlapping segments merge. */
function buildSegments(clickTimes) {
  const groups = []
  for (const t of [...clickTimes].sort((a, b) => a - b)) {
    const last = groups[groups.length - 1]
    if (last && t - last[last.length - 1] <= MERGE_GAP) last.push(t)
    else groups.push([t])
  }

  const built = groups.map((g) => {
    const first = g[0]
    const last = g[g.length - 1]
    const holdStart = Math.max(0, first - PRE_ROLL)
    return {
      rampInStart: Math.max(0, holdStart - RAMP_IN),
      holdStart,
      holdEnd: last + HOLD_AFTER,
      rampOutEnd: last + HOLD_AFTER + RAMP_OUT,
    }
  })

  built.sort((a, b) => a.rampInStart - b.rampInStart)
  const merged = []
  for (const seg of built) {
    const last = merged[merged.length - 1]
    if (last && seg.rampInStart <= last.rampOutEnd) {
      last.holdEnd = Math.max(last.holdEnd, seg.holdEnd)
      last.rampOutEnd = Math.max(last.rampOutEnd, seg.rampOutEnd)
    } else merged.push({ ...seg })
  }
  return merged
}

/**
 * @param {{t:number,x:number,y:number}[]} track densely sampled cursor path, x/y in 0..1
 * @param {number[]} clickTimes seconds at which the mouse went down
 * @param {number} zoomScale hold magnification
 */
export function createPlanner(track, clickTimes, zoomScale = 1.9) {
  const path = damp(track)
  const segments = buildSegments(clickTimes)

  const scaleAt = (t) => {
    for (const s of segments) {
      if (t < s.rampInStart || t > s.rampOutEnd) continue
      if (t < s.holdStart) {
        return lerp(1, zoomScale, smootherstep((t - s.holdStart + RAMP_IN) / RAMP_IN))
      }
      if (t <= s.holdEnd) return zoomScale
      return lerp(zoomScale, 1, smootherstep((t - s.holdEnd) / (s.rampOutEnd - s.holdEnd)))
    }
    return 1
  }

  return {
    segments,
    /* Focus is clamped so the zoomed frame never samples outside the capture —
       the same clamp the Metal compositor applies. */
    at(t) {
      const scale = scaleAt(t)
      const focus = sampleAt(path, t)
      const half = 0.5 / scale
      return {
        scale,
        fx: Math.min(1 - half, Math.max(half, focus.x)),
        fy: Math.min(1 - half, Math.max(half, focus.y)),
      }
    },
    cursorAt: (t) => sampleAt(track, t),
  }
}

/* Turns a handful of waypoints into a 60 Hz path that moves the way a hand does:
   accelerate away, decelerate in, sit still while clicking. */
export function buildTrack(waypoints, duration, hz = 60) {
  const track = []
  const dt = 1 / hz
  for (let t = 0; t <= duration; t += dt) {
    let i = 0
    while (i < waypoints.length - 2 && waypoints[i + 1].t <= t) i += 1
    const a = waypoints[i]
    const b = waypoints[Math.min(i + 1, waypoints.length - 1)]
    const span = b.t - a.t
    const f = span > 0 ? smootherstep((t - a.t) / span) : 1
    track.push({ t, x: lerp(a.x, b.x, f), y: lerp(a.y, b.y, f) })
  }
  return track
}

export { smootherstep }
