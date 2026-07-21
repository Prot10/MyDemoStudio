import Foundation

/// What a timeline clip plays from.
///
/// - `.recording` points at a `.mydemo` package in the clip library (by folder name), so
///   several projects can reuse the same recording without duplicating gigabytes.
/// - `.file` is a path **relative to the project's `Media/` folder** — imports are copied
///   in, so a project never breaks when the original is moved or deleted.
/// - `.text` is a synthetic clip with no media at all.
enum MediaSource: Codable, Sendable, Equatable, Hashable {
    case recording(id: String)
    case file(path: String, kind: MediaKind)
    case text

    var kind: MediaKind {
        switch self {
        case .recording: return .video
        case .file(_, let kind): return kind
        case .text: return .image
        }
    }

    /// True if this source can contribute audio to the mix.
    var carriesAudio: Bool {
        switch self {
        case .recording: return true
        case .file(_, let kind): return kind == .video || kind == .audio
        case .text: return false
        }
    }

    /// True if this source contributes a real video track to the composition (as opposed
    /// to being drawn by the compositor from a still image, or nothing at all).
    var hasVideoTrack: Bool {
        switch self {
        case .recording: return true
        case .file(_, let kind): return kind == .video
        case .text: return false
        }
    }
}

enum MediaKind: String, Codable, Sendable {
    case video, image, audio
}

/// Where a clip is drawn in the canvas, in normalized (0…1) canvas coordinates. Used for
/// overlays — the main video track ignores it and uses the padded `RenderLayout` rect.
struct ClipTransform: Codable, Sendable, Equatable {
    /// Center of the clip in normalized canvas coordinates.
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    /// Size as a fraction of the canvas's smaller side.
    var scale: Double = 0.22
    var opacity: Double = 1.0
    /// Draw as a circle (the webcam bubble) rather than a rounded rect.
    var circular: Bool = true

    static let bubbleBottomLeading = ClipTransform(centerX: 0.14, centerY: 0.84)
}

/// Slow pan/zoom over a still image so photos don't look dead. Interpolated across the
/// clip's own duration; fed straight into the compositor's existing zoom uniform.
struct KenBurns: Codable, Sendable, Equatable {
    var startScale: Double = 1.0
    var endScale: Double = 1.18
    /// Focus point in source UV (0…1), start and end.
    var startX: Double = 0.5
    var startY: Double = 0.5
    var endX: Double = 0.5
    var endY: Double = 0.5

    static let gentleZoomIn = KenBurns()
}

/// A text card / lower-third drawn on top of everything.
struct TextOverlay: Codable, Sendable, Equatable {
    var string: String
    /// Font size as a fraction of the canvas height.
    var fontSize: Double = 0.07
    var color: RGBAColor = RGBAColor(1, 1, 1, 1)
    var bold: Bool = true
    /// Center position in normalized canvas coordinates.
    var x: Double = 0.5
    var y: Double = 0.5
    /// Draw a dark rounded pill behind the text.
    var pill: Bool = false
}

/// Per-clip overrides of the project's look. Every field is optional: `nil` means
/// "inherit the project default", so a clip only stores what it actually changes.
struct LookOverride: Codable, Sendable, Equatable {
    var background: BackgroundStyle?
    var paddingFraction: Double?
    var cornerRadiusFraction: Double?
    var shadowRadiusFraction: Double?
    var shadowOpacity: Double?
    var zoomEnabled: Bool?
    var zoomScale: Double?
    var cursorStyle: CursorStyle?
    var cursorScale: Double?
    var cursorSmoothing: Double?
    var sfxEnabled: Bool?
    var sfxVolume: Double?
    var captionsEnabled: Bool?

    var isEmpty: Bool { self == LookOverride() }

    /// Resolves this override against the project defaults, producing the concrete
    /// `RenderSettings` the compositor already knows how to render.
    func applied(to base: RenderSettings) -> RenderSettings {
        var s = base
        if let background { s.background = background }
        if let paddingFraction { s.paddingFraction = paddingFraction }
        if let cornerRadiusFraction { s.cornerRadiusFraction = cornerRadiusFraction }
        if let shadowRadiusFraction { s.shadowRadiusFraction = shadowRadiusFraction }
        if let shadowOpacity { s.shadowOpacity = shadowOpacity }
        if let zoomEnabled { s.zoomEnabled = zoomEnabled }
        if let zoomScale { s.zoomScale = zoomScale }
        if let cursorStyle { s.cursorStyle = cursorStyle }
        if let cursorScale { s.cursorScale = cursorScale }
        if let cursorSmoothing { s.cursorSmoothing = cursorSmoothing }
        if let sfxEnabled { s.sfxEnabled = sfxEnabled }
        if let sfxVolume { s.sfxVolume = sfxVolume }
        if let captionsEnabled { s.captionsEnabled = captionsEnabled }
        return s
    }
}

