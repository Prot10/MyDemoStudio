import Foundation

/// Output options for export. Resolutions are caps (never upscaled beyond the
/// recording's native size); GIF renders smaller and at a lower frame rate.
enum ExportPreset: String, CaseIterable, Identifiable, Sendable {
    case uhd = "4K"
    case fullHD = "1080p"
    case hd = "720p"
    case gif = "GIF"

    var id: String { rawValue }

    var isGIF: Bool { self == .gif }

    /// Frame rate for GIF output.
    var gifFrameRate: Int { 16 }

    /// Longest-edge target in pixels for this quality.
    private var targetLongEdge: Int {
        switch self {
        case .uhd:    return 3840
        case .fullHD: return 1920
        case .hd:     return 1280
        case .gif:    return 900
        }
    }

    var fileExtension: String { isGIF ? "gif" : "mov" }

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
}
