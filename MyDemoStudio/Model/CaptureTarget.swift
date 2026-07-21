import Foundation
import CoreGraphics

/// A capturable window surfaced to the picker.
struct CaptureWindowInfo: Identifiable, Sendable, Equatable, Hashable {
    let id: CGWindowID
    let title: String
    let appName: String

    var displayName: String {
        title.isEmpty ? appName : "\(appName) — \(title)"
    }
}

/// What the recorder captures: the whole display, or a single window (for the clean
/// single-window-on-a-background look).
enum CaptureTarget: Sendable, Equatable, Hashable {
    case display
    case window(CaptureWindowInfo)

    var label: String {
        switch self {
        case .display: return "Entire Screen"
        case .window(let info): return info.displayName
        }
    }

    var isWindow: Bool {
        if case .window = self { return true }
        return false
    }

    /// The captured window's id, so the picker can tick the current selection.
    var windowID: CGWindowID? {
        if case .window(let info) = self { return info.id }
        return nil
    }
}
