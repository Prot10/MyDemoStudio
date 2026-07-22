/* The take.

   A synthetic recording: where the pointer went, when it clicked, and what the
   captured app did in response. Coordinates are fractions of the captured frame,
   which is exactly how `events.json` stores them. */

export const DURATION = 16

export const WAYPOINTS = [
  { t: 0.0, x: 0.7, y: 0.66 },
  { t: 0.8, x: 0.145, y: 0.375 },
  { t: 1.6, x: 0.145, y: 0.375 },
  { t: 2.5, x: 0.6, y: 0.318 },
  { t: 3.3, x: 0.6, y: 0.318 },
  { t: 4.3, x: 0.6, y: 0.471 },
  { t: 5.0, x: 0.6, y: 0.471 },
  { t: 7.0, x: 0.38, y: 0.7 },
  { t: 8.7, x: 0.845, y: 0.556 },
  { t: 9.6, x: 0.845, y: 0.556 },
  { t: 10.6, x: 0.845, y: 0.8 },
  { t: 11.5, x: 0.845, y: 0.8 },
  { t: 12.6, x: 0.62, y: 0.86 },
  { t: 14.5, x: 0.7, y: 0.66 },
  { t: DURATION, x: 0.7, y: 0.66 },
]

export const CLICKS = [1.6, 3.3, 5.0, 9.6, 11.5]

/** What the captured app looks like at time `t`. */
export function sceneAt(t) {
  return {
    nav: t >= 1.6 ? 'environments' : 'overview',
    dropdown: t >= 3.3 && t < 5.0,
    region: t >= 5.0 ? 'eu-central-1' : 'us-east-1',
    rollback: t >= 9.6,
    deploy: t < 11.5 ? 0 : Math.min(1, (t - 11.5) / 2.6),
  }
}

/** Labels for the mini timeline under the stage. */
export const BEATS = [
  { t: 1.6, label: 'click' },
  { t: 3.3, label: 'click' },
  { t: 5.0, label: 'click' },
  { t: 9.6, label: 'click' },
  { t: 11.5, label: 'click' },
]
