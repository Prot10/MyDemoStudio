import SwiftUI
import AppKit

/// The inspector for the multi-clip editor. It's contextual: with nothing selected it
/// edits the project defaults, and with a clip selected it edits that clip — including
/// look overrides that fall back to the project value until you actually change them.
struct ClipInspectorView: View {
    @Bindable var model: TimelineEditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if let clip = model.selectedClip {
                    clipSections(clip)
                } else {
                    projectSections
                }

                exportSection
            }
            .padding(20)
        }
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedClip == nil ? "Project" : "Clip")
                    .font(.title2.weight(.semibold))
                Text(model.selectedClip == nil
                     ? model.project.name
                     : (model.selectedClip?.name.isEmpty == false ? model.selectedClip!.name : "Untitled clip"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if model.selectedClipID != nil {
                Button { model.selectedClipID = nil } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.glass)
                .help("Edit project settings instead")
            }
        }
    }

    // MARK: Clip

    @ViewBuilder private func clipSections(_ clip: TimelineClip) -> some View {
        InspectorSection("Timing") {
            readout("Starts at", timecode(clip.start))
            readout("Length", String(format: "%.2fs", clip.duration))
            readout("Source window", String(format: "%.2f–%.2fs", clip.sourceIn, clip.sourceOut))
            slider("Speed", model.clipBinding(\.speed, fallback: 1), in: 0.25...4, unit: "×")
            HStack(spacing: 6) {
                ForEach([0.5, 1.0, 2.0], id: \.self) { speed in
                    Button("\(String(format: "%.2g", speed))×") {
                        model.edit("Speed") { $0.setSpeed(clipID: clip.id, speed: speed) }
                    }
                    .buttonStyle(.glass).controlSize(.small)
                }
            }
        }

        InspectorSection("Fades") {
            slider("Fade in", model.clipBinding(\.fadeIn, fallback: 0), in: 0...3, unit: "s")
            slider("Fade out", model.clipBinding(\.fadeOut, fallback: 0), in: 0...3, unit: "s")
        }

        if clip.source.carriesAudio {
            InspectorSection("Audio") {
                slider("Volume", model.clipBinding(\.volume, fallback: 1), in: 0...1.5, percent: true)
            }
        }

        if let text = clip.text {
            InspectorSection("Text") {
                let binding = model.clipBinding(\.text, fallback: text).unwrapped
                TextField("Text", text: binding.string, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                slider("Size", binding.fontSize, in: 0.02...0.25, percent: true)
                slider("Position X", binding.x, in: 0...1, percent: true)
                slider("Position Y", binding.y, in: 0...1, percent: true)
                Toggle("Background pill", isOn: binding.pill)
            }
        }

        if clip.source.kind == .image {
            InspectorSection("Ken Burns") {
                Toggle("Slow zoom", isOn: Binding(
                    get: { clip.kenBurns != nil },
                    set: { on in model.updateSelected { $0.kenBurns = on ? KenBurns() : nil } }
                ))
                if let ken = clip.kenBurns {
                    slider("Start zoom", model.clipBinding(\.kenBurns, fallback: ken).unwrapped.startScale, in: 1...2.5, unit: "×")
                    slider("End zoom", model.clipBinding(\.kenBurns, fallback: ken).unwrapped.endScale, in: 1...2.5, unit: "×")
                }
            }
        }

        // Overlay placement only matters for clips drawn on top of the picture.
        if model.document.trackIndex(containingClip: clip.id).map({ model.document.tracks[$0].kind }) == .overlay,
           clip.text == nil {
            InspectorSection("Overlay placement") {
                Toggle("Circular (webcam bubble)", isOn: model.clipBinding(\.transform, fallback: clip.transform).circular)
                slider("Size", model.clipBinding(\.transform, fallback: clip.transform).scale, in: 0.05...0.6, percent: true)
                slider("Position X", model.clipBinding(\.transform, fallback: clip.transform).centerX, in: 0...1, percent: true)
                slider("Position Y", model.clipBinding(\.transform, fallback: clip.transform).centerY, in: 0...1, percent: true)
                slider("Opacity", model.clipBinding(\.transform, fallback: clip.transform).opacity, in: 0...1, percent: true)
            }
        }

        if case .recording = clip.source {
            InspectorSection("Look (this clip)") {
                Text("Overrides the project look for this clip only.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Auto-zoom", isOn: model.clipLookBinding(
                    read: { $0.zoomEnabled }, write: { $0.zoomEnabled = $1 }, inherited: { $0.zoomEnabled }))
                slider("Zoom amount", model.clipLookBinding(
                    read: { $0.zoomScale }, write: { $0.zoomScale = $1 }, inherited: { $0.zoomScale }),
                       in: 1...3, unit: "×")
                slider("Padding", model.clipLookBinding(
                    read: { $0.paddingFraction }, write: { $0.paddingFraction = $1 }, inherited: { $0.paddingFraction }),
                       in: 0...0.15, percent: true)
                Toggle("Click & typing sounds", isOn: model.clipLookBinding(
                    read: { $0.sfxEnabled }, write: { $0.sfxEnabled = $1 }, inherited: { $0.sfxEnabled }))
                Picker("Cursor", selection: model.clipLookBinding(
                    read: { $0.cursorStyle }, write: { $0.cursorStyle = $1 }, inherited: { $0.cursorStyle })) {
                    ForEach(CursorStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Button("Reset to project look") { model.resetSelectedLook() }
                    .buttonStyle(.glass).controlSize(.small)
                    .disabled(clip.look == nil)
            }
        }

        InspectorSection("Reuse these settings") {
            Text("Copy this clip's look, speed, volume, fades and placement onto another clip — or push its look onto every clip at once.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button { model.copySelectedSettings() } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button { model.pasteSettingsToSelected() } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(!model.canPasteSettings)
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }

            Button { model.applySelectedLookToAllClips() } label: {
                Label("Apply this look to all clips", systemImage: "square.stack.3d.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        }
    }

    // MARK: Project

    @ViewBuilder private var projectSections: some View {
        InspectorSection("Aspect ratio") {
            Picker("Aspect", selection: Binding(
                get: { model.document.canvas.aspect },
                set: { model.setAspect($0) }
            )) {
                ForEach(OutputAspect.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            readout("Canvas", "\(model.document.canvas.width)×\(model.document.canvas.height) @ \(model.document.canvas.fps)fps")
        }

        InspectorSection("Background") {
            Picker("Style", selection: model.lookBinding(\.background.kind)) {
                Text("Wallpaper").tag(BackgroundStyle.Kind.wallpaper)
                Text("Gradient").tag(BackgroundStyle.Kind.gradient)
                Text("Solid").tag(BackgroundStyle.Kind.solid)
            }
            .pickerStyle(.segmented)

            switch model.document.defaultLook.background.kind {
            case .wallpaper:
                wallpaperSwatches
                slider("Background blur", model.lookBinding(\.background.blur), in: 0...1, percent: true)
            case .gradient:
                ColorPicker("Primary", selection: colorBinding(\.background.color1))
                ColorPicker("Secondary", selection: colorBinding(\.background.color2))
                slider("Angle", model.lookBinding(\.background.angleDegrees), in: 0...360, unit: "°")
            case .solid:
                ColorPicker("Color", selection: colorBinding(\.background.color1))
            }
        }

        InspectorSection("Layout") {
            slider("Padding", model.lookBinding(\.paddingFraction), in: 0...0.15, percent: true)
            slider("Corner radius", model.lookBinding(\.cornerRadiusFraction), in: 0...0.05, percent: true)
            slider("Shadow size", model.lookBinding(\.shadowRadiusFraction), in: 0...0.06, percent: true)
            slider("Shadow strength", model.lookBinding(\.shadowOpacity), in: 0...1, percent: true)
        }

        InspectorSection("Auto-zoom") {
            Toggle("Zoom into clicks", isOn: model.lookBinding(\.zoomEnabled))
            if model.document.defaultLook.zoomEnabled {
                slider("Zoom amount", model.lookBinding(\.zoomScale), in: 1...3, unit: "×")
            }
        }

        InspectorSection("Cursor") {
            Picker("Style", selection: model.lookBinding(\.cursorStyle)) {
                ForEach(CursorStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            slider("Size", model.lookBinding(\.cursorScale), in: 0.5...5, unit: "×")
            slider("Smoothing", model.lookBinding(\.cursorSmoothing), in: 0...1, percent: true)
        }

        InspectorSection("Audio & captions") {
            Toggle("Click & typing sounds", isOn: model.lookBinding(\.sfxEnabled))
            if model.document.defaultLook.sfxEnabled {
                slider("SFX volume", model.lookBinding(\.sfxVolume), in: 0...1, percent: true)
            }
            Toggle("Show captions", isOn: model.lookBinding(\.captionsEnabled))
        }

        if model.hasClipLookOverrides {
            InspectorSection("Per-clip overrides") {
                Text("Some clips override these settings with their own.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.resetAllClipLooks() } label: {
                    Label("Make every clip follow the project", systemImage: "arrow.triangle.merge")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
        }
    }

    private var wallpaperSwatches: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(0..<BackgroundStyle.wallpaperCount, id: \.self) { index in
                Button {
                    model.adjust { $0.defaultLook.background.wallpaperIndex = index }
                } label: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: wallpaperPreviewColors(index),
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(height: 38)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(model.document.defaultLook.background.wallpaperIndex == index
                                        ? Color.white : Color.white.opacity(0.15),
                                        lineWidth: model.document.defaultLook.background.wallpaperIndex == index ? 2 : 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // Mirrors the shader's wallpaper palettes for the swatch previews.
    private func wallpaperPreviewColors(_ index: Int) -> [Color] {
        switch index {
        case 1: return [Color(red: 0.98, green: 0.45, blue: 0.42), Color(red: 0.96, green: 0.76, blue: 0.36)]
        case 2: return [Color(red: 0.11, green: 0.37, blue: 0.33), Color(red: 0.30, green: 0.62, blue: 0.40)]
        case 3: return [Color(red: 0.10, green: 0.12, blue: 0.28), Color(red: 0.44, green: 0.22, blue: 0.66)]
        case 4: return [Color(red: 0.98, green: 0.58, blue: 0.30), Color(red: 0.85, green: 0.28, blue: 0.62)]
        case 5: return [Color(red: 0.16, green: 0.18, blue: 0.22), Color(red: 0.30, green: 0.33, blue: 0.38)]
        default: return [Color(red: 0.42, green: 0.30, blue: 0.86), Color(red: 0.28, green: 0.48, blue: 0.96)]
        }
    }

    // MARK: Export

    private var exportSection: some View {
        ExportControls(
            isExporting: model.isExporting,
            progress: model.exportProgress,
            canExport: model.document.duration > 0.01,
            suggestedName: model.suggestedExportName,
            errorMessage: model.errorMessage
        ) { format, preset, url in
            Task { await model.export(format: format, preset: preset, to: url) }
        }
    }

    // MARK: Small helpers

    private func colorBinding(_ keyPath: WritableKeyPath<RenderSettings, RGBAColor>) -> Binding<Color> {
        Binding(
            get: { Color(model.document.defaultLook[keyPath: keyPath]) },
            set: { newValue in
                let ns = NSColor(newValue).usingColorSpace(.sRGB) ?? .white
                model.adjust {
                    $0.defaultLook[keyPath: keyPath] = RGBAColor(
                        Double(ns.redComponent), Double(ns.greenComponent),
                        Double(ns.blueComponent), Double(ns.alphaComponent))
                }
            }
        )
    }

    private func readout(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, in range: ClosedRange<Double>,
                        unit: String = "", percent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(percent ? "\(Int(value.wrappedValue * 100))%"
                     : String(format: "%.2f%@", value.wrappedValue, unit))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func timecode(_ t: Double) -> String {
        String(format: "%02d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
}

/// A titled block of controls.
struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

extension Binding where Value == KenBurns? {
    /// Lets the Ken Burns controls bind through the clip's optional field.
    var unwrapped: Binding<KenBurns> {
        Binding<KenBurns>(
            get: { wrappedValue ?? KenBurns() },
            set: { wrappedValue = $0 }
        )
    }
}

extension Binding where Value == TextOverlay? {
    var unwrapped: Binding<TextOverlay> {
        Binding<TextOverlay>(
            get: { wrappedValue ?? TextOverlay(string: "") },
            set: { wrappedValue = $0 }
        )
    }
}
