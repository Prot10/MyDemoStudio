import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AVFoundation
import CoreGraphics
import Synchronization

/// Records a display to `master.mov` via ScreenCaptureKit's `SCRecordingOutput`, while
/// an attached stream output captures the first frame's host time as the sync anchor
/// (`t0`) that rebases the event log onto the video timeline.
final class ScreenRecorder: NSObject, @unchecked Sendable {

    enum RecorderError: Error {
        case noDisplayAvailable
        case permissionDenied
        case alreadyRecording
    }

    private struct CaptureMeta {
        var pixelWidth: Int
        var pixelHeight: Int
        var originX: Double
        var originY: Double
        var widthPoints: Double
        var heightPoints: Double
        var scale: Double
        var fps: Int
    }

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private let eventTap = EventTap()
    private let sampleQueue = DispatchQueue(label: "com.andrea.mydemostudio.screenrecorder.samples")

    private let firstFrameAnchor = Mutex<Double?>(nil)
    private var captureMeta: CaptureMeta?

    private(set) var isRecording = false

    // MARK: Start

    /// Real, recordable app windows (on-screen, normal layer, reasonably sized, not
    /// our own and not system/desktop chrome like the Dock or the wallpaper backstop).
    @concurrent
    static func availableWindows() async -> [CaptureWindowInfo] {
        guard let content = try? await SCShareableContent.current else { return [] }
        let ownID = Bundle.main.bundleIdentifier
        let systemBundles: Set<String> = [
            "com.apple.WindowServer", "com.apple.dock", "com.apple.controlcenter",
            "com.apple.notificationcenterui", "com.apple.wallpaper", "com.apple.systemuiserver"
        ]
        // A full-screen app lives on its own Space, so it reports isOnScreen == false when
        // you're viewing a different Space. Detect it by its frame matching a display.
        let displays = content.displays
        func isFullScreen(_ window: SCWindow) -> Bool {
            displays.contains { display in
                abs(display.frame.width - window.frame.width) < 4 &&
                abs(display.frame.height - window.frame.height) < 4
            }
        }
        return content.windows.compactMap { window -> (info: CaptureWindowInfo, area: CGFloat)? in
            guard window.isOnScreen || isFullScreen(window),
                  window.windowLayer == 0,                       // normal app windows only
                  window.frame.width > 240, window.frame.height > 160,
                  let app = window.owningApplication,
                  app.bundleIdentifier != ownID,
                  !systemBundles.contains(app.bundleIdentifier),
                  !app.applicationName.isEmpty
            else { return nil }
            let info = CaptureWindowInfo(id: window.windowID, title: window.title ?? "", appName: app.applicationName)
            return (info, window.frame.width * window.frame.height)
        }
        .sorted { $0.area > $1.area }        // largest (most likely the main window) first
        .map(\.info)
    }

