import Foundation
import AVFoundation
import Observation
import AppKit

/// Drives the editor: holds the editable `RenderSettings`, a live-preview `AVPlayer`
/// wired to the same `DemoCompositor` used for export, and derived zoom intervals for
/// the timeline. Setting changes debounce a preview rebuild and persist to disk.
@MainActor
@Observable
final class ProjectEditorModel {

    let project: DemoProject
    var settings: RenderSettings
    private(set) var eventTrack: EventTrack

    let player = AVPlayer()
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var isReady = false
    private(set) var zoomIntervals: [ClosedRange<Double>] = []

    // Export state.
    private(set) var isExporting = false
    private(set) var exportProgress: Double = 0
    private(set) var lastExportURL: URL?
    private(set) var errorMessage: String?

    // Captions.
    private(set) var isTranscribing = false
    private(set) var captionCount = 0

    private var built: BuiltAsset?
    private var fps: Int = 60
    private var rebuildTask: Task<Void, Never>?
    private var timeObserver: Any?

    // Preview audio (mixed voiceover + SFX) attached to the composition.
    private var audioRebuildTask: Task<Void, Never>?
    private var previewAudioAsset: AVURLAsset?
    private var previewAudioURL: URL?
    private var previewAudioTrackID: CMPersistentTrackID?
    private var lastAudioSignature: [Double] = [-1]

    init?(project: DemoProject) {
        guard let track = try? project.readEventTrack() else { return nil }
        self.project = project
        self.eventTrack = track
        self.settings = project.readSettings()
            ?? .makeDefault(masterWidth: track.pixelWidth, masterHeight: track.pixelHeight)
        Task { await load() }
    }

    private func load() async {
        guard let built = try? await CompositionBuilder.buildAsset(
            masterURL: project.masterURL,
            cameraURL: project.hasCamera ? project.cameraURL : nil
        ) else { return }

        self.built = built
        fps = built.fps
        duration = CMTimeGetSeconds(built.duration)

        let item = AVPlayerItem(asset: built.asset)
        applyComposition(to: item)
        player.replaceCurrentItem(with: item)

        // Track playhead ~30fps for the timeline.
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = CMTimeGetSeconds(time)
            self.isPlaying = self.player.rate != 0
        }

