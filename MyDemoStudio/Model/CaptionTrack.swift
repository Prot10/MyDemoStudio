import Foundation

/// One caption line with its on-screen time window (seconds on the video timeline).
struct CaptionSegment: Codable, Sendable, Equatable {
    var start: Double
    var end: Double
    var text: String
}

/// All captions for a project, persisted to `captions.json`.
struct CaptionTrack: Codable, Sendable, Equatable {
    var segments: [CaptionSegment]

    /// The caption visible at time `t`, if any.
    func active(at t: Double) -> CaptionSegment? {
        segments.first { t >= $0.start && t <= $0.end }
    }
}
