import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import Observation

/// The two macOS privacy permissions MyDemoStudio needs.
///
/// - Screen Recording (TCC): required by ScreenCaptureKit to capture the display.
/// - Accessibility / Input Monitoring: required by the `CGEventTap` that logs
///   cursor moves and clicks for the automatic-zoom timeline.
///
/// Both are granted through System Settings and take effect for the running app's
/// code signature. For a locally-run, ad-hoc-signed build that means the *path* of
/// the built `.app`; re-granting after moving the bundle is expected.
@MainActor
@Observable
final class PermissionsManager {

    enum Status: Equatable {
        case granted
        case denied
        case unknown

        var isGranted: Bool { self == .granted }
    }

    private(set) var screenRecording: Status = .unknown
    private(set) var accessibility: Status = .unknown

    /// True only when everything the capture pipeline needs is in place.
    /// `MDS_BYPASS_PERMS=1` forces the UI open for headless/editor testing.
    var allGranted: Bool {
        if ProcessInfo.processInfo.environment["MDS_BYPASS_PERMS"] == "1" { return true }
        return screenRecording.isGranted && accessibility.isGranted
    }

    init() {
        refresh()
    }

    /// Re-reads current permission state without prompting. Cheap; call on
    /// `.onAppear`, on app activation, and after returning from System Settings.
    func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .denied
        accessibility = AXIsProcessTrusted() ? .granted : .denied
    }

    /// True once the user has engaged the Screen Recording flow this session — used to
    /// nudge them to relaunch (Screen Recording only applies after a restart).
    private(set) var didRequestScreenRecording = false

    /// Triggers the system Screen Recording prompt (first call only; afterwards it
    /// is a no-op and the user must toggle it in System Settings).
    func requestScreenRecording() {
        didRequestScreenRecording = true
        CGRequestScreenCaptureAccess()
        refresh()
    }

    /// Relaunches the app. macOS only applies a new Screen Recording grant after the
    /// app restarts, so we spawn a tiny detached shell to reopen us right after we quit.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.5; open \"\(path)\""]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// Triggers the system Accessibility prompt with the "Open System Settings"
    /// affordance. Subsequent calls just re-check.
    func requestAccessibility() {
        // Use the documented literal for `kAXTrustedCheckOptionPrompt` — the imported
        // global is a non-Sendable `var` that Swift 6 strict concurrency rejects.
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: kCFBooleanTrue as Any] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    /// Deep-links into the relevant System Settings pane so the user can flip the
    /// toggle when the one-shot prompt has already been consumed.
    func openSettings(for pane: SettingsPane) {
        if let url = URL(string: pane.urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    enum SettingsPane {
        case screenRecording
        case accessibility

        var urlString: String {
            switch self {
            case .screenRecording:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            case .accessibility:
                return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            }
        }
    }
}
