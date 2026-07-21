import Foundation

/// A plain RGBA color, Codable so it can live in `project.json`.
struct RGBAColor: Codable, Sendable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
}

/// Which pointer sprite the render draws.
enum CursorStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    case arrow          // system arrow, always
    case hand           // pointing hand, always
    case handOnClick    // arrow normally, hand while clicking

    var id: String { rawValue }
    var label: String {
        switch self {
        case .arrow: return "Arrow"
        case .hand: return "Hand"
        case .handOnClick: return "Hand on click"
        }
    }
}

/// Corner placement for the webcam bubble.
enum WebcamCorner: String, Codable, Sendable, CaseIterable, Identifiable {
    case bottomLeading, bottomTrailing, topLeading, topTrailing
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bottomLeading: return "Bottom L"
        case .bottomTrailing: return "Bottom R"
        case .topLeading: return "Top L"
        case .topTrailing: return "Top R"
        }
    }
}

/// Output shape presets. The recording is fitted inside, preserving its own aspect,
/// with the background filling the rest (so a 16:9 recording in a 9:16 canvas gets
/// tall gradient bars — the vertical social look).
enum OutputAspect: String, Codable, Sendable, CaseIterable, Identifiable {
    case original
    case wide        // 16:9
    case vertical    // 9:16
    case square      // 1:1

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return "Original"
        case .wide: return "16:9"
        case .vertical: return "9:16"
        case .square: return "1:1"
        }
    }

    /// Editing-canvas pixel size for this aspect (export scales it to the chosen preset).
    func canvasSize(masterWidth: Int, masterHeight: Int) -> (width: Int, height: Int) {
        switch self {
        case .original: return (masterWidth, masterHeight)
        case .wide:     return (1920, 1080)
        case .vertical: return (1080, 1920)
        case .square:   return (1080, 1080)
        }
    }
}

/// How the area around the recording is filled.
struct BackgroundStyle: Codable, Sendable, Equatable {
    enum Kind: Int, Codable, Sendable { case solid = 0, gradient = 1, wallpaper = 2 }
    var kind: Kind
    var color1: RGBAColor
    var color2: RGBAColor
    /// Gradient direction in degrees (0 = left→right).
    var angleDegrees: Double
    /// Which built-in mesh-gradient wallpaper (used when `kind == .wallpaper`).
    var wallpaperIndex: Int = 0
    /// Background softening, 0…1 (used for wallpaper/gradient).
    var blur: Double = 0

    /// Number of built-in wallpapers (must match the shader's palette count).
    static let wallpaperCount = 6

    static let violet = BackgroundStyle(
        kind: .gradient,
        color1: RGBAColor(0.42, 0.30, 0.86),
        color2: RGBAColor(0.20, 0.58, 0.90),
        angleDegrees: 45
    )

    static let sunset = BackgroundStyle(
        kind: .gradient,
        color1: RGBAColor(0.98, 0.45, 0.42),
        color2: RGBAColor(0.96, 0.76, 0.36),
        angleDegrees: 40
    )

    static let forest = BackgroundStyle(
        kind: .gradient,
        color1: RGBAColor(0.11, 0.37, 0.33),
        color2: RGBAColor(0.20, 0.55, 0.42),
        angleDegrees: 55
    )

    static let graphite = BackgroundStyle(
        kind: .gradient,
        color1: RGBAColor(0.20, 0.22, 0.26),
        color2: RGBAColor(0.10, 0.11, 0.13),
        angleDegrees: 90
    )

    static let presets: [BackgroundStyle] = [.violet, .sunset, .forest, .graphite]

    /// Default: the first built-in mesh wallpaper.
    static let defaultWallpaper = BackgroundStyle(
        kind: .wallpaper,
        color1: RGBAColor(0.42, 0.30, 0.86),
        color2: RGBAColor(0.28, 0.48, 0.96),
        angleDegrees: 45
    )
}

/// All non-destructive settings that turn the master recording into the polished
/// output. Stored in `project.json`; the master movie is never modified. Zoom
/// keyframes are added by `ZoomPlanner` in M3.
struct RenderSettings: Codable, Sendable, Equatable {
    /// Output pixel dimensions (defaults to the master's native size).
    var outputWidth: Int
    var outputHeight: Int
    /// Selected output shape (drives `outputWidth`/`outputHeight`).
    var aspect: OutputAspect

    var background: BackgroundStyle

    /// Padding around the recording, as a fraction of the output's smaller side.
    var paddingFraction: Double
    /// Corner radius of the recording, as a fraction of the output's smaller side.
    var cornerRadiusFraction: Double
    /// Drop-shadow blur radius, as a fraction of the output's smaller side.
    var shadowRadiusFraction: Double
    var shadowOpacity: Double

    /// Cursor rendering.
    var cursorScale: Double
    /// 0 = raw, 1 = maximum smoothing of the cursor path.
    var cursorSmoothing: Double
    /// Which pointer sprite to draw.
    var cursorStyle: CursorStyle = .arrow
    /// M2 sync-validation aid: draw a bright dot at the smoothed cursor position.
    var showDebugCursorDot: Bool

    /// Automatic zoom.
    var zoomEnabled: Bool
    /// Magnification factor during a zoom (e.g. 2.0 = 2×).
    var zoomScale: Double
    /// Radial motion blur during zoom transitions (off by default — some find it distorting).
    var motionBlur: Bool = false

    /// Webcam bubble.
    var webcamEnabled: Bool = true
    var webcamCorner: WebcamCorner = .bottomLeading
    /// Bubble diameter as a fraction of the output's smaller side.
    var webcamSize: Double = 0.2

    /// Burned-in captions (from the voiceover transcript).
    var captionsEnabled: Bool = true

    /// Click / keystroke sound effects mixed into the export.
    var sfxEnabled: Bool = false
    var sfxVolume: Double = 0.5
    /// Voiceover level (0 = muted).
    var voiceoverVolume: Double = 1.0

    /// Trim (seconds). `trimEnd <= 0` means "to the end".
    var trimStart: Double = 0
    var trimEnd: Double = 0

    static func makeDefault(masterWidth: Int, masterHeight: Int) -> RenderSettings {
        RenderSettings(
            outputWidth: masterWidth,
            outputHeight: masterHeight,
            aspect: .original,
            background: .defaultWallpaper,
            paddingFraction: 0.055,
            cornerRadiusFraction: 0.018,
            shadowRadiusFraction: 0.03,
            shadowOpacity: 0.45,
            cursorScale: 1.0,
            cursorSmoothing: 0.6,
            showDebugCursorDot: false,
            zoomEnabled: true,
            zoomScale: 2.0
        )
    }

    // Derived pixel values.
    var minSide: Double { Double(min(outputWidth, outputHeight)) }
    var paddingPixels: Double { paddingFraction * minSide }
    var cornerRadiusPixels: Double { cornerRadiusFraction * minSide }
    var shadowRadiusPixels: Double { shadowRadiusFraction * minSide }
}
