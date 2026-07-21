import SwiftUI
import AppKit

/// The look inspector: background, layout, zoom, and cursor controls, plus export.
/// Every change flows into `model.settings`, whose `onChange` rebuilds the preview.
struct InspectorView: View {
    @Bindable var model: ProjectEditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                Section("Aspect ratio") {
                    Picker("Aspect", selection: Binding(
                        get: { model.settings.aspect },
                        set: { model.setAspect($0) }
                    )) {
                        ForEach(OutputAspect.allCases) { aspect in
                            Text(aspect.label).tag(aspect)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section("Background") {
                    Picker("Style", selection: $model.settings.background.kind) {
                        Text("Wallpaper").tag(BackgroundStyle.Kind.wallpaper)
                        Text("Gradient").tag(BackgroundStyle.Kind.gradient)
                        Text("Solid").tag(BackgroundStyle.Kind.solid)
                    }
                    .pickerStyle(.segmented)

                    switch model.settings.background.kind {
                    case .wallpaper:
                        wallpaperSwatches
                        labeledSlider("Background blur", value: $model.settings.background.blur, in: 0...1, percent: true)
                    case .gradient:
                        ColorPicker("Primary", selection: colorBinding(\.background.color1))
                        ColorPicker("Secondary", selection: colorBinding(\.background.color2))
                        labeledSlider("Angle", value: $model.settings.background.angleDegrees, in: 0...360, unit: "°")
                        presetSwatches
                    case .solid:
                        ColorPicker("Color", selection: colorBinding(\.background.color1))
                    }
                }

                Section("Layout") {
                    labeledSlider("Padding", value: $model.settings.paddingFraction, in: 0...0.15, percent: true)
                    labeledSlider("Corner radius", value: $model.settings.cornerRadiusFraction, in: 0...0.05, percent: true)
                    labeledSlider("Shadow size", value: $model.settings.shadowRadiusFraction, in: 0...0.06, percent: true)
                    labeledSlider("Shadow strength", value: $model.settings.shadowOpacity, in: 0...1, percent: true)
                }

                Section("Auto-zoom") {
                    Toggle("Zoom into clicks", isOn: $model.settings.zoomEnabled)
                    if model.settings.zoomEnabled {
                        labeledSlider("Zoom amount", value: $model.settings.zoomScale, in: 1.0...3.0, unit: "×")
                        Toggle("Motion blur", isOn: $model.settings.motionBlur)
                    }
                }

                Section("Audio") {
                    labeledSlider("Voiceover", value: $model.settings.voiceoverVolume, in: 0...1.5, percent: true)
                    Toggle("Click & typing sounds", isOn: $model.settings.sfxEnabled)
                    if model.settings.sfxEnabled {
                        labeledSlider("SFX volume", value: $model.settings.sfxVolume, in: 0...1, percent: true)
                    }
                }

                Section("Captions") {
                    Toggle("Show captions", isOn: $model.settings.captionsEnabled)
                    Button {
                        Task { await model.generateCaptions() }
                    } label: {
                        HStack {
                            if model.isTranscribing {
                                ProgressView().controlSize(.small)
                                Text("Transcribing…")
                            } else {
                                Label(model.captionCount > 0 ? "Regenerate captions (\(model.captionCount))" : "Generate captions",
                                      systemImage: "captions.bubble")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .disabled(model.isTranscribing)
                }

                Section("Webcam bubble") {
                    Toggle("Show webcam", isOn: $model.settings.webcamEnabled)
                    if model.settings.webcamEnabled {
                        Picker("Corner", selection: $model.settings.webcamCorner) {
                            ForEach(WebcamCorner.allCases) { corner in
                                Text(corner.label).tag(corner)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        labeledSlider("Bubble size", value: $model.settings.webcamSize, in: 0.1...0.35, percent: true)
                    }
                }

                Section("Cursor") {
                    Picker("Style", selection: $model.settings.cursorStyle) {
                        ForEach(CursorStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    labeledSlider("Size", value: $model.settings.cursorScale, in: 0.5...5.0, unit: "×")
                    labeledSlider("Smoothing", value: $model.settings.cursorSmoothing, in: 0...1, percent: true)
                }

            }
            .padding(20)
        }
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Look")
                    .font(.title2.weight(.semibold))
                Text(model.project.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                model.resetLook()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.glass)
            .help("Reset to defaults")
        }
    }

    private var wallpaperSwatches: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(0..<BackgroundStyle.wallpaperCount, id: \.self) { index in
                Button {
                    model.settings.background.wallpaperIndex = index
                } label: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: wallpaperPreviewColors(index),
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(height: 42)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(model.settings.background.wallpaperIndex == index ? Color.white : Color.white.opacity(0.15),
                                        lineWidth: model.settings.background.wallpaperIndex == index ? 2 : 1)
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

    private var presetSwatches: some View {
        HStack(spacing: 10) {
            ForEach(Array(BackgroundStyle.presets.enumerated()), id: \.offset) { _, preset in
                Button {
                    model.settings.background = preset
                } label: {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(
                            colors: [Color(preset.color1), Color(preset.color2)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(height: 30)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Helpers

    private func colorBinding(_ keyPath: WritableKeyPath<RenderSettings, RGBAColor>) -> Binding<Color> {
        Binding(
            get: { Color(model.settings[keyPath: keyPath]) },
            set: { newValue in
                let ns = NSColor(newValue).usingColorSpace(.sRGB) ?? .white
                model.settings[keyPath: keyPath] = RGBAColor(
                    Double(ns.redComponent), Double(ns.greenComponent),
                    Double(ns.blueComponent), Double(ns.alphaComponent))
            }
        )
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                               unit: String = "", percent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(percent ? "\(Int(value.wrappedValue * 100))%" : String(format: "%.1f%@", value.wrappedValue, unit))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}

/// Groups a titled block of controls.
private struct Section<Content: View>: View {
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

extension Color {
    init(_ c: RGBAColor) {
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }
}