/// One clip placed on a timeline track.
///
/// The source window is `[sourceIn, sourceOut)` in the media's own time; `speed` warps it
/// onto the timeline, so a 10 s window at 2× occupies 5 s starting at `start`.
struct TimelineClip: Codable, Sendable, Identifiable, Equatable {
    var id: UUID = UUID()
    var source: MediaSource
    /// Position on the timeline, in seconds.
    var start: Double
    /// Window into the source media, in the source's own seconds.
    var sourceIn: Double
    var sourceOut: Double
    /// Playback rate. 2.0 plays twice as fast and occupies half the timeline.
    var speed: Double = 1.0
    var volume: Double = 1.0
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var transform: ClipTransform = ClipTransform()
    var look: LookOverride?
    var kenBurns: KenBurns?
    var text: TextOverlay?
    /// Display name in the timeline lane.
    var name: String = ""

    /// Length of the source window, before the speed warp.
    var sourceDuration: Double { max(0, sourceOut - sourceIn) }
    /// Length on the timeline, after the speed warp.
    var duration: Double { sourceDuration / max(speed, 0.01) }
    var end: Double { start + duration }

    func contains(_ t: Double) -> Bool { t >= start && t < end }

    /// Maps a timeline instant to the corresponding instant in the source media.
    func sourceTime(at timelineTime: Double) -> Double {
        sourceIn + (timelineTime - start) * max(speed, 0.01)
    }

    /// Progress through the clip, 0…1 — drives Ken Burns and fades.
    func progress(at timelineTime: Double) -> Double {
        guard duration > 0.0001 else { return 0 }
        return min(max((timelineTime - start) / duration, 0), 1)
    }

    /// Fade envelope (1 = fully visible) at a timeline instant.
    func fadeLevel(at timelineTime: Double) -> Double {
        var level = 1.0
        if fadeIn > 0.0001 {
            level = min(level, min(max((timelineTime - start) / fadeIn, 0), 1))
        }
        if fadeOut > 0.0001 {
            level = min(level, min(max((end - timelineTime) / fadeOut, 0), 1))
        }
        return level
    }
}

enum TrackKind: String, Codable, Sendable {
    /// The main picture track — clips here get the full padded/zoomed treatment.
    case main
    /// Video/image drawn on top (webcam bubble, logo) and text cards.
    case overlay
    /// Audio only (voiceover, music, sound beds).
    case audio
}

/// One lane of the timeline. Clips within a track never overlap, which lets each track
/// map to a single `AVMutableCompositionTrack`.
struct Track: Codable, Sendable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: TrackKind
    var name: String
    var muted: Bool = false
    var hidden: Bool = false
    var volume: Double = 1.0
    var clips: [TimelineClip] = []

    var end: Double { clips.map(\.end).max() ?? 0 }

    /// The clip playing at a timeline instant, if any.
    func clip(at t: Double) -> TimelineClip? { clips.first { $0.contains(t) } }

    /// Keeps clips ordered by start time — the invariant every mutation restores.
    mutating func sort() { clips.sort { $0.start < $1.start } }
}

/// Output canvas for a project.
struct Canvas: Codable, Sendable, Equatable {
    var width: Int
    var height: Int
    var aspect: OutputAspect
    var fps: Int

    static let fullHD = Canvas(width: 1920, height: 1080, aspect: .wide, fps: 60)

    static func make(aspect: OutputAspect, masterWidth: Int, masterHeight: Int, fps: Int = 60) -> Canvas {
        let size = aspect.canvasSize(masterWidth: masterWidth, masterHeight: masterHeight)
        return Canvas(width: size.width, height: size.height, aspect: aspect, fps: fps)
    }
}

/// The edit document: everything needed to render a multi-clip project. Stored as
/// `document.json` inside a `.mdsproj` package. Source media is never modified.
struct EditDocument: Codable, Sendable, Equatable {
    /// Schema version, so future migrations can be detected rather than guessed.
    var version: Int = 1
    var name: String
    var canvas: Canvas
    /// Project-wide look; each clip's `LookOverride` is resolved against this.
    var defaultLook: RenderSettings
    var tracks: [Track]

    /// Total timeline length.
    var duration: Double { tracks.map(\.end).max() ?? 0 }

    /// The default set of lanes a new project starts with.
    static func makeDefault(name: String, canvas: Canvas) -> EditDocument {
        var look = RenderSettings.makeDefault(masterWidth: canvas.width, masterHeight: canvas.height)
        look.outputWidth = canvas.width
        look.outputHeight = canvas.height
        look.aspect = canvas.aspect
        return EditDocument(
            name: name,
            canvas: canvas,
            defaultLook: look,
            tracks: [
                Track(kind: .main, name: "Video"),
                Track(kind: .overlay, name: "Overlays"),
                Track(kind: .audio, name: "Voiceover"),
                Track(kind: .audio, name: "Music")
            ]
        )
    }

    // MARK: Lookups

    func track(id: UUID) -> Track? { tracks.first { $0.id == id } }

    func trackIndex(containingClip clipID: UUID) -> Int? {
        tracks.firstIndex { $0.clips.contains { $0.id == clipID } }
    }

