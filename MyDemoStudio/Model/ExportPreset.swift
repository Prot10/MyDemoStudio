import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// The container the export is written into.
///
/// MP4 is the default because it is what everything else accepts — browsers, social
/// platforms, Slack, Premiere. MOV is kept for handing work to other Apple tools.
enum ExportFormat: String, CaseIterable, Identifiable, Sendable, Codable {
    case mp4
    case mov
    case gif

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mp4: return "MP4"
        case .mov: return "MOV"
        case .gif: return "GIF"
        }
    }

    var detail: String {
        switch self {
        case .mp4: return "H.264 — plays everywhere"
        case .mov: return "H.264 in a QuickTime container"
        case .gif: return "Animated, no audio"
        }
    }

    var isGIF: Bool { self == .gif }

    var fileExtension: String { rawValue }

    var systemImage: String { isGIF ? "photo.stack" : "film" }

    /// The container AVFoundation writes.
    var fileType: AVFileType {
        switch self {
        case .mp4: return .mp4
        case .mov, .gif: return .mov      // GIF never reaches the video writer
        }
    }

    var contentType: UTType {
        switch self {
        case .mp4: return .mpeg4Movie
        case .mov: return .quickTimeMovie
        case .gif: return .gif
        }
    }

    /// Frame rate for GIF output.
    var gifFrameRate: Int { 16 }
}

/// Output resolution. Resolutions are caps applied to the editing canvas, which is what
/// defines the aspect ratio.
enum ExportPreset: String, CaseIterable, Identifiable, Sendable {
    case uhd = "4K"
    case fullHD = "1080p"
    case hd = "720p"

    var id: String { rawValue }

    var label: String { rawValue }

    /// Longest-edge target in pixels for this quality.
    private var targetLongEdge: Int {
        switch self {
        case .uhd:    return 3840
        case .fullHD: return 1920
        case .hd:     return 1280
        }
    }

    /// Scales the editing canvas (which defines the aspect) to this preset's resolution.
    func outputSize(canvasWidth: Int, canvasHeight: Int) -> (width: Int, height: Int) {
        let longEdge = Double(max(canvasWidth, canvasHeight, 1))
        let scale = Double(targetLongEdge) / longEdge
        var w = Int((Double(canvasWidth) * scale).rounded())
        var h = Int((Double(canvasHeight) * scale).rounded())
        w -= w % 2
        h -= h % 2
        return (max(w, 2), max(h, 2))
    }

    /// GIFs render smaller, so they stay a sane file size.
    static func gifSize(canvasWidth: Int, canvasHeight: Int) -> (width: Int, height: Int) {
        let longEdge = Double(max(canvasWidth, canvasHeight, 1))
        let scale = 900.0 / longEdge
        return (max(Int(Double(canvasWidth) * scale), 2), max(Int(Double(canvasHeight) * scale), 2))
    }
}
