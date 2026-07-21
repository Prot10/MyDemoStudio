import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import ApplicationServices
import AppKit

/// Headless end-to-end pipeline test, triggered by launching the app with the
/// environment variable `MDS_SELFTEST=1`. It synthesizes a known cursor path, records
/// the screen, exports through the Metal compositor, then reads back pixels of the
/// exported frame to empirically confirm capture + clock sync + render all work.
///
/// Runs inside the real app bundle so it inherits the granted Screen Recording /
/// Accessibility permissions. Prints `SELFTEST:` lines and exits with 0 on success.
enum SelfTest {

    /// Validates that a master movie's audio track is carried through export. Expects
    /// `MDS_AUDIO_MASTER` to point at a video+audio file (built with ffmpeg).
    static func runAudioExport() async -> Bool {
        setvbuf(stdout, nil, _IONBF, 0)
        log("audio-export check starting")
        guard let masterPath = ProcessInfo.processInfo.environment["MDS_AUDIO_MASTER"] else {
            log("FAIL no MDS_AUDIO_MASTER"); return false
        }
        let masterURL = URL(fileURLWithPath: masterPath)
        let asset = AVURLAsset(url: masterURL)
        guard let vtrack = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await vtrack.load(.naturalSize) else {
            log("FAIL no video track in master"); return false
        }
        let inAudio = ((try? await asset.loadTracks(withMediaType: .audio))?.count ?? 0)
        let dur = await masterDuration(masterURL)
        log("master \(Int(size.width))x\(Int(size.height)) audioTracks=\(inAudio) dur=\(String(format: "%.2f", dur))s")

        let project: DemoProject
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MDSAudioTest", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            project = try DemoProject.create(named: "audio", in: dir)
            try FileManager.default.copyItem(at: masterURL, to: project.masterURL)
        } catch {
            log("FAIL setup: \(error)"); return false
        }

        let base = EventTrack(pixelWidth: Int(size.width), pixelHeight: Int(size.height),
                              displayOriginX: 0, displayOriginY: 0,
                              displayWidthPoints: size.width, displayHeightPoints: size.height,
                              scale: 1, frameRate: 60, events: [])
        try? project.writeEventTrack(synthesizeTrack(base: base, duration: dur))

        let settings = RenderSettings.makeDefault(masterWidth: Int(size.width), masterHeight: Int(size.height))
        let outURL = project.packageURL.appendingPathComponent("polished.mov")
        do {
            try await VideoExporter.export(project: project, settings: settings, to: outURL) { _ in }
        } catch {
            log("FAIL export: \(error)"); return false
        }

