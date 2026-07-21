import Foundation
import ScreenCaptureKit
import ImageIO
import AppKit

/// Debug-only: has the app screenshot its OWN window via ScreenCaptureKit and write a
/// PNG, so the editor UI can be inspected headlessly (a background-launched app can't
/// steal focus, so ordinary screencapture grabs the wrong window). Bypass mode only.
enum DebugWindowShot {
    static func capture(after seconds: Double, to path: String) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            NSLog("MDSShot: capturing…")
            guard let content = try? await SCShareableContent.current else {
                NSLog("MDSShot: no shareable content"); return
            }
            let bundleID = Bundle.main.bundleIdentifier

            // ScreenCaptureKit can only capture a window that is actually on screen, and
            // a background-launched app doesn't reliably come forward on the first try.
            // Keep activating and re-querying until one shows up.
            var window: SCWindow?
            for attempt in 0..<10 {
                await MainActor.run {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
                }
                try? await Task.sleep(for: .milliseconds(600))
                guard let fresh = try? await SCShareableContent.current else { continue }
                let mineAll = fresh.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID }
                if attempt == 0 {
                    NSLog("MDSShot: found \(mineAll.count) own windows; frames \(mineAll.map { "\(Int($0.frame.width))x\(Int($0.frame.height)) onscreen=\($0.isOnScreen)" })")
                }
                let wanted = ProcessInfo.processInfo.environment["MDS_SHOT_TITLE"]
                let candidates = mineAll.filter { $0.frame.width > 400 && $0.frame.height > 300 && $0.isOnScreen }
                let preferred = wanted.flatMap { hint in
                    candidates.first { ($0.title ?? "").localizedCaseInsensitiveContains(hint) }
                }
                if let match = preferred ?? (wanted == nil ? candidates.first : nil) {
                    window = match
                    break
                }
            }
            guard let window else { NSLog("MDSShot: no on-screen window to capture"); return }
            _ = content

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * 2)
            config.height = Int(window.frame.height * 2)

            let image: CGImage
            do {
                image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            } catch {
                NSLog("MDSShot: captureImage failed: \(error)")
                return
            }

            let url = URL(fileURLWithPath: path)
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
                NSLog("MyDemoStudio: wrote window shot to \(path)")
            }
        }
    }
}
