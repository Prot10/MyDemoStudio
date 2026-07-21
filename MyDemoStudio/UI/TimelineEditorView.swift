import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// The multi-clip editing surface: live preview on top, a multi-lane timeline below,
/// and a contextual inspector on the right.
struct TimelineEditorView: View {
    @Bindable var model: TimelineEditorModel
    let clips: [LibraryClip]

    /// The trailing inspector, collapsible just like the sidebar on the left.
    @AppStorage("inspectorVisible") private var showInspector = true

    var body: some View {
        VStack(spacing: 12) {
            preview
            // Scrollable so the row of controls never imposes a large minimum width on
            // the content column. Without this, expanding the inspector can squeeze the
            // column below what these controls demand, which AppKit reports as an
            // unsatisfiable layout while the divider is being dragged.
            ScrollView(.horizontal, showsIndicators: false) {
                TransportBar(model: model, clips: clips)
            }
            .fixedSize(horizontal: false, vertical: true)
            TimelineLanes(model: model)
                .frame(minHeight: 190, maxHeight: 260)
        }
        .padding(16)
        .background(backdrop)
        .overlay(alignment: .topTrailing) {
            EditorFloatingActions(
                showInspector: $showInspector,
                isExporting: model.isExporting,
                progress: model.exportProgress,
                canExport: model.document.duration > 0.01,
                suggestedName: model.suggestedExportName,
                errorMessage: model.errorMessage
            ) { format, preset, url in
                Task { await model.export(format: format, preset: preset, to: url) }
            }
        }
        .inspector(isPresented: $showInspector) {
            ClipInspectorView(model: model)
                .inspectorColumnWidth(min: 240, ideal: 330, max: 460)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.importFile(url) }
                }
            }
            return true
        }
    }

    @ViewBuilder private var preview: some View {
        ZStack {
            if model.isReady {
                PreviewPlayerView(player: model.player)
                    .aspectRatio(canvasAspect, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 10))
            } else if let error = model.buildError {
                ContentUnavailableView {
                    Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else if model.document.duration < 0.01 {
                ContentUnavailableView {
                    Label("Empty project", systemImage: "film.stack")
                } description: {
                    Text("Add a recording from the sidebar, or drop a video, image or sound here.")
                }
            } else {
                ProgressView("Building preview…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 34)
    }

    private var canvasAspect: CGFloat {
        guard model.document.canvas.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(model.document.canvas.width) / CGFloat(model.document.canvas.height)
    }

    private var backdrop: some View {
        LinearGradient(colors: [Color(white: 0.10), Color(white: 0.06)],
                       startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }
}

// MARK: - Transport

private struct TransportBar: View {
    @Bindable var model: TimelineEditorModel
    let clips: [LibraryClip]
    @State private var showClipPicker = false

    var body: some View {
        HStack(spacing: 12) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3).frame(width: 26)
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.space, modifiers: [])

            Text("\(timecode(model.currentTime)) / \(timecode(model.duration))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)

            Divider().frame(height: 18)

            Button { showClipPicker = true } label: {
                Label("Add clip", systemImage: "plus")
            }
            .buttonStyle(.glass)
            .popover(isPresented: $showClipPicker) { clipPicker }

            Button { model.addTextCard() } label: {
                Label("Title", systemImage: "textformat")
            }
            .buttonStyle(.glass)

            Button { model.splitAtPlayhead() } label: {
                Label("Split", systemImage: "scissors")
            }
            .buttonStyle(.glass)
            .keyboardShortcut("b", modifiers: .command)

            Button(role: .destructive) { model.deleteSelected(ripple: true) } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.glass)
            .disabled(model.selectedClipID == nil)

            Divider().frame(height: 18)

            Button { Task { await model.toggleVoiceover() } } label: {
                Label(model.voiceover.isRecording ? "Stop (\(Int(model.voiceover.elapsed))s)" : "Voiceover",
                      systemImage: model.voiceover.isRecording ? "stop.circle.fill" : "mic")
            }
            .buttonStyle(.glass)
            .tint(model.voiceover.isRecording ? .red : nil)

            Button { model.toggleCameraTake() } label: {
                Label(model.isRecordingCamera ? "Stop camera" : "Camera",
                      systemImage: model.isRecordingCamera ? "stop.circle.fill" : "web.camera")
            }
            .buttonStyle(.glass)
            .tint(model.isRecordingCamera ? .red : nil)

            Spacer()

            if model.voiceover.isRecording {
                LevelMeter(level: model.voiceover.level)
            }

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.glass).disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: .command)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.glass).disabled(!model.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])

            Slider(value: $model.pixelsPerSecond, in: 8...300) { Text("Zoom") }
                .labelsHidden()
                .frame(width: 90)
                .help("Timeline zoom")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }

    private var clipPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recordings").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 4)
            if clips.isEmpty {
                Text("No recordings yet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(clips) { clip in
                Button {
                    model.add(libraryClip: clip)
                    showClipPicker = false
                } label: {
                    HStack {
                        Image(systemName: "film")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(clip.name).lineLimit(1)
                            Text("\(timecode(clip.duration)) · \(clip.pixelWidth)×\(clip.pixelHeight)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(.rect)
                    .padding(.vertical, 3).padding(.horizontal, 5)
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.vertical, 5)
            Button {
                showClipPicker = false
                importFromDisk()
            } label: {
                Label("Import video, image or sound…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 330)
    }

    private func importFromDisk() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .video, .image, .audio]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { model.importFile(url) }
    }

    private func timecode(_ t: Double) -> String {
        let total = Int(t.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct LevelMeter: View {
    let level: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.white.opacity(0.12))
            .frame(width: 70, height: 6)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(level > 0.9 ? Color.orange : Color.green)
                    .frame(width: 70 * level)
            }
    }
}

// MARK: - Timeline lanes

private struct TimelineLanes: View {
    @Bindable var model: TimelineEditorModel

    private let laneHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            // Never let the fixed header column outgrow the space actually available.
            let headerWidth = min(132, max(geo.size.width * 0.35, 40))
            HStack(spacing: 0) {
                // Track headers stay put while the lanes scroll.
                VStack(alignment: .leading, spacing: 6) {
                    Color.clear.frame(height: 18)          // aligns with the ruler
                    ForEach(model.document.tracks) { track in
                        TrackHeader(model: model, track: track)
                            .frame(height: laneHeight)
                    }
                }
                .frame(width: headerWidth)

                ScrollView([.horizontal]) {
                    VStack(alignment: .leading, spacing: 6) {
                        TimeRuler(duration: model.duration, pixelsPerSecond: model.pixelsPerSecond)
                            .frame(height: 18)
                        ForEach(model.document.tracks) { track in
                            LaneView(model: model, track: track, laneHeight: laneHeight)
                                .frame(height: laneHeight)
                        }
                    }
                    .padding(.trailing, 40)
                    .frame(minWidth: max(contentWidth, geo.size.width - headerWidth), alignment: .leading)
                    .overlay(alignment: .topLeading) { playhead }
                    .contentShape(.rect)
                    .gesture(
                        DragGesture(minimumDistance: 0).onChanged { value in
                            model.seek(to: value.location.x / model.pixelsPerSecond)
                        }
                    )
                }
            }
            // Fit the timeline asynchronously rather than from `onAppear`: mutating
            // observable state *during* a layout pass is what makes AppKit fall over
            // while a split-view divider is being dragged. `.task` runs after layout,
            // and re-runs when the available width actually changes.
            // Fit the timeline asynchronously rather than from `onAppear`: mutating
            // observable state *during* a layout pass is what makes AppKit fall over
            // while a split-view divider is being dragged. `.task` runs after layout,
            // and re-runs when the available width actually changes.
            .task(id: geo.size.width) {
                model.zoomToFitIfUntouched(width: geo.size.width - headerWidth)
            }
        }
        .padding(10)
        .background(.black.opacity(0.25), in: .rect(cornerRadius: 12))
    }

    private var contentWidth: CGFloat { CGFloat(model.duration * model.pixelsPerSecond) }

    private var playhead: some View {
        Rectangle()
            .fill(.white)
            .frame(width: 2)
            .shadow(radius: 2)
            .offset(x: CGFloat(model.currentTime * model.pixelsPerSecond) - 1)
            .allowsHitTesting(false)
    }
}

