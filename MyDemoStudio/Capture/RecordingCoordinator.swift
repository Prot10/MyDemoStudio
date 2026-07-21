import Foundation
import Observation
import AppKit
import AVFoundation

/// MainActor-facing recording controller. Owns the `ScreenRecorder`, manages the
/// project package for each take, and exposes observable state for the UI.
@MainActor
@Observable
final class RecordingCoordinator {

    enum State: Equatable {
        case idle
        case recording
        case finishing
    }

    enum ExportState: Equatable {
        case idle
        case exporting
        case done
    }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastProject: DemoProject?
    private(set) var lastEventCount: Int = 0
    private(set) var errorMessage: String?

    private(set) var exportState: ExportState = .idle
    private(set) var exportProgress: Double = 0
    private(set) var lastExportURL: URL?

    var isRecording: Bool { state == .recording }
    var isBusy: Bool { state == .finishing }
    var isExporting: Bool { exportState == .exporting }

    /// Whether to record microphone voiceover into the master movie.
    var recordMicrophone: Bool = true
    /// Whether to record the webcam bubble.
    var recordWebcam: Bool = true
    private let webcam = WebcamRecorder()

    /// What to capture: entire screen or a single window.
    var captureTarget: CaptureTarget = .display
    private(set) var availableWindows: [CaptureWindowInfo] = []

    /// Refreshes the list of capturable windows for the picker.
    func refreshWindows() async {
        availableWindows = await ScreenRecorder.availableWindows()
    }

    private let recorder = ScreenRecorder()
    private var project: DemoProject?
    private var startDate: Date?
    private var timerTask: Task<Void, Never>?

    // MARK: Intent

    func toggle() {
        switch state {
        case .idle:      Task { await start() }
        case .recording: Task { await stop() }
        case .finishing: break
        }
    }

    func start() async {
        guard state == .idle else { return }
        errorMessage = nil
        lastProject = nil
        lastEventCount = 0
        exportState = .idle
        exportProgress = 0
        lastExportURL = nil
        do {
            let dir = try DemoProject.defaultLibraryDirectory()
            let project = try DemoProject.create(named: Self.timestampName(), in: dir)
            self.project = project

            // Ask for the mic only if the user wants voiceover; fall back to silent
            // capture if it's denied so recording still works.
            var micEnabled = false
            if recordMicrophone {
                micEnabled = await AVCaptureDevice.requestAccess(for: .audio)
            }

            // Start the webcam first so its clip lines up with the screen capture.
            if recordWebcam, await AVCaptureDevice.requestAccess(for: .video) {
                webcam.start(to: project.cameraURL)
            }

            try await recorder.start(to: project, target: captureTarget, recordMicrophone: micEnabled)
            state = .recording
            startTimer()
        } catch {
            errorMessage = Self.friendly(error)
            self.project = nil
            state = .idle
        }
    }

    func stop() async {
        guard state == .recording, let project else { return }
        state = .finishing
        stopTimer()
        webcam.stop()
        do {
            try await recorder.stop(writingTo: project)
            let track = try? project.readEventTrack()
            lastEventCount = track?.events.count ?? 0
            lastProject = project
        } catch {
            errorMessage = Self.friendly(error)
        }
        self.project = nil
        state = .idle
    }

    func revealLastProject() {
        guard let url = lastProject?.packageURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Renders the last recording through the Metal compositor and opens the result.
    /// Output is capped to 1920px wide so test exports stay fast.
    func exportLast() async {
        guard let project = lastProject, exportState != .exporting else { return }
        errorMessage = nil
        exportState = .exporting
        exportProgress = 0
        do {
            let track = try project.readEventTrack()
            var settings = RenderSettings.makeDefault(masterWidth: track.pixelWidth, masterHeight: track.pixelHeight)
            if track.pixelWidth > 1920 {
                let ratio = Double(track.pixelHeight) / Double(track.pixelWidth)
                settings.outputWidth = 1920
                settings.outputHeight = Int((1920.0 * ratio).rounded())
            }
            // H.264 requires even dimensions.
            settings.outputWidth -= settings.outputWidth % 2
            settings.outputHeight -= settings.outputHeight % 2

            let outputURL = project.packageURL.appendingPathComponent("polished.mov")
            try await VideoExporter.export(project: project, settings: settings, to: outputURL) { [weak self] p in
                Task { @MainActor in self?.exportProgress = p }
            }
            lastExportURL = outputURL
            exportState = .done
            NSWorkspace.shared.open(outputURL)
        } catch {
            errorMessage = Self.friendly(error)
            exportState = .idle
        }
    }

    // MARK: Timer

    private func startTimer() {
        startDate = Date()
        elapsed = 0
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let start = self.startDate else { break }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        startDate = nil
    }

    // MARK: Helpers

    private static func timestampName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Recording \(formatter.string(from: Date()))"
    }

    private static func friendly(_ error: Error) -> String {
        if let recorderError = error as? ScreenRecorder.RecorderError {
            switch recorderError {
            case .noDisplayAvailable: return "No display was available to record."
            case .permissionDenied:   return "Screen Recording permission is required."
            case .alreadyRecording:   return "A recording is already in progress."
            }
        }
        return error.localizedDescription
    }
}
