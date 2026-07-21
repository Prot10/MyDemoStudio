import SwiftUI
import AVFoundation
import AppKit

/// The editing surface: live preview + transport + zoom timeline on the left, the
/// look inspector on the right. Edits update the preview (same compositor as export).
struct EditorView: View {
    @Bindable var model: ProjectEditorModel

    /// Shares its visibility with the multi-clip editor, so the panel behaves like one
    /// app-wide inspector rather than a per-screen one.
    @AppStorage("inspectorVisible") private var showInspector = true

    var body: some View {
        previewColumn
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .inspector(isPresented: $showInspector) {
                InspectorView(model: model)
                    .inspectorColumnWidth(min: 240, ideal: 320, max: 460)
            }
            .onChange(of: model.settings) { _, _ in model.settingsChanged() }
    }

    private var previewColumn: some View {
        VStack(spacing: 16) {
            ZStack {
                if model.isReady {
                    PreviewPlayerView(player: model.player)
                        .aspectRatio(previewAspect, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 10))
                } else {
                    ProgressView("Loading preview…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)

            ScrollView(.horizontal, showsIndicators: false) {
                TransportBar(model: model, showInspector: $showInspector)
            }
            .fixedSize(horizontal: false, vertical: true)
            ZoomTimeline(model: model)
                .frame(height: 46)
        }
        .padding(20)
        .background(previewBackdrop)
    }

    private var previewAspect: CGFloat {
        guard model.settings.outputHeight > 0 else { return 16.0 / 9.0 }
        return CGFloat(model.settings.outputWidth) / CGFloat(model.settings.outputHeight)
    }

    private var previewBackdrop: some View {
        LinearGradient(
            colors: [Color(white: 0.10), Color(white: 0.06)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

// MARK: - Transport

private struct TransportBar: View {
    @Bindable var model: ProjectEditorModel
    @Binding var showInspector: Bool

    var body: some View {
        HStack(spacing: 16) {
            Button {
                model.togglePlay()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 30)
            }
            .buttonStyle(.glass)
            .controlSize(.large)

            Text(timecode(model.currentTime))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { model.currentTime },
                    set: { model.seek(to: $0) }
                ),
                in: 0...max(model.duration, 0.1)
            )

            Text(timecode(model.duration))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)

            Button { showInspector.toggle() } label: {
                Image(systemName: "sidebar.trailing")
            }
            .buttonStyle(.glass)
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help(showInspector ? "Hide inspector" : "Show inspector")
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }

    private func timecode(_ t: Double) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Zoom timeline

private struct ZoomTimeline: View {
    @Bindable var model: ProjectEditorModel

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let dur = max(model.duration, 0.1)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(0.06))

                // Zoom-active regions.
                ForEach(Array(model.zoomIntervals.enumerated()), id: \.offset) { _, interval in
                    let x = CGFloat(interval.lowerBound / dur) * w
                    let width = CGFloat((interval.upperBound - interval.lowerBound) / dur) * w
                    RoundedRectangle(cornerRadius: 6)
                        .fill(LinearGradient(colors: [.indigo, .purple], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(width, 3))
                        .offset(x: x)
                        .overlay(alignment: .leading) {
                            Image(systemName: "plus.magnifyingglass")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(.leading, 5)
                                .offset(x: x)
                                .opacity(width > 26 ? 1 : 0)
                        }
                }

                // Playhead.
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .offset(x: CGFloat(model.currentTime / dur) * w - 1)
                    .shadow(radius: 2)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    model.seek(to: Double(value.location.x / w) * dur)
                }
            )
        }
        .overlay(alignment: .topLeading) {
            Text("Auto-zoom")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(4)
        }
    }
}
