import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The floating controls in the top-right of the editor: export, and the inspector
/// toggle. Both are actions you reach for occasionally, so they hover over the content
/// instead of taking up permanent space in a panel.
struct EditorFloatingActions: View {
    @Binding var showInspector: Bool
    let isExporting: Bool
    let progress: Double
    let canExport: Bool
    let suggestedName: String
    let errorMessage: String?
    let onExport: (ExportFormat, ExportPreset, URL) -> Void

    @State private var showExport = false

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 2) {
                Button {
                    showExport = true
                } label: {
                    ZStack {
                        // While a render runs the button becomes the progress readout, so
                        // the popover doesn't have to stay open to watch it.
                        if isExporting {
                            ProgressView(value: progress)
                                .progressViewStyle(.circular)
                                .controlSize(.small)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .frame(width: 26, height: 20)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(!canExport)
                .help(isExporting ? "Rendering… \(Int(progress * 100))%" : "Export this video")
                .popover(isPresented: $showExport, arrowEdge: .bottom) {
                    ExportPopover(isExporting: isExporting, progress: progress,
                                  suggestedName: suggestedName, errorMessage: errorMessage) { format, preset, url in
                        showExport = false
                        onExport(format, preset, url)
                    }
                }

                Divider().frame(height: 16).opacity(0.5)

                Button {
                    showInspector.toggle()
                } label: {
                    Image(systemName: showInspector ? "sidebar.trailing" : "sidebar.leading")
                        .frame(width: 26, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(showInspector ? "Hide inspector" : "Show inspector")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .padding(14)
    }
}

/// Format, resolution, and where the file goes.
private struct ExportPopover: View {
    let isExporting: Bool
    let progress: Double
    let suggestedName: String
    let errorMessage: String?
    let onExport: (ExportFormat, ExportPreset, URL) -> Void

    @AppStorage("exportFormat") private var formatRaw = ExportFormat.mp4.rawValue
    @AppStorage("exportPreset") private var presetRaw = ExportPreset.fullHD.rawValue

    private var format: ExportFormat { ExportFormat(rawValue: formatRaw) ?? .mp4 }
    private var preset: ExportPreset { ExportPreset(rawValue: presetRaw) ?? .fullHD }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Format").font(.caption).foregroundStyle(.secondary)
                Picker("Format", selection: $formatRaw) {
                    ForEach(ExportFormat.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden()
                Text(format.detail).font(.caption2).foregroundStyle(.secondary)
            }

            if !format.isGIF {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Resolution").font(.caption).foregroundStyle(.secondary)
                    Picker("Resolution", selection: $presetRaw) {
                        ForEach(ExportPreset.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
            }

            if isExporting {
                ProgressView(value: progress) {
                    Text("Rendering… \(Int(progress * 100))%").font(.caption)
                }
            }

            Button {
                if let url = ExportDestination.chooseFile(named: suggestedName, format: format) {
                    onExport(format, preset, url)
                }
            } label: {
                Label("Choose destination…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(.pink)
            .disabled(isExporting)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 290)
    }
}

/// Picks the export destination, remembering the folder between exports.
enum ExportDestination {

    private static let lastFolderKey = "lastExportFolder"

    static func chooseFile(named name: String, format: ExportFormat) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Video"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "\(sanitized(name)).\(format.fileExtension)"
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        if let path = UserDefaults.standard.string(forKey: lastFolderKey) {
            panel.directoryURL = URL(fileURLWithPath: path)
        } else {
            panel.directoryURL = try? FileManager.default.url(
                for: .moviesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        }

        guard panel.runModal() == .OK, var url = panel.url else { return nil }

        // The panel can hand back a name without the extension; normalise it so the
        // writer and the container always agree.
        if url.pathExtension.lowercased() != format.fileExtension {
            url = url.deletingPathExtension().appendingPathExtension(format.fileExtension)
        }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: lastFolderKey)
        return url
    }

    private static func sanitized(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}
