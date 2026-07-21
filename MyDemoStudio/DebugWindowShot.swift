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
            let mineAll = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID }
            NSLog("MDSShot: found \(mineAll.count) own windows; frames \(mineAll.map { "\(Int($0.frame.width))x\(Int($0.frame.height)) onscreen=\($0.isOnScreen)" })")
            let mine = mineAll.first { $0.frame.width > 400 && $0.frame.height > 300 }
            guard let window = mine else { NSLog("MDSShot: no suitable window"); return }

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