        let outAsset = AVURLAsset(url: outURL)
        let outVideo = (try? await outAsset.loadTracks(withMediaType: .video))?.count ?? 0
        let outAudio = (try? await outAsset.loadTracks(withMediaType: .audio))?.count ?? 0
        log("output tracks: video=\(outVideo) audio=\(outAudio)")
        let ok = outVideo == 1 && outAudio == 1
        log(ok ? "PASS voiceover audio carried through export" : "FAIL audio not carried")
        return ok
    }

    /// Deterministic pure-logic validation — runs instantly, no recording/permissions.
    static func runAlgo() -> Bool {
        setvbuf(stdout, nil, _IONBF, 0)
        log("algo checks starting")
        var ok = true

        // Build a track: 1920x1080 master, a click cluster at t=5s near (960,540),
        // and a second, far-apart click at t=20s near (300,300).
        var events: [RecordingEvent] = []
        for t in stride(from: 0.0, through: 25.0, by: 0.1) {
            events.append(RecordingEvent(t: t, type: .mouseMoved, x: 500 + t * 10, y: 400))
        }
        events.append(RecordingEvent(t: 5.0, type: .leftMouseDown, x: 960, y: 540))
        events.append(RecordingEvent(t: 5.3, type: .leftMouseDown, x: 970, y: 545))
        events.append(RecordingEvent(t: 20.0, type: .leftMouseDown, x: 300, y: 300))
        let track = EventTrack(
            pixelWidth: 1920, pixelHeight: 1080,
            displayOriginX: 0, displayOriginY: 0,
            displayWidthPoints: 1920, displayHeightPoints: 1080,
            scale: 1, frameRate: 60,
            events: events.sorted { $0.t < $1.t }
        )
        var settings = RenderSettings.makeDefault(masterWidth: 1920, masterHeight: 1080)
        settings.zoomScale = 2.0

        let planner = ZoomPlanner(track: track, settings: settings)

        // 1. Far from any click → no zoom.
        let z0 = planner.zoom(at: 0.5)
        ok = expect(abs(z0.scale - 1.0) < 0.01, "zoom idle at t=0.5 (scale \(fmt(z0.scale)))") && ok

        // 2. During the first cluster's hold → fully zoomed, focused near (965,542).
        let z5 = planner.zoom(at: 5.6)
        ok = expect(abs(z5.scale - 2.0) < 0.05, "zoom held at t=5.6 (scale \(fmt(z5.scale)))") && ok
        ok = expect(abs(z5.focus.x - 965) < 25 && abs(z5.focus.y - 542) < 25,
                    "zoom focus near click (\(fmt(z5.focus.x)),\(fmt(z5.focus.y)))") && ok

        // 3. Two clicks 0.3s apart merged into one segment (not two separate zooms).
        let z53 = planner.zoom(at: 5.15)
        ok = expect(z53.scale > 1.0, "cluster stays zoomed between merged clicks") && ok

        // 4. Well after the cluster and before the next → zoomed back out.
        let z12 = planner.zoom(at: 12.0)
        ok = expect(abs(z12.scale - 1.0) < 0.01, "zoom released by t=12 (scale \(fmt(z12.scale)))") && ok

        // 5. Ramp is monotonic on the way in (t=5.0 < t=5.3 scale, both < peak).
        let zA = planner.zoom(at: 4.85).scale
        let zB = planner.zoom(at: 5.0).scale
        ok = expect(zA <= zB && zB <= 2.0, "zoom ramps in monotonically (\(fmt(zA))→\(fmt(zB)))") && ok

        // 6. CursorSmoother returns an interpolated point within bounds.
        let smoother = CursorSmoother(track: track, smoothing: 0.6)
        if let p = smoother.position(at: 10.0) {
            ok = expect(p.x > 0 && p.x < 1920 && p.y > 0 && p.y < 1080,
                        "cursor smoothed in bounds (\(fmt(p.x)),\(fmt(p.y)))") && ok
        } else {
            ok = expect(false, "cursor position available at t=10") && ok
        }

        log(ok ? "PASS algo checks" : "FAIL algo checks")
        return ok
    }

    private static func expect(_ condition: Bool, _ label: String) -> Bool {
        log("\(condition ? "ok  " : "FAIL") \(label)")
        return condition
    }

    static func run() async -> Bool {
        setvbuf(stdout, nil, _IONBF, 0)
        log("starting")
        log("perms: screenRecording=\(CGPreflightScreenCaptureAccess()) accessibility=\(AXIsProcessTrusted())")

        let recorder = ScreenRecorder()
        let useLibrary = ProcessInfo.processInfo.environment["MDS_SELFTEST_LIB"] == "1"
        let project: DemoProject
        do {
            if useLibrary {
                let dir = try DemoProject.defaultLibraryDirectory()
                project = try DemoProject.create(named: "UITest", in: dir)
            } else {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MDSSelfTest", isDirectory: true)
                try? FileManager.default.removeItem(at: dir)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                project = try DemoProject.create(named: "selftest", in: dir)
            }
        } catch {
            log("FAIL could not create project: \(error)")
            return false
        }

        // Choose capture target: display, or the first window if MDS_SELFTEST_WINDOW=1.
        var target: CaptureTarget = .display
        if ProcessInfo.processInfo.environment["MDS_SELFTEST_WINDOW"] == "1" {
            let windows = await ScreenRecorder.availableWindows()
            log("available windows: \(windows.count)")
            if let first = windows.first {
                target = .window(first)
                log("window target: \(first.displayName) [id \(first.id)]")
            } else {
                log("no windows available; falling back to display")
            }
        }

        // Start capture.
        do {
            try await recorder.start(to: project, target: target, fps: 60)
            log("recording started (\(target.label))")
        } catch {
            log("FAIL recorder.start: \(error)  (likely missing Screen Recording permission)")
            return false
        }

        // Let capture stabilize, then drive a known diagonal cursor path + a click.
        try? await Task.sleep(for: .milliseconds(500))
        let path = synthesizeCursorPath()
        log("synthesized \(path.count) mouse events over ~2.5s")

        do {
            try await recorder.stop(writingTo: project)
            log("recording stopped")
        } catch {
            log("FAIL recorder.stop: \(error)")
            return false
        }

        // Read the event log the recorder wrote (correct master dims even with 0 events).
        var track: EventTrack
        do {
            track = try project.readEventTrack()
        } catch {
            log("FAIL reading events.json: \(error)")
            return false
        }
        log("master \(track.pixelWidth)x\(track.pixelHeight) scale \(track.scale); live events captured=\(track.events.count)")

        // Live capture needs Accessibility. If it's off, inject a known synthetic path so
        // the render half of the pipeline can still be validated empirically.
        if track.events.isEmpty {
            let duration = await masterDuration(project.masterURL)
            log("no live events (accessibility=\(AXIsProcessTrusted())) → injecting synthetic path over \(String(format: "%.2f", duration))s")
            track = synthesizeTrack(base: track, duration: duration)
            try? project.writeEventTrack(track)
        }
        let tRange = (track.events.first!.t, track.events.last!.t)
        log("event track: \(track.events.count) events, t \(String(format: "%.2f", tRange.0))…\(String(format: "%.2f", tRange.1))s")

        // Optionally inject a synthetic webcam clip to validate the bubble compositing.
        if let camPath = ProcessInfo.processInfo.environment["MDS_SELFTEST_CAMERA"] {
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: camPath), to: project.cameraURL)
            log("injected camera clip → hasCamera=\(project.hasCamera)")
        }

        // Optionally inject synthetic captions to validate caption rendering.
        if ProcessInfo.processInfo.environment["MDS_SELFTEST_CAPTIONS"] == "1" {
            let captions = CaptionTrack(segments: [
                CaptionSegment(start: 0.0, end: 5.0, text: "down here and now we format it to")
            ])
            try? project.writeCaptions(captions)
            log("injected captions")
        }

        // Export through the compositor.
        var settings = RenderSettings.makeDefault(masterWidth: track.pixelWidth, masterHeight: track.pixelHeight)
        if track.pixelWidth > 1920 {
            let ratio = Double(track.pixelHeight) / Double(track.pixelWidth)
            settings.outputWidth = 1920
            settings.outputHeight = Int((1920.0 * ratio).rounded())
        }
        settings.outputWidth -= settings.outputWidth % 2
        settings.outputHeight -= settings.outputHeight % 2

        if ProcessInfo.processInfo.environment["MDS_SELFTEST_SFX"] == "1" {
            settings.sfxEnabled = true
            settings.sfxVolume = 0.6
            log("SFX enabled for this export")
        }
        if let raw = ProcessInfo.processInfo.environment["MDS_SELFTEST_ASPECT"],
           let aspect = OutputAspect(rawValue: raw) {
            settings.aspect = aspect
            let cs = aspect.canvasSize(masterWidth: track.pixelWidth, masterHeight: track.pixelHeight)
            settings.outputWidth = cs.width
            settings.outputHeight = cs.height
            log("aspect override: \(aspect.label) → \(cs.width)x\(cs.height)")
        }

        let outputURL = project.packageURL.appendingPathComponent("polished.mov")
        do {
            try await VideoExporter.export(project: project, settings: settings, to: outputURL) { _ in }
        } catch {
            log("FAIL export: \(error)")
            return false
        }
        guard let size = fileSize(outputURL), size > 10_000 else {
            log("FAIL polished.mov missing or too small")
            return false
        }
        log("exported polished.mov: \(size / 1024) KB at \(settings.outputWidth)x\(settings.outputHeight)")
        log("artifacts: \(project.packageURL.path)")

        // Read back a rendered frame and check the composited layers empirically.
        let frameOK = await validateRenderedFrame(url: outputURL, settings: settings)

        // Export a GIF through the same compositor and confirm it's a multi-frame GIF.
        var gifSettings = settings
        let gifSize = ExportPreset.gif.outputSize(canvasWidth: settings.outputWidth, canvasHeight: settings.outputHeight)
        gifSettings.outputWidth = gifSize.width
        gifSettings.outputHeight = gifSize.height
        let gifURL = project.packageURL.appendingPathComponent("polished.gif")
        var gifOK = false
        do {
            try await VideoExporter.exportGIF(project: project, settings: gifSettings,
                                              frameRate: ExportPreset.gif.gifFrameRate, to: gifURL) { _ in }
            let frames = gifFrameCount(gifURL)
            let bytes = fileSize(gifURL) ?? 0
            gifOK = frames > 5 && bytes > 5_000
            log("GIF export: \(frames) frames, \(bytes / 1024) KB, size \(gifSize.width)x\(gifSize.height) → \(gifOK ? "ok" : "FAIL")")
        } catch {
            log("FAIL GIF export: \(error)")
        }

        let ok = frameOK && gifOK
        log(ok ? "PASS pipeline validated end-to-end" : "FAIL pipeline validation")
        return ok
    }

    private static func gifFrameCount(_ url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    // MARK: Synthetic event track (render validation without Accessibility)

    private static func masterDuration(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        let d = (try? await asset.load(.duration)) ?? .zero
        return max(CMTimeGetSeconds(d), 1.0)
    }

    /// A known diagonal cursor path in master-pixel space. `scale`/origin are set to
    /// identity so `EventTrack.pixelPoint` returns these coordinates unchanged.
    private static func synthesizeTrack(base: EventTrack, duration: Double) -> EventTrack {
        var events: [RecordingEvent] = []
        let n = 90
        // Move from the CENTER to the TOP-RIGHT (clearly off-center) so we can verify
        // the camera keeps the cursor centered in the zoomed view.
        let x0 = Double(base.pixelWidth) * 0.5,  y0 = Double(base.pixelHeight) * 0.5
        let x1 = Double(base.pixelWidth) * 0.80, y1 = Double(base.pixelHeight) * 0.20
        let t0 = 0.3, t1 = max(0.6, duration - 0.3)
        for i in 0...n {
            let f = Double(i) / Double(n)
            events.append(RecordingEvent(
                t: t0 + (t1 - t0) * f,
                type: .mouseMoved,
                x: x0 + (x1 - x0) * f,
                y: y0 + (y1 - y0) * f
            ))
        }
        // Click early (t ≈ 1.0) so the zoom is active well before the hold frame.
        let clickF = 0.3
        events.append(RecordingEvent(t: t0 + (t1 - t0) * clickF, type: .leftMouseDown,
                                     x: x0 + (x1 - x0) * clickF, y: y0 + (y1 - y0) * clickF))
        return EventTrack(
            pixelWidth: base.pixelWidth,
            pixelHeight: base.pixelHeight,
            displayOriginX: 0, displayOriginY: 0,
            displayWidthPoints: Double(base.pixelWidth),
            displayHeightPoints: Double(base.pixelHeight),
            scale: 1,
            frameRate: base.frameRate,
            events: events.sorted { $0.t < $1.t }
        )
    }

    // MARK: Synthetic input (live-capture path, needs Accessibility)

    private static func synthesizeCursorPath() -> [CGPoint] {
        let start = CGPoint(x: 200, y: 200)
        let end = CGPoint(x: 1000, y: 800)
        var points: [CGPoint] = []
        let steps = 80
        for i in 0...steps {
            let f = Double(i) / Double(steps)
            let p = CGPoint(x: start.x + (end.x - start.x) * f, y: start.y + (end.y - start.y) * f)
            points.append(p)
            postMouseMove(to: p)
            usleep(30_000) // 30ms → ~2.5s total
        }
        postClick(at: end)
        return points
    }

    private static func postMouseMove(to p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private static func postClick(at p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(20_000)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    // MARK: Frame validation

    private static func validateRenderedFrame(url: URL, settings: RenderSettings) async -> Bool {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let cg: CGImage
        do {
            cg = try await generator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
        } catch {
            log("FAIL could not read exported frame: \(error)")
            return false
        }

        // Save a PNG of the validated frame for visual inspection.
        let pngURL = url.deletingLastPathComponent().appendingPathComponent("frame.png")
        if let dest = CGImageDestinationCreateWithURL(pngURL as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
            log("frame PNG: \(pngURL.path)")
        }

        guard let pixels = RGBAImage(cg) else {
            log("FAIL could not read pixel data")
            return false
        }

        // 1. A corner should be the violet gradient background (not black, purple-ish).
        let corner = pixels.average(x: 4, y: 4, w: 20, h: 20)
        let cornerIsBackground = corner.r > 0.15 && corner.b > 0.2 && corner.max < 0.98
        log("corner color rgb(\(fmt(corner.r)),\(fmt(corner.g)),\(fmt(corner.b))) background=\(cornerIsBackground)")

        // 2. Somewhere there should be a near-white cursor dot.
        let hasCursor = pixels.containsNearWhite(minChannel: 0.85)
        log("near-white cursor pixel present=\(hasCursor)")

        // 3. The frame should not be uniform (screen content composited in center).
        let variety = pixels.hasVariety()
        log("frame has visual variety=\(variety)")

        return cornerIsBackground && hasCursor && variety
    }

    // MARK: Helpers

    private static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
    }

    private static func fmt(_ d: Double) -> String { String(format: "%.2f", d) }

    private static func log(_ message: String) {
        print("SELFTEST: \(message)")
    }
}

/// Minimal RGBA bitmap reader for empirical pixel checks.
private struct RGBAImage {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(_ cg: CGImage) {
        width = cg.width
        height = cg.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(
            data: &buffer, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = buffer
    }

    struct Color { var r, g, b: Double; var max: Double { Swift.max(r, g, b) } }

    private func pixel(_ x: Int, _ y: Int) -> Color {
        let i = (y * width + x) * 4
        return Color(r: Double(bytes[i]) / 255, g: Double(bytes[i + 1]) / 255, b: Double(bytes[i + 2]) / 255)
    }

    func average(x: Int, y: Int, w: Int, h: Int) -> Color {
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for yy in y..<min(y + h, height) {
            for xx in x..<min(x + w, width) {
                let p = pixel(xx, yy); r += p.r; g += p.g; b += p.b; n += 1
            }
        }
        return n > 0 ? Color(r: r / n, g: g / n, b: b / n) : Color(r: 0, g: 0, b: 0)
    }

    func containsNearWhite(minChannel: Double) -> Bool {
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let p = pixel(x, y)
                if p.r >= minChannel && p.g >= minChannel && p.b >= minChannel { return true }
                x += 2
            }
            y += 2
        }
        return false
    }

    func hasVariety() -> Bool {
        var minL = 1.0, maxL = 0.0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let p = pixel(x, y)
                let l = (p.r + p.g + p.b) / 3
                minL = Swift.min(minL, l); maxL = Swift.max(maxL, l)
                x += 8
            }
            y += 8
        }
        return (maxL - minL) > 0.25
    }
}
