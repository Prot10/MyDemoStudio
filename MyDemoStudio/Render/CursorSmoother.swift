import Foundation
import CoreGraphics

/// Turns the raw input log into a smooth cursor path in master-pixel space.
///
/// The recorded pointer is jittery; Screen Studio's signature glide comes from
/// low-pass filtering that path. We build a time-ordered list of positions (from
/// every event that carries a location) and apply an exponential moving average,
/// then interpolate to any frame time.
struct CursorSmoother: Sendable {

    private struct Sample {
        var t: Double
        var point: CGPoint
    }

    private let samples: [Sample]
    private let pressIntervals: [(start: Double, end: Double)]
    /// Seconds of pointer stillness after which the cursor is considered idle.
    private let idleHideDelay: Double = 1.5

    init(track: EventTrack, smoothing: Double) {
        // Mouse-button press windows (down → up), for the hand-on-click cursor.
        var intervals: [(start: Double, end: Double)] = []
        var openDown: Double?
        for event in track.events.sorted(by: { $0.t < $1.t }) {
            switch event.type {
            case .leftMouseDown, .rightMouseDown:
                openDown = event.t
            case .leftMouseUp, .rightMouseUp:
                if let down = openDown { intervals.append((down, event.t)); openDown = nil }
            default:
                break
            }
        }
        if let down = openDown { intervals.append((down, down + 0.15)) }
        pressIntervals = intervals

        // Map every located event into master-pixel space, in time order.
        let raw: [Sample] = track.events
            .sorted { $0.t < $1.t }
            .map { event in
                let p = track.pixelPoint(for: event)
                return Sample(t: event.t, point: CGPoint(x: p.x, y: p.y))
            }

        guard !raw.isEmpty else { samples = []; return }

        // Exponential moving average. `smoothing` in [0,1] maps to a light→heavy
        // filter; alpha is the weight given to each new raw sample.
        let alpha = 1.0 - (0.55 + 0.44 * max(0, min(1, smoothing)))  // ~0.45 → ~0.01
        var filtered: [Sample] = []
        filtered.reserveCapacity(raw.count)
        var current = raw[0].point
        for sample in raw {
            current.x += (sample.point.x - current.x) * alpha
            current.y += (sample.point.y - current.y) * alpha
            filtered.append(Sample(t: sample.t, point: current))
        }
        samples = filtered
    }

    var isEmpty: Bool { samples.isEmpty }

    /// True if a mouse button is held at time `t` (small padding so quick clicks register).
    func isPressed(at t: Double) -> Bool {
        let pad = 0.08
        return pressIntervals.contains { t >= $0.start - pad && t <= $0.end + pad }
    }

    /// Smoothed cursor position at time `t` (master-pixel space), or nil before the
    /// first sample / while the pointer is idle (Screen-Studio-style hide-when-still).
    func position(at t: Double) -> CGPoint? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if t <= first.t { return first.point }
        if t >= last.t {
            return (t - last.t) > idleHideDelay ? nil : last.point
        }

        // Binary search for the surrounding samples, then linear interpolate.
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = samples[lo], b = samples[hi]

        // A large gap between movement samples means the pointer sat still: keep it
        // visible briefly after it stops and just before it moves again, hide between.
        if (b.t - a.t) > idleHideDelay {
            if (t - a.t) <= idleHideDelay { return a.point }
            if (b.t - t) <= 0.2 { return b.point }
            return nil
        }

        let span = b.t - a.t
        let f = span > 0 ? (t - a.t) / span : 0
        return CGPoint(
            x: a.point.x + (b.point.x - a.point.x) * f,
            y: a.point.y + (b.point.y - a.point.y) * f
        )
    }
}
