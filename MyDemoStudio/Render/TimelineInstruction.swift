import Foundation
import AVFoundation
import CoreMedia

/// The main-track clip visible during one composition segment, with everything the
/// compositor needs to draw it: where its frames come from, how timeline time maps back
/// to clip time, and which effects apply.
final class MainSegment: @unchecked Sendable {
    /// Composition video track carrying this clip's frames, or nil for still images and
    /// text-only segments (which have no video track at all).
    let trackID: CMPersistentTrackID?
    /// Still image to draw instead of a video frame.
    let imageURL: URL?
    /// Natural pixel size of the source, used to lay out the padded content rect.
    let sourceWidth: Int
    let sourceHeight: Int

    /// Timeline placement, used to recover clip-local time and the fade envelope.
    let clipStart: Double
    let clipDuration: Double
    let sourceIn: Double
    let speed: Double
    let fadeIn: Double
    let fadeOut: Double

    /// Auto-zoom + smooth cursor, present only for screen recordings.
    let zoomAt: (@Sendable (Double) -> ZoomState)?
    let smoother: CursorSmoother?
    /// Slow pan/zoom for still images.
    let kenBurns: KenBurns?
    let captions: CaptionTrack?

    init(trackID: CMPersistentTrackID?, imageURL: URL?, sourceWidth: Int, sourceHeight: Int,
         clipStart: Double, clipDuration: Double, sourceIn: Double, speed: Double,
         fadeIn: Double, fadeOut: Double,
         zoomAt: (@Sendable (Double) -> ZoomState)? = nil, smoother: CursorSmoother? = nil,
         kenBurns: KenBurns? = nil, captions: CaptionTrack? = nil) {
        self.trackID = trackID
        self.imageURL = imageURL
        self.sourceWidth = max(sourceWidth, 1)
        self.sourceHeight = max(sourceHeight, 1)
        self.clipStart = clipStart
        self.clipDuration = clipDuration
        self.sourceIn = sourceIn
        self.speed = speed
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.zoomAt = zoomAt
        self.smoother = smoother
        self.kenBurns = kenBurns
        self.captions = captions
    }

    /// Timeline time → time within the source media (the inverse of the speed warp).
    func sourceTime(at t: Double) -> Double { sourceIn + (t - clipStart) * speed }

    /// 0…1 progress through the clip, for Ken Burns interpolation.
    func progress(at t: Double) -> Double {
        guard clipDuration > 0.0001 else { return 0 }
        return min(max((t - clipStart) / clipDuration, 0), 1)
    }

    /// Fade-to-black envelope; 1 = fully visible.
    func fadeLevel(at t: Double) -> Double {
        var level = 1.0
        if fadeIn > 0.0001 { level = min(level, min(max((t - clipStart) / fadeIn, 0), 1)) }
        if fadeOut > 0.0001 { level = min(level, min(max((clipStart + clipDuration - t) / fadeOut, 0), 1)) }
        return level
    }
}

/// A video clip drawn on top of the main picture — the webcam bubble, a logo sting.
struct OverlaySegment: Sendable {
    let trackID: CMPersistentTrackID
    let transform: ClipTransform
    let clipStart: Double
    let clipDuration: Double
    let fadeIn: Double
    let fadeOut: Double

    func fadeLevel(at t: Double) -> Double {
        var level = 1.0
        if fadeIn > 0.0001 { level = min(level, min(max((t - clipStart) / fadeIn, 0), 1)) }
        if fadeOut > 0.0001 { level = min(level, min(max((clipStart + clipDuration - t) / fadeOut, 0), 1)) }
        return level
    }
}

/// A text card active during this segment. All active texts are rasterized together into
/// one canvas-sized layer, so there is no per-overlay limit in the shader.
struct TextSegment: Sendable {
    let text: TextOverlay
    let clipStart: Double
    let clipDuration: Double
    let fadeIn: Double
    let fadeOut: Double

    func fadeLevel(at t: Double) -> Double {
        var level = 1.0
        if fadeIn > 0.0001 { level = min(level, min(max((t - clipStart) / fadeIn, 0), 1)) }
        if fadeOut > 0.0001 { level = min(level, min(max((clipStart + clipDuration - t) / fadeOut, 0), 1)) }
        return level
    }

    /// Cache key for the rasterized layer — anything that changes the pixels.
    var cacheKey: String {
        "\(text.string)|\(text.fontSize)|\(text.bold)|\(text.x)|\(text.y)|\(text.pill)|\(text.color.r),\(text.color.g),\(text.color.b)"
    }
}

/// One slice of the timeline during which the set of visible clips doesn't change.
///
/// The video composition is cut at every clip boundary, so within a single instruction
/// there is at most one main clip (there are no cross-dissolves), which keeps the
/// compositor a single Metal pass.
final class TimelineInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    /// The look resolved for this segment's main clip (project defaults + clip overrides).
    let settings: RenderSettings
    let main: MainSegment?
    let overlays: [OverlaySegment]
    let texts: [TextSegment]

    init(timeRange: CMTimeRange, settings: RenderSettings, fillerTrackID: CMPersistentTrackID,
         main: MainSegment?, overlays: [OverlaySegment], texts: [TextSegment]) {
        self.timeRange = timeRange
        self.settings = settings
        self.main = main
        self.overlays = overlays
        self.texts = texts

        // The filler track is always required: it guarantees AVFoundation has video
        // content for every instant, so image-only, text-only and gap segments still
        // produce frames.
        var ids: Set<CMPersistentTrackID> = [fillerTrackID]
        if let id = main?.trackID { ids.insert(id) }
        for overlay in overlays { ids.insert(overlay.trackID) }
        self.requiredSourceTrackIDs = ids.sorted().map { NSNumber(value: $0) }
    }
}