        recomputeZoomIntervals()
        isReady = true
        rebuildPreviewAudio()
    }

    /// Builds the mixed audio (voiceover + SFX) and attaches it to the composition so it
    /// plays in the live preview. Only rebuilds when audio-relevant settings change.
    private func rebuildPreviewAudio(force: Bool = false) {
        let signature = [settings.sfxEnabled ? 1.0 : 0.0, settings.sfxVolume, settings.voiceoverVolume]
        if !force && signature == lastAudioSignature { return }
        lastAudioSignature = signature

        audioRebuildTask?.cancel()
        audioRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled, let built = self.built else { return }

            let newURL = try? await AudioMixer.buildMixedAudio(
                masterURL: self.project.masterURL, eventTrack: self.eventTrack,
                settings: self.settings, duration: CMTimeGetSeconds(built.duration))
            guard !Task.isCancelled else {
                if let newURL { try? FileManager.default.removeItem(at: newURL) }
                return
            }

            // Swap out any previous preview-audio track + temp file.
            if let id = self.previewAudioTrackID, let old = built.asset.track(withTrackID: id) {
                built.asset.removeTrack(old)
            }
            self.previewAudioTrackID = nil
            if let oldURL = self.previewAudioURL { try? FileManager.default.removeItem(at: oldURL) }
            self.previewAudioURL = newURL
            self.previewAudioAsset = nil

            if let newURL {
                let asset = AVURLAsset(url: newURL)
                self.previewAudioAsset = asset      // retain so the track stays valid
                if let src = try? await asset.loadTracks(withMediaType: .audio).first,
                   let comp = built.asset.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try? comp.insertTimeRange(CMTimeRange(start: .zero, duration: built.duration), of: src, at: .zero)
                    self.previewAudioTrackID = comp.trackID
                }
            }

            // Reload the player item, preserving playhead.
            let resumeTime = self.player.currentTime()
            let wasPlaying = self.player.rate != 0
            let item = AVPlayerItem(asset: built.asset)
            self.applyComposition(to: item)
            self.player.replaceCurrentItem(with: item)
            await self.player.seek(to: resumeTime)
            if wasPlaying { self.player.play() }
        }
    }

    // MARK: Preview composition

    private func applyComposition(to item: AVPlayerItem) {
        guard let built else { return }
        item.videoComposition = CompositionBuilder.videoComposition(
            settings: settings, eventTrack: eventTrack, built: built, captions: project.readCaptions()
        )
    }

    /// Call when `settings` changes; debounces a preview rebuild + persist.
    func settingsChanged() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled, let item = self.player.currentItem else { return }
            self.applyComposition(to: item)
            self.recomputeZoomIntervals()
            try? self.project.writeSettings(self.settings)
        }
        rebuildPreviewAudio()   // no-op unless an audio setting actually changed
    }

    private func recomputeZoomIntervals() {
        let planner = ZoomPlanner(track: eventTrack, settings: settings)
        zoomIntervals = planner.intervals
    }

    // MARK: Transport

    func togglePlay() {
        if player.rate != 0 {
            player.pause()
        } else {
            if currentTime >= duration - 0.05 { seek(to: 0) }
            player.play()
        }
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }

    // MARK: Export

    func export(format: ExportFormat, preset: ExportPreset, to outputURL: URL) async {
        guard !isExporting else { return }
        errorMessage = nil
        isExporting = true
        exportProgress = 0

        // Scale the current canvas (aspect) to the chosen resolution.
        var exportSettings = settings
        let size = format.isGIF
            ? ExportPreset.gifSize(canvasWidth: settings.outputWidth, canvasHeight: settings.outputHeight)
            : preset.outputSize(canvasWidth: settings.outputWidth, canvasHeight: settings.outputHeight)
        exportSettings.outputWidth = size.width
        exportSettings.outputHeight = size.height

        do {
            let onProgress: @Sendable (Double) -> Void = { [weak self] p in
                Task { @MainActor in self?.exportProgress = p }
            }
            if format.isGIF {
                try await VideoExporter.exportGIF(project: project, settings: exportSettings,
                                                  frameRate: format.gifFrameRate, to: outputURL, progress: onProgress)
            } else {
                try await VideoExporter.export(project: project, settings: exportSettings,
                                               format: format, to: outputURL, progress: onProgress)
            }
            lastExportURL = outputURL
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        } catch {
            errorMessage = error.localizedDescription
        }
        isExporting = false
    }

    func resetLook() {
        settings = .makeDefault(masterWidth: eventTrack.pixelWidth, masterHeight: eventTrack.pixelHeight)
        settingsChanged()
    }

    /// Transcribes the voiceover into captions (on-device), then refreshes the preview.
    func generateCaptions() async {
        guard !isTranscribing else { return }
        errorMessage = nil
        isTranscribing = true
        do {
            let audioURL = try await extractAudio(from: project.masterURL)
            let segments = try await CaptionsTranscriber.transcribe(audioURL: audioURL)
            try project.writeCaptions(CaptionTrack(segments: segments))
            try? FileManager.default.removeItem(at: audioURL)
            captionCount = segments.count
            settings.captionsEnabled = true
            settingsChanged()
        } catch {
            errorMessage = "Captions: \(error.localizedDescription)"
        }
        isTranscribing = false
    }

    /// Extracts the master's audio to a temporary m4a for transcription.
    private func extractAudio(from movURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: movURL)
        guard let audioTracks = try? await asset.loadTracks(withMediaType: .audio), !audioTracks.isEmpty else {
            throw CaptionsTranscriber.TranscribeError.noAudio
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CaptionsTranscriber.TranscribeError.notAvailable
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("mds_vo_\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: output)
        try await session.export(to: output, as: .m4a)
        return output
    }

    /// Changes the output shape, recomputing the canvas dimensions from the master.
    func setAspect(_ aspect: OutputAspect) {
        settings.aspect = aspect
        let size = aspect.canvasSize(masterWidth: eventTrack.pixelWidth, masterHeight: eventTrack.pixelHeight)
        settings.outputWidth = size.width
        settings.outputHeight = size.height
        settingsChanged()
    }
}
