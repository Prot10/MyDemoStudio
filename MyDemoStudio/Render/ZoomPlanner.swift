import Foundation
import CoreGraphics

/// Turns the click log into an automatic-zoom timeline. Unlike a fixed zoom-into-a-point,
/// the camera **pans to follow the cursor** while zoomed (heavily damped so it glides,
/// not jitters) and eases in/out with a smootherstep curve.
struct ZoomPlanner: Sendable {

    private struct Segment: Sendable {
        var rampInStart: Double
        var holdStart: Double
        var holdEnd: Double
        var rampOutEnd: Double
        var scale: Double
    }

    private struct Sample: Sendable {
        var t: Double
        var point: CGPoint
    }

    private let segments: [Segment]
    private let cameraPath: [Sample]   // heavily damped cursor path, master-pixel space

    // Tunables (seconds).
    private static let preRoll = 0.15
    private static let rampIn = 0.75      // slower, smoother zoom-in
    private static let holdAfter = 1.60
    private static let rampOut = 0.90      // slow, gentle zoom-out
    private static let mergeGap = 3.50     // keep zoomed through nearby clicks (less bouncing)
    private static let followTau = 0.30    // camera follow smoothness (fixed-timestep; smaller = cursor stays nearer center)

    init(track: EventTrack, settings: RenderSettings) {
        guard settings.zoomEnabled, settings.zoomScale > 1.01 else {
            segments = []; cameraPath = []; return
        }

        // Heavily damped camera-follow path from every located event.
        let raw: [Sample] = track.events
            .sorted { $0.t < $1.t }
            .map { event in
                let p = track.pixelPoint(for: event)
                return Sample(t: event.t, point: CGPoint(x: p.x, y: p.y))
            }
        cameraPath = Self.damp(raw, tau: Self.followTau)

        // Zoom scale envelope from clustered clicks.
        let clickTimes = track.events
            .filter { $0.type == .leftMouseDown || $0.type == .rightMouseDown }
            .map(\.t)
            .sorted()
        guard !clickTimes.isEmpty else { segments = []; return }

        var groups: [[Double]] = []
        for t in clickTimes {
            if let last = groups.last, let prev = last.last, t - prev <= Self.mergeGap {
                groups[groups.count - 1].append(t)
            } else {
                groups.append([t])
            }
        }

        var built: [Segment] = groups.map { group in
            let first = group.first!, last = group.last!
            let holdStart = max(0, first - Self.preRoll)
            return Segment(
                rampInStart: max(0, holdStart - Self.rampIn),
                holdStart: holdStart,
                holdEnd: last + Self.holdAfter,
                rampOutEnd: last + Self.holdAfter + Self.rampOut,
                scale: settings.zoomScale
            )
        }

        built.sort { $0.rampInStart < $1.rampInStart }
        var merged: [Segment] = []
        for seg in built {
            if var last = merged.last, seg.rampInStart <= last.rampOutEnd {
                last.holdEnd = max(last.holdEnd, seg.holdEnd)
                last.rampOutEnd = max(last.rampOutEnd, seg.rampOutEnd)
                merged[merged.count - 1] = last
            } else {
                merged.append(seg)
            }
        }
        segments = merged
    }

    var isEmpty: Bool { segments.isEmpty }

    var intervals: [ClosedRange<Double>] {
        segments.map { $0.rampInStart...$0.rampOutEnd }
    }

    /// Zoom at time `t`: scale from the envelope, focus following the damped cursor.
    func zoom(at t: Double) -> ZoomState {
        let scale = scale(at: t)
        if scale <= 1.001 { return .identity }
        return ZoomState(focus: focus(at: t), scale: scale)
    }

    private func scale(at t: Double) -> Double {
        for s in segments where t >= s.rampInStart && t <= s.rampOutEnd {
            if t < s.holdStart {
                let f = Self.smootherstep((t - s.rampInStart) / max(s.holdStart - s.rampInStart, 1e-4))
                return 1 + (s.scale - 1) * f
            } else if t <= s.holdEnd {
                return s.scale
            } else {
                let f = Self.smootherstep((t - s.holdEnd) / max(s.rampOutEnd - s.holdEnd, 1e-4))
                return s.scale + (1 - s.scale) * f
            }
        }
        return 1
    }

    private func focus(at t: Double) -> CGPoint {
        guard let first = cameraPath.first, let last = cameraPath.last else { return .zero }
        if t <= first.t { return first.point }
        if t >= last.t { return last.point }
        var lo = 0, hi = cameraPath.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cameraPath[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = cameraPath[lo], b = cameraPath[hi]
        let span = b.t - a.t
        let f = span > 0 ? (t - a.t) / span : 0
        return CGPoint(x: a.point.x + (b.point.x - a.point.x) * f,
                       y: a.point.y + (b.point.y - a.point.y) * f)
    }

    /// Fixed-timestep smoothing. The raw cursor samples are irregularly spaced (and can
    /// have big gaps), so we resample the target position at a constant rate and run a
    /// spring at that rate — this prevents the camera from teleporting on sparse samples.
    private static func damp(_ raw: [Sample], tau: Double) -> [Sample] {
        guard let first = raw.first, let last = raw.last, raw.count > 1 else { return raw }
        let dt = 1.0 / 120.0
        let alpha = 1 - exp(-dt / tau)
        var out: [Sample] = []
        out.reserveCapacity(Int((last.t - first.t) / dt) + 2)
        var pos = first.point
        var t = first.t
        var idx = 0
        while t <= last.t {
            while idx < raw.count - 1 && raw[idx + 1].t <= t { idx += 1 }
            let target: CGPoint
            if idx >= raw.count - 1 {
                target = raw[raw.count - 1].point
            } else {
                let a = raw[idx], b = raw[idx + 1]
                let span = b.t - a.t
                let f = span > 0 ? (t - a.t) / span : 0
                target = CGPoint(x: a.point.x + (b.point.x - a.point.x) * f,
                                 y: a.point.y + (b.point.y - a.point.y) * f)
            }
            pos.x += (target.x - pos.x) * alpha
            pos.y += (target.y - pos.y) * alpha
            out.append(Sample(t: t, point: pos))
            t += dt
        }
        return out
    }

    private static func smootherstep(_ x: Double) -> Double {
        let t = max(0, min(1, x))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}
