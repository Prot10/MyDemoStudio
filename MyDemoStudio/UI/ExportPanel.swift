import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The export controls shared by both editors: pick a format and resolution, then choose
/// where the file goes.
///
/// The format and resolution are remembered app-wide, and the save panel reopens in the
/// last folder you exported to — so the common case is two clicks, while the destination
/// is still always yours to choose.
struct ExportControls: View {
    let isExporting: Bool
    let progress: Double
    let canExport: Bool
    let suggestedName: String
    let errorMessage: String?
    /// Called with the chosen format, resolution and destination.
    let onExport: (ExportFormat, ExportPreset, URL) -> Void

    @AppStorage("exportFormat") private var formatRaw = ExportFormat.mp4.rawValue
    @AppStorage("exportPreset") private var presetRaw = ExportPreset.fullHD.rawValue

    private var format: ExportFormat { ExportFormat(rawValue: formatRaw) ?? .mp4 }
    private var preset: ExportPreset { ExportPreset(rawValue: presetRaw) ?? .fullHD }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EXPORT")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Format", selection: $formatRaw) {
                ForEach(ExportFormat.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(format.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !format.isGIF {
                Picker("Resolution", selection: $presetRaw) {
                    ForEach(ExportPreset.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
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
                Label("Export…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(.pink)
            .disabled(isExporting || !canExport)
            .help("Choose where to save the exported video")

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.top, 6)
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
        // Keep the extension in step if the user switches type in the panel.
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
