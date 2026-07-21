import Foundation
import AVFoundation
import Observation
import AppKit
import SwiftUI

/// Drives the multi-clip editor: owns the `EditDocument`, keeps a live `AVPlayer`
/// preview wired to the same compositor the exporter uses, and persists every edit.
///
/// The single-recording editor's shape is deliberately mirrored here (debounced rebuild,
/// mixed preview audio, one compositor for preview and export) so both surfaces behave
/// the same. Every mutation goes through `edit(_:)`, which is what gives undo and
/// autosave for free.
@MainActor
@Observable
final class TimelineEditorModel {

    let project: EditProject
    private(set) var document: EditDocument

    let player = AVPlayer()
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var isReady = false
    private(set) var buildError: String?

    /// Currently selected clip, which drives the inspector.
    var selectedClipID: UUID?
    /// Horizontal timeline scale, in points per second.
    var pixelsPerSecond: Double = 60 {
        didSet { if !isAutoFitting { userChoseZoom = true } }
    }
    /// Set once the zoom has been chosen deliberately (slider or explicit fit), after
    /// which automatic fitting stops interfering.
    private var userChoseZoom = false
    private var isAutoFitting = false

    private(set) var isExporting = false
    private(set) var exportProgress: Double = 0
    private(set) var lastExportURL: URL?
    var errorMessage: String?

    let voiceover = VoiceoverRecorder()
    private(set) var isRecordingCamera = false
    private let webcam = WebcamRecorder()
    private var cameraURL: URL?
    private var cameraStartTime: Double = 0

    private var undoStack: [EditDocument] = []
    private var redoStack: [EditDocument] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private var built: BuiltTimeline?
    private var rebuildTask: Task<Void, Never>?
    /// Increments on every rebuild request; a build whose generation is stale never
    /// installs its result.
    private var rebuildGeneration: UInt64 = 0
    private var timeObserver: Any?
    private var previewAudioURL: URL?
    private var previewAudioAsset: AVURLAsset?
    /// Not main-actor isolated, so `deinit` can cancel it.
    private nonisolated(unsafe) var documentWatcher: DispatchSourceFileSystemObject?
    private var isApplyingExternalChange = false
    /// The document as this editor last wrote it, so the file watcher can tell our own
    /// saves apart from an edit made by the MCP server.
    private var lastWrittenDocument: EditDocument?

    var selectedClip: TimelineClip? { selectedClipID.flatMap { document.clip(id: $0) } }