    @concurrent
    func start(to project: DemoProject, target: CaptureTarget = .display,
               fps: Int = 60, recordMicrophone: Bool = false) async throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw RecorderError.permissionDenied
        }

        // Resolve the capture filter + geometry for the chosen target.
        let filter: SCContentFilter
        let pixelWidth: Int
        let pixelHeight: Int
        var sourceRect: CGRect?

        switch target {
        case .window(let info):
            guard let window = content.windows.first(where: { $0.windowID == info.id }) else {
                throw RecorderError.noDisplayAvailable
            }
            // Capture the DISPLAY cropped to the window's rect (via sourceRect) rather than
            // a desktop-independent window — the latter makes macOS replace the traffic
            // lights with a system "screen sharing" pill in the captured frames.
            let display = content.displays.first(where: { $0.frame.intersects(window.frame) })
                ?? content.displays.first
            guard let display else { throw RecorderError.noDisplayAvailable }
            let ownWindows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let scale = Double(filter.pointPixelScale)
            // Window rect in the display's local point space, clamped to the display so we
            // never capture past the edge (which would leave black bars).
            let displayBounds = CGRect(origin: .zero, size: display.frame.size)
            let local = CGRect(
                x: window.frame.origin.x - display.frame.origin.x,
                y: window.frame.origin.y - display.frame.origin.y,
                width: window.frame.width, height: window.frame.height
            ).intersection(displayBounds)
            sourceRect = local
            pixelWidth = max(2, Int((local.width * scale).rounded()))
            pixelHeight = max(2, Int((local.height * scale).rounded()))
            captureMeta = CaptureMeta(
                pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                originX: Double(display.frame.origin.x) + Double(local.origin.x),
                originY: Double(display.frame.origin.y) + Double(local.origin.y),
                widthPoints: Double(local.width), heightPoints: Double(local.height),
                scale: scale, fps: fps
            )

        case .display:
            guard let display = content.displays.first else {
                throw RecorderError.noDisplayAvailable
            }
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            pixelWidth = mode?.pixelWidth ?? display.width
            pixelHeight = mode?.pixelHeight ?? display.height
            let scale = display.width > 0 ? Double(pixelWidth) / Double(display.width) : 2.0
            captureMeta = CaptureMeta(
                pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                originX: Double(display.frame.origin.x), originY: Double(display.frame.origin.y),
                widthPoints: Double(display.frame.width), heightPoints: Double(display.frame.height),
                scale: scale, fps: fps
            )
            // Exclude our own windows so the recorder UI never appears in the shot.
            let ownWindows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        }

        firstFrameAnchor.withLock { $0 = nil }

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        if let sourceRect {
            config.sourceRect = sourceRect          // crop the display to the window
            config.scalesToFit = false
        }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = false                 // we render our own smooth cursor
        config.capturesAudio = false               // system audio: off for now
        if recordMicrophone {
            config.captureMicrophone = true         // mic voiceover → recorded into master.mov
        }
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

        // Recording output must be added before startCapture so the first frame lands in the file.
        let recConfig = SCRecordingOutputConfiguration()
        recConfig.outputURL = project.masterURL
        recConfig.outputFileType = .mov
        let recOutput = SCRecordingOutput(configuration: recConfig, delegate: self)
        try stream.addRecordingOutput(recOutput)

        // Start logging input just before capture so we never miss early clicks.
        if !eventTap.start() {
            NSLog("MyDemoStudio: event tap failed to start — Accessibility permission likely missing; recording without input log.")
        }

        try await stream.startCapture()

        self.stream = stream
        self.recordingOutput = recOutput
        isRecording = true
    }

    // MARK: Stop

    /// Stops capture, rebases the event log onto the video timeline, and writes
    /// `events.json` into the project package.
    @concurrent
    func stop(writingTo project: DemoProject) async throws {
        guard isRecording, let stream else { return }
        isRecording = false

        try? await stream.stopCapture()   // also finalizes the recording file

        // stopCapture returns before the movie's moov atom is necessarily flushed;
        // wait until the file is actually playable so downstream export never reads a
        // half-written file ("media may be damaged").
        await Self.waitUntilReadable(project.masterURL, timeout: 3.0)

        let raw = eventTap.stop()

        let anchor = firstFrameAnchor.withLock { $0 }
        // Fall back to the earliest event if we somehow never saw a complete frame.
        let t0 = anchor ?? raw.map(\.hostTime).min() ?? 0

        let events: [RecordingEvent] = raw.compactMap { sample in
            let t = sample.hostTime - t0
            guard t >= 0 else { return nil }
            return RecordingEvent(t: t, type: sample.type, x: sample.x, y: sample.y)
        }

        let meta = captureMeta
        let track = EventTrack(
            pixelWidth: meta?.pixelWidth ?? 0,
            pixelHeight: meta?.pixelHeight ?? 0,
            displayOriginX: meta?.originX ?? 0,
            displayOriginY: meta?.originY ?? 0,
            displayWidthPoints: meta?.widthPoints ?? 0,
            displayHeightPoints: meta?.heightPoints ?? 0,
            scale: meta?.scale ?? 2.0,
            frameRate: meta?.fps ?? 60,
            events: events
        )
        try project.writeEventTrack(track)

        self.stream = nil
        self.recordingOutput = nil
        self.captureMeta = nil
    }

    /// Polls until the recording file reports as playable (its moov atom is present),
    /// or the timeout elapses.
    private static func waitUntilReadable(_ url: URL, timeout: Double) async {
        let deadline = timeout / 0.1
        var attempts = 0
        while attempts < Int(deadline) {
            let asset = AVURLAsset(url: url)
            if let playable = try? await asset.load(.isPlayable), playable,
               let duration = try? await asset.load(.duration), CMTimeGetSeconds(duration) > 0.05 {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
            attempts += 1
        }
    }
}

// MARK: - SCStreamOutput (first-frame sync anchor)

extension ScreenRecorder: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }

        // Anchor on the FIRST delivered sample's presentation time — this matches the
        // first frame written to master.mov. (Requiring status == .complete would skip
        // the leading idle frames of a static screen and push the anchor late, dropping
        // early events.)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, !pts.isIndefinite else { return }
        let seconds = CMTimeGetSeconds(pts)
        firstFrameAnchor.withLock { if $0 == nil { $0 = seconds } }
    }
}

// MARK: - SCStreamDelegate

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("MyDemoStudio: capture stream stopped with error: \(error.localizedDescription)")
        isRecording = false
    }
}

// MARK: - SCRecordingOutputDelegate

extension ScreenRecorder: SCRecordingOutputDelegate {
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        NSLog("MyDemoStudio: recording failed: \(error.localizedDescription)")
    }
}