    func clip(id: UUID) -> TimelineClip? {
        for track in tracks {
            if let clip = track.clips.first(where: { $0.id == id }) { return clip }
        }
        return nil
    }

    /// The main-track clip visible at a timeline instant.
    func mainClip(at t: Double) -> TimelineClip? {
        tracks.first { $0.kind == .main && !$0.hidden }?.clip(at: t)
    }

    /// Every distinct time at which the composition changes — the boundaries used to cut
    /// the video composition into instructions.
    var segmentBoundaries: [Double] {
        var set = Set<Double>([0])
        for track in tracks where !track.hidden {
            for clip in track.clips {
                set.insert((clip.start * 1000).rounded() / 1000)
                set.insert((clip.end * 1000).rounded() / 1000)
            }
        }
        let total = duration
        set = set.filter { $0 >= 0 && $0 <= total }
        set.insert(total)
        return set.sorted()
    }

    // MARK: Mutations (shared by the UI and the CLI, so both behave identically)

    /// Appends a clip at the end of a track, or at `at` when given.
    mutating func add(_ clip: TimelineClip, toTrack trackID: UUID, at start: Double? = nil) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        var clip = clip
        clip.start = start ?? tracks[index].end
        tracks[index].clips.append(clip)
        tracks[index].sort()
    }

    /// Splits the clip at a timeline instant into two clips. Returns the new clip's id.
    @discardableResult
    mutating func split(clipID: UUID, at t: Double) -> UUID? {
        guard let ti = trackIndex(containingClip: clipID),
              let ci = tracks[ti].clips.firstIndex(where: { $0.id == clipID }) else { return nil }
        let clip = tracks[ti].clips[ci]
        // Refuse degenerate splits — a zero-length clip is never what the user wanted.
        guard t > clip.start + 0.02, t < clip.end - 0.02 else { return nil }

        let cutSource = clip.sourceTime(at: t)
        var left = clip
        left.sourceOut = cutSource
        left.fadeOut = 0
        var right = clip
        right.id = UUID()
        right.sourceIn = cutSource
        right.start = t
        right.fadeIn = 0

        tracks[ti].clips[ci] = left
        tracks[ti].clips.insert(right, at: ci + 1)
        return right.id
    }

    /// Retrims a clip's source window, keeping its timeline start unless `rippleFrom` is set.
    mutating func trim(clipID: UUID, sourceIn: Double?, sourceOut: Double?) {
        guard let ti = trackIndex(containingClip: clipID),
              let ci = tracks[ti].clips.firstIndex(where: { $0.id == clipID }) else { return }
        var clip = tracks[ti].clips[ci]
        if let sourceIn { clip.sourceIn = max(0, min(sourceIn, clip.sourceOut - 0.05)) }
        if let sourceOut { clip.sourceOut = max(clip.sourceIn + 0.05, sourceOut) }
        tracks[ti].clips[ci] = clip
    }

    mutating func setSpeed(clipID: UUID, speed: Double) {
        guard let ti = trackIndex(containingClip: clipID),
              let ci = tracks[ti].clips.firstIndex(where: { $0.id == clipID }) else { return }
        tracks[ti].clips[ci].speed = max(0.1, min(speed, 10))
    }

    mutating func move(clipID: UUID, to start: Double, trackID: UUID? = nil) {
        guard let ti = trackIndex(containingClip: clipID),
              let ci = tracks[ti].clips.firstIndex(where: { $0.id == clipID }) else { return }
        var clip = tracks[ti].clips[ci]
        clip.start = max(0, start)
        if let trackID, trackID != tracks[ti].id,
           let di = tracks.firstIndex(where: { $0.id == trackID }) {
            tracks[ti].clips.remove(at: ci)
            tracks[di].clips.append(clip)
            tracks[di].sort()
        } else {
            tracks[ti].clips[ci] = clip
            tracks[ti].sort()
        }
    }

    mutating func remove(clipID: UUID) {
        guard let ti = trackIndex(containingClip: clipID) else { return }
        tracks[ti].clips.removeAll { $0.id == clipID }
    }

    /// Removes a clip and slides everything after it left to close the hole.
    mutating func rippleDelete(clipID: UUID) {
        guard let ti = trackIndex(containingClip: clipID),
              let clip = tracks[ti].clips.first(where: { $0.id == clipID }) else { return }
        let gap = clip.duration
        tracks[ti].clips.removeAll { $0.id == clipID }
        for i in tracks[ti].clips.indices where tracks[ti].clips[i].start > clip.start {
            tracks[ti].clips[i].start -= gap
        }
    }

    /// Removes any gaps on a track so clips play back to back.
    mutating func compact(trackID: UUID) {
        guard let ti = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[ti].sort()
        var cursor = 0.0
        for i in tracks[ti].clips.indices {
            tracks[ti].clips[i].start = cursor
            cursor += tracks[ti].clips[i].duration
        }
    }
}