    init?(project: EditProject) {
        guard let document = try? project.read() else { return nil }
        self.project = project
        self.document = document
        self.duration = document.duration

        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = CMTimeGetSeconds(time)
            self.isPlaying = self.player.rate != 0
        }
        rebuild(immediately: true)
        watchDocument()
    }

    deinit {
        documentWatcher?.cancel()
    }

    // MARK: Editing

    /// The single entry point for every change: pushes undo, mutates, saves, rebuilds.
    func edit(_ label: String = "", _ body: (inout EditDocument) -> Void) {
        undoStack.append(document)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
        body(&document)
        persistAndRebuild()
    }

    /// A continuous adjustment (dragging a slider). Same persist-and-rebuild path as
    /// `edit`, but without pushing an undo entry per tick — otherwise one slider drag
    /// would bury the undo stack.
    func adjust(_ body: (inout EditDocument) -> Void) {
        body(&document)
        persistAndRebuild()
    }

    /// Two-way binding onto a project-default look setting.
    func lookBinding<T>(_ keyPath: WritableKeyPath<RenderSettings, T>) -> Binding<T> {
        Binding(
            get: { self.document.defaultLook[keyPath: keyPath] },
            set: { value in self.adjust { $0.defaultLook[keyPath: keyPath] = value } }
        )
    }

    /// Two-way binding onto a field of the selected clip.
    func clipBinding<T>(_ keyPath: WritableKeyPath<TimelineClip, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { self.selectedClip?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard let id = self.selectedClipID else { return }
                self.adjust { document in
                    guard let ti = document.trackIndex(containingClip: id),
                          let ci = document.tracks[ti].clips.firstIndex(where: { $0.id == id }) else { return }
                    document.tracks[ti].clips[ci][keyPath: keyPath] = value
                }
            }
        )
    }

    /// Binding onto one of the selected clip's look overrides. Reading falls back to the
    /// project default, so the control always shows the value actually being rendered.
    func clipLookBinding<T>(
        read: @escaping (LookOverride) -> T?,
        write: @escaping (inout LookOverride, T) -> Void,
        inherited: @escaping (RenderSettings) -> T
    ) -> Binding<T> {
        Binding(
            get: {
                guard let clip = self.selectedClip else { return inherited(self.document.defaultLook) }
                if let look = clip.look, let value = read(look) { return value }
                return inherited(self.document.defaultLook)
            },
            set: { value in
                guard let id = self.selectedClipID else { return }
                self.adjust { document in
                    guard let ti = document.trackIndex(containingClip: id),
                          let ci = document.tracks[ti].clips.firstIndex(where: { $0.id == id }) else { return }
                    var look = document.tracks[ti].clips[ci].look ?? LookOverride()
                    write(&look, value)
                    document.tracks[ti].clips[ci].look = look
                }
            }
        )
    }

    // MARK: Sharing settings between clips

    /// A clip's adjustable settings, lifted off one clip so they can be dropped onto
    /// another. Deliberately excludes what makes a clip *itself* — its source, its place
    /// on the timeline, its trim, and its speed (all editorial choices per clip, not a
    /// "look" you'd want to stamp onto everything).
    struct ClipSettings: Sendable, Equatable {
        var look: LookOverride?
        var volume: Double
        var fadeIn: Double
        var fadeOut: Double
        var transform: ClipTransform
        var kenBurns: KenBurns?
    }

    /// The last copied clip settings — the editor's private clipboard.
    private(set) var copiedSettings: ClipSettings?
    var canPasteSettings: Bool { copiedSettings != nil && selectedClipID != nil }

    func copySelectedSettings() {
        guard let clip = selectedClip else { return }
        copiedSettings = ClipSettings(look: clip.look, volume: clip.volume,
                                      fadeIn: clip.fadeIn, fadeOut: clip.fadeOut,
                                      transform: clip.transform, kenBurns: clip.kenBurns)
    }

    func pasteSettingsToSelected() {
        guard let settings = copiedSettings, let id = selectedClipID else { return }
        edit("Paste clip settings") { document in
            guard let ti = document.trackIndex(containingClip: id),
                  let ci = document.tracks[ti].clips.firstIndex(where: { $0.id == id }) else { return }
            var clip = document.tracks[ti].clips[ci]
            clip.look = settings.look
            clip.volume = settings.volume
            clip.fadeIn = settings.fadeIn
            clip.fadeOut = settings.fadeOut
            clip.transform = settings.transform
            clip.kenBurns = settings.kenBurns
            document.tracks[ti].clips[ci] = clip
        }
    }

    /// Promotes the selected clip's look to the project default and clears every clip's
    /// override, so the whole video picks up that zoom / cursor / background treatment.
    func applySelectedLookToAllClips() {
        guard let clip = selectedClip else { return }
        let resolved = clip.look?.applied(to: document.defaultLook) ?? document.defaultLook
        edit("Apply look to all clips") { document in
            var look = resolved
            // The canvas belongs to the project, not to a clip.
            look.outputWidth = document.canvas.width
            look.outputHeight = document.canvas.height
            look.aspect = document.canvas.aspect
            document.defaultLook = look
            for ti in document.tracks.indices {
                for ci in document.tracks[ti].clips.indices {
                    document.tracks[ti].clips[ci].look = nil
                }
            }
        }
    }

    /// Clears every per-clip override so all clips follow the project look.
    func resetAllClipLooks() {
        edit("Reset all clip looks") { document in
            for ti in document.tracks.indices {
                for ci in document.tracks[ti].clips.indices {
                    document.tracks[ti].clips[ci].look = nil
                }
            }
        }
    }

    /// True when at least one clip is overriding the project look.
    var hasClipLookOverrides: Bool {
        document.tracks.contains { $0.clips.contains { $0.look != nil } }
    }

    /// Drops every override on the selected clip, so it inherits the project look again.
    func resetSelectedLook() {
        guard let id = selectedClipID else { return }
        edit("Reset clip look") { document in
            guard let ti = document.trackIndex(containingClip: id),
                  let ci = document.tracks[ti].clips.firstIndex(where: { $0.id == id }) else { return }
            document.tracks[ti].clips[ci].look = nil
        }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
        persistAndRebuild()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
        persistAndRebuild()
    }

    private func persistAndRebuild() {
        duration = document.duration
        lastWrittenDocument = document
        try? project.write(document)
        rebuild()
    }

    // MARK: Timeline operations

    func add(libraryClip: LibraryClip, at start: Double? = nil) {
        edit("Add clip") { document in
            guard let track = document.tracks.first(where: { $0.kind == .main }) else { return }
            document.add(libraryClip.makeTimelineClip(), toTrack: track.id, at: start)
        }
    }

    /// Imports a file (copying it into the project) and drops it on a suitable track.
    func importFile(_ url: URL, at start: Double? = nil) {
        do {
            let source = try project.importMedia(from: url)
            let length = mediaDuration(source)
            edit("Import") { document in
                let kind: TrackKind = source.kind == .audio ? .audio : .main
                guard let track = document.tracks.first(where: { $0.kind == kind }) ?? document.tracks.first else { return }
                var clip = TimelineClip(source: source, start: 0, sourceIn: 0, sourceOut: length,
                                        name: url.deletingPathExtension().lastPathComponent)
                if source.kind == .image { clip.kenBurns = KenBurns() }
                document.add(clip, toTrack: track.id, at: start)
            }
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func mediaDuration(_ source: MediaSource) -> Double {
        if source.kind == .image { return 4 }
        guard let url = project.url(for: source) else { return 4 }
        let seconds = CMTimeGetSeconds(AVURLAsset(url: url).duration)
        return seconds.isFinite && seconds > 0 ? seconds : 4
    }

    func splitAtPlayhead() {
        guard let clip = clipAtPlayhead() else { return }
        let at = currentTime
        edit("Split") { document in
            if let newID = document.split(clipID: clip.id, at: at) { self.selectedClipID = newID }
        }
    }

    /// The selected clip if it spans the playhead, otherwise whatever is under it.
    private func clipAtPlayhead() -> TimelineClip? {
        if let selected = selectedClip, selected.contains(currentTime) { return selected }
        for track in document.tracks {
            if let clip = track.clip(at: currentTime) { return clip }
        }
        return nil
    }

    func deleteSelected(ripple: Bool = false) {
        guard let id = selectedClipID else { return }
        edit("Delete") { document in
            if ripple { document.rippleDelete(clipID: id) } else { document.remove(clipID: id) }
        }
        selectedClipID = nil
    }

    func addTextCard() {
        let start = currentTime
        edit("Add title") { document in
            guard let track = document.tracks.first(where: { $0.kind == .overlay }) else { return }
            var clip = TimelineClip(source: .text, start: start, sourceIn: 0, sourceOut: 3, name: "Title")
            clip.text = TextOverlay(string: "Title", fontSize: 0.08, x: 0.5, y: 0.5, pill: true)
            clip.fadeIn = 0.3
            clip.fadeOut = 0.3
            document.add(clip, toTrack: track.id, at: start)
            self.selectedClipID = clip.id
        }
    }

    func updateSelected(_ body: (inout TimelineClip) -> Void) {
        guard let id = selectedClipID else { return }
        edit("Adjust clip") { document in
            guard let ti = document.trackIndex(containingClip: id),
                  let ci = document.tracks[ti].clips.firstIndex(where: { $0.id == id }) else { return }
            body(&document.tracks[ti].clips[ci])
        }
    }

    func toggleMute(trackID: UUID) {
        edit("Mute track") { document in
            guard let index = document.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            document.tracks[index].muted.toggle()
        }
    }

    func toggleHidden(trackID: UUID) {
        edit("Hide track") { document in
            guard let index = document.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            document.tracks[index].hidden.toggle()
        }
    }

    func setVolume(trackID: UUID, volume: Double) {
        edit("Track volume") { document in
            guard let index = document.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            document.tracks[index].volume = volume
        }
    }

    func setAspect(_ aspect: OutputAspect) {
        edit("Aspect") { document in
            let size = aspect.canvasSize(masterWidth: document.canvas.width, masterHeight: document.canvas.height)
            document.canvas = Canvas(width: size.width, height: size.height, aspect: aspect, fps: document.canvas.fps)
            document.defaultLook.outputWidth = size.width
            document.defaultLook.outputHeight = size.height
            document.defaultLook.aspect = aspect
        }
    }

    // MARK: Post-hoc voiceover & camera

    func toggleVoiceover() async {
        if voiceover.isRecording {
            let length = voiceover.stop()
            guard length > 0.2, let url = previewVoiceoverURL else { return }
            let start = voiceover.punchInTime
            edit("Voiceover") { document in
                guard let track = document.tracks.first(where: { $0.kind == .audio }) else { return }
                let source = MediaSource.file(path: url.lastPathComponent, kind: .audio)
                let clip = TimelineClip(source: source, start: start, sourceIn: 0, sourceOut: length, name: "Voiceover")
                document.add(clip, toTrack: track.id, at: start)
            }
            previewVoiceoverURL = nil
            player.pause()
            return
        }

        guard await VoiceoverRecorder.requestAccess() else {
            errorMessage = "Microphone access is required to record a voiceover."
            return
        }
        guard let url = try? project.newMediaURL(prefix: "voiceover", extension: "wav") else { return }
        previewVoiceoverURL = url
        // Play the timeline while recording, so the take lines up with the picture.
        if voiceover.start(to: url, punchInAt: currentTime) { player.play() }
    }

    private var previewVoiceoverURL: URL?

    func toggleCameraTake() {
        if isRecordingCamera {
            webcam.stop()
            isRecordingCamera = false
            player.pause()
            guard let url = cameraURL else { return }
            let start = cameraStartTime
            // The file finalizes asynchronously; wait for it before measuring its length.
            Task { @MainActor in
                for _ in 0..<40 {
                    try? await Task.sleep(for: .milliseconds(100))
                    let seconds = CMTimeGetSeconds(AVURLAsset(url: url).duration)
                    if seconds.isFinite, seconds > 0.2 {
                        edit("Camera take") { document in
                            guard let track = document.tracks.first(where: { $0.kind == .overlay }) else { return }
                            var clip = TimelineClip(source: .file(path: url.lastPathComponent, kind: .video),
                                                    start: start, sourceIn: 0, sourceOut: seconds, name: "Camera")
                            clip.transform = .bubbleBottomLeading
                            document.add(clip, toTrack: track.id, at: start)
                        }
                        return
                    }
                }
                errorMessage = "The camera take could not be read back."
            }
            return
        }

        guard let url = try? project.newMediaURL(prefix: "camera", extension: "mov") else { return }
        cameraURL = url
        cameraStartTime = currentTime
        if webcam.start(to: url) {
            isRecordingCamera = true
            player.play()
        } else {
            errorMessage = "No camera available (check Camera permission)."
        }
    }

    // MARK: Preview

    private func rebuild(immediately: Bool = false) {
        // Bump the generation *before* cancelling: a build already past its cancellation
        // checks must not be allowed to install its (now stale) player item. Dragging a
        // slider fires these continuously, so overlapping builds are the normal case,
        // not the exception.
        rebuildGeneration &+= 1
        let generation = rebuildGeneration
        let previous = rebuildTask
        previous?.cancel()

        rebuildTask = Task { [weak self] in
            // Let the superseded build finish unwinding before starting another, so two
            // builds never mutate their compositions concurrently.
            _ = await previous?.value
            if !immediately { try? await Task.sleep(for: .milliseconds(250)) }
            guard let self, !Task.isCancelled, generation == self.rebuildGeneration else { return }
            await self.rebuildNow(generation: generation)
        }
    }

    private func rebuildNow(generation: UInt64) async {
        guard document.duration > 0.01 else {
            built = nil
            player.replaceCurrentItem(with: nil)
            isReady = false
            buildError = nil
            return
        }

        do {
            let built = try await TimelineCompositionBuilder.build(project: project, document: document)
            guard !Task.isCancelled, generation == rebuildGeneration else { return }
            self.built = built
            buildError = nil

            // Mix the audio and attach it to the same composition, so the preview hears
            // exactly what the export will contain.
            if let oldURL = previewAudioURL { try? FileManager.default.removeItem(at: oldURL) }
            previewAudioURL = try? await TimelineAudioMixer.build(project: project, document: document)
            previewAudioAsset = nil
            if let audioURL = previewAudioURL {
                let asset = AVURLAsset(url: audioURL)
                previewAudioAsset = asset          // retain: a track outlives its asset badly
                if let source = try? await asset.loadTracks(withMediaType: .audio).first,
                   let compTrack = built.asset.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    let length = min(built.duration, (try? await asset.load(.duration)) ?? built.duration)
                    try? compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: .zero)
                }
            }

            // On the first build the player has no item yet, so `currentTime()` is not a
            // valid time — seeking to it would be undefined.
            let current = player.currentTime()
            let resume = (player.currentItem != nil && current.isValid && current.isNumeric) ? current : .zero
            let wasPlaying = player.rate != 0
            // One last check: the audio mix above is asynchronous, so a newer edit may
            // have superseded this build while it was running.
            guard generation == rebuildGeneration else { return }
            let item = AVPlayerItem(asset: built.asset)
            item.videoComposition = built.videoComposition
            player.replaceCurrentItem(with: item)
            // Always seek, even to zero: a paused player shows nothing until it is given
            // a time to display, so without this a freshly opened project sits black
            // until you press play.
            await player.seek(to: resume, toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
            isReady = true


        } catch {
            buildError = error.localizedDescription
            isReady = false
        }
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
        let clamped = max(0, min(seconds, max(duration, 0.01)))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }

    func zoomToFit(width: Double) {
        guard duration > 0.01, width > 40 else { return }
        userChoseZoom = true
        pixelsPerSecond = max(8, min((width - 20) / duration, 400))
    }

    /// Fits the timeline only while the user hasn't set a zoom themselves, so resizing
    /// the window never yanks the zoom out from under them.
    func zoomToFitIfUntouched(width: Double) {
        guard !userChoseZoom, duration > 0.01, width > 40 else { return }
        let fitted = max(8, min((width - 20) / duration, 400))
        // Only write when it actually changes: a redundant write to observable state
        // would invalidate the view and could loop against the layout that triggered it.
        guard abs(fitted - pixelsPerSecond) > 0.5 else { return }
        isAutoFitting = true
        pixelsPerSecond = fitted
        isAutoFitting = false
    }

    // MARK: Export

    func export(format: ExportFormat, preset: ExportPreset, to outputURL: URL) async {
        guard !isExporting, document.duration > 0.01 else { return }
        errorMessage = nil
        isExporting = true
        exportProgress = 0

        do {
            let onProgress: @Sendable (Double) -> Void = { [weak self] p in
                Task { @MainActor in self?.exportProgress = p }
            }
            if format.isGIF {
                try await VideoExporter.exportTimelineGIF(project: project, document: document,
                                                          frameRate: format.gifFrameRate, to: outputURL, progress: onProgress)
            } else {
                let size = preset.outputSize(canvasWidth: document.canvas.width, canvasHeight: document.canvas.height)
                try await VideoExporter.exportTimeline(project: project, document: document,
                                                       size: (size.width, size.height), format: format,
                                                       to: outputURL, progress: onProgress)
            }
            lastExportURL = outputURL
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        } catch {
            errorMessage = error.localizedDescription
        }
        isExporting = false
    }

    /// Suggested file name for the save panel.
    var suggestedExportName: String { project.name }

    // MARK: External edits (the MCP server writing the same document)

    private func watchDocument() {
        let descriptor = open(project.documentURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.reloadIfChangedOnDisk() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        documentWatcher = source
    }

    /// Picks up edits made outside the app (the MCP server), without stomping our own
    /// in-flight changes — the on-disk copy only wins when it actually differs.
    private func reloadIfChangedOnDisk() {
        guard !isApplyingExternalChange,
              let onDisk = try? project.read(),
              onDisk != document,
              onDisk != lastWrittenDocument else { return }
        isApplyingExternalChange = true
        undoStack.append(document)
        document = onDisk
        duration = onDisk.duration
        rebuild()
        isApplyingExternalChange = false
    }
}
