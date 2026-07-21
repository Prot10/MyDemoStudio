import Foundation

/// The kinds of input we log during a recording. Movement (including drags) drives
/// the smooth cursor; the button-down events drive the automatic-zoom timeline.
enum RecordingEventType: String, Codable, Sendable {
    case mouseMoved
    case leftMouseDown
    case leftMouseUp
    case rightMouseDown
    case rightMouseUp
    case drag          // any button held while moving
    case scroll
    case keyDown       // keyboard key press (for typing sound effects)
}

/// One input sample on the video timeline.
///
/// - `t` is seconds from the first captured video frame (see `EventTrack`), so it
///   lines up directly with the master movie's presentation times.
/// - `x`/`y` are in **global display points**, top-left origin. The renderer maps
///   them into master-pixel space using the `EventTrack` display metadata.
struct RecordingEvent: Codable, Sendable {
    var t: Double
    var type: RecordingEventType
    var x: Double
    var y: Double
}

/// The full event log for one recording, plus the geometry needed to project the
/// point-space event coordinates into the master movie's pixel space.
struct EventTrack: Codable, Sendable {
    /// Master movie pixel dimensions.
    var pixelWidth: Int
    var pixelHeight: Int
    /// The captured display's origin and size in global points (for coordinate mapping).
    var displayOriginX: Double
    var displayOriginY: Double
    var displayWidthPoints: Double
    var displayHeightPoints: Double
    /// Backing scale (pixels per point) of the captured display.
    var scale: Double
    /// Nominal capture frame rate.
    var frameRate: Int
    var events: [RecordingEvent]

    /// Maps a global-point event coordinate into master-pixel space (top-left origin).
    func pixelPoint(for event: RecordingEvent) -> (x: Double, y: Double) {
        let localX = (event.x - displayOriginX) * scale
        let localY = (event.y - displayOriginY) * scale
        return (localX, localY)
    }
}