private struct TrackHeader: View {
    @Bindable var model: TimelineEditorModel
    let track: Track

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name).font(.caption.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Button { model.toggleMute(trackID: track.id) } label: {
                        Image(systemName: track.muted ? "speaker.slash.fill" : "speaker.wave.2")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(track.muted ? Color.orange : .secondary)
                    .help(track.muted ? "Unmute" : "Mute")

                    if track.kind != .audio {
                        Button { model.toggleHidden(trackID: track.id) } label: {
                            Image(systemName: track.hidden ? "eye.slash.fill" : "eye")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(track.hidden ? Color.orange : .secondary)
                        .help(track.hidden ? "Show" : "Hide")
                    }

                    Slider(value: Binding(
                        get: { track.volume },
                        set: { model.setVolume(trackID: track.id, volume: $0) }
                    ), in: 0...1.5)
                    .controlSize(.mini)
                    .frame(width: 46)
                    .help("Track volume")
                }
                .font(.caption2)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var icon: String {
        switch track.kind {
        case .main: return "film"
        case .overlay: return "rectangle.on.rectangle"
        case .audio: return "waveform"
        }
    }
}

private struct TimeRuler: View {
    let duration: Double
    let pixelsPerSecond: Double

    var body: some View {
        // Pick a tick spacing that stays readable at any zoom level.
        let step = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300].first { $0 * pixelsPerSecond >= 56 } ?? 600
        let count = Int(duration / step) + 1
        ZStack(alignment: .topLeading) {
            ForEach(0..<max(count, 1), id: \.self) { index in
                let t = Double(index) * step
                Text(label(t))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .offset(x: CGFloat(t * pixelsPerSecond) + 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func label(_ t: Double) -> String {
        let total = Int(t)
        return t < 60 ? String(format: "%.0fs", t) : String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct LaneView: View {
    @Bindable var model: TimelineEditorModel
    let track: Track
    let laneHeight: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(track.hidden ? 0.02 : 0.05))
                .frame(width: max(CGFloat(model.duration * model.pixelsPerSecond), 40))

            ForEach(track.clips) { clip in
                ClipBlock(model: model, track: track, clip: clip, laneHeight: laneHeight)
            }
        }
        .opacity(track.hidden ? 0.45 : 1)
    }
}

/// One clip on a lane: drag the body to move it, drag either edge to trim.
private struct ClipBlock: View {
    @Bindable var model: TimelineEditorModel
    let track: Track
    let clip: TimelineClip
    let laneHeight: CGFloat

    @State private var dragOffset: CGFloat = 0
    @State private var trimLeading: CGFloat = 0
    @State private var trimTrailing: CGFloat = 0

    private var pps: Double { model.pixelsPerSecond }
    private var isSelected: Bool { model.selectedClipID == clip.id }
    private var width: CGFloat { max(CGFloat(clip.duration * pps) - trimLeading + trimTrailing, 10) }
    private var offsetX: CGFloat { CGFloat(clip.start * pps) + dragOffset + trimLeading }

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.white : Color.white.opacity(0.18),
                            lineWidth: isSelected ? 2 : 1)
            )
            .overlay(alignment: .leading) { label }
            .overlay(alignment: .leading) { trimHandle(leading: true) }
            .overlay(alignment: .trailing) { trimHandle(leading: false) }
            .frame(width: width, height: laneHeight - 6)
            .offset(x: offsetX, y: 3)
            .onTapGesture { model.selectedClipID = clip.id }
            .gesture(moveGesture)
            .contextMenu { menu }
            .help("\(clip.name.isEmpty ? "Clip" : clip.name) — \(String(format: "%.2fs", clip.duration))"
                  + (clip.speed != 1 ? " at \(String(format: "%.2f", clip.speed))×" : ""))
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(clip.name.isEmpty ? defaultName : clip.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            if clip.speed != 1 {
                Text("\(String(format: "%.2g", clip.speed))×")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(.black.opacity(0.35), in: .rect(cornerRadius: 3))
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 8)
        .allowsHitTesting(false)
    }

    private var defaultName: String {
        switch clip.source {
        case .text: return clip.text?.string ?? "Title"
        case .recording: return "Recording"
        case .file(let path, _): return path
        }
    }

    private var icon: String {
        switch clip.source {
        case .text: return "textformat"
        case .recording: return "film"
        case .file(_, let kind):
            switch kind {
            case .video: return "video"
            case .image: return "photo"
            case .audio: return "waveform"
            }
        }
    }

    private var fill: LinearGradient {
        let colors: [Color]
        switch clip.source {
        case .recording: colors = [.indigo, .purple]
        case .text: colors = [.teal, .cyan]
        case .file(_, let kind):
            switch kind {
            case .video: colors = [.blue, .indigo]
            case .image: colors = [.orange, .pink]
            case .audio: colors = [.green, .mint]
            }
        }
        return LinearGradient(colors: colors.map { $0.opacity(0.85) },
                              startPoint: .leading, endPoint: .trailing)
    }

    /// Drag the body to reposition; the document only changes on release, so dragging
    /// never triggers a composition rebuild mid-gesture.
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                model.selectedClipID = clip.id
                dragOffset = value.translation.width
            }
            .onEnded { value in
                let newStart = max(0, clip.start + Double(value.translation.width) / pps)
                dragOffset = 0
                model.edit("Move clip") { document in
                    document.move(clipID: clip.id, to: snap(newStart), trackID: nil)
                }
            }
    }

    private func trimHandle(leading: Bool) -> some View {
        Rectangle()
            .fill(.white.opacity(0.001))
            .frame(width: 10)
            .contentShape(.rect)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        model.selectedClipID = clip.id
                        if leading { trimLeading = value.translation.width }
                        else { trimTrailing = value.translation.width }
                    }
                    .onEnded { value in
                        let deltaSeconds = Double(value.translation.width) / pps * clip.speed
                        trimLeading = 0
                        trimTrailing = 0
                        model.edit("Trim clip") { document in
                            if leading {
                                // Trimming the head also moves the clip, so the rest of
                                // the picture stays where it is on the timeline.
                                let newIn = min(max(0, clip.sourceIn + deltaSeconds), clip.sourceOut - 0.05)
                                document.trim(clipID: clip.id, sourceIn: newIn, sourceOut: nil)
                                let moved = clip.start + (newIn - clip.sourceIn) / clip.speed
                                document.move(clipID: clip.id, to: max(0, moved), trackID: nil)
                            } else {
                                document.trim(clipID: clip.id, sourceIn: nil,
                                              sourceOut: max(clip.sourceIn + 0.05, clip.sourceOut + deltaSeconds))
                            }
                        }
                    }
            )
    }

    /// Snaps to whole/half seconds when the timeline is zoomed out enough that a pixel
    /// covers more than a few milliseconds.
    private func snap(_ seconds: Double) -> Double {
        let grain = pps > 120 ? 0.1 : (pps > 40 ? 0.25 : 0.5)
        return (seconds / grain).rounded() * grain
    }

    @ViewBuilder private var menu: some View {
        Button("Split at playhead") { model.selectedClipID = clip.id; model.splitAtPlayhead() }
        Menu("Speed") {
            ForEach([0.25, 0.5, 1.0, 1.5, 2.0, 4.0], id: \.self) { speed in
                Button("\(String(format: "%.2g", speed))×") {
                    model.edit("Speed") { $0.setSpeed(clipID: clip.id, speed: speed) }
                }
            }
        }
        Divider()
        Button("Close gaps on this track") {
            model.edit("Compact") { $0.compact(trackID: track.id) }
        }
        Divider()
        Button("Delete", role: .destructive) {
            model.selectedClipID = clip.id
            model.deleteSelected()
        }
        Button("Delete and close gap", role: .destructive) {
            model.selectedClipID = clip.id
            model.deleteSelected(ripple: true)
        }
    }
}
