import SwiftUI
import AppKit

/// Top-level view. Gates the app behind the two required permissions, then shows
/// the home surface. In later milestones the "ready" branch becomes the recorder +
/// editor; for M0 it is a placeholder that proves the Liquid Glass shell builds.
struct RootView: View {
    @Environment(PermissionsManager.self) private var permissions
    @Environment(\.scenePhase) private var scenePhase
    @State private var recorder = RecordingCoordinator()
    @State private var library = LibraryModel()
    @State private var selection: URL?
    @State private var editorModel: ProjectEditorModel?

    var body: some View {
        Group {
            if permissions.allGranted {
                NavigationSplitView {
                    SidebarView(library: library, recorder: recorder, selection: $selection)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
                } detail: {
                    detail
                }
                .task {
                    // Editor-preview testing: jump straight into the first recording.
                    if ProcessInfo.processInfo.environment["MDS_BYPASS_PERMS"] == "1" {
                        NSApplication.shared.activate()
                        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
                        if selection == nil, let first = library.projects.first {
                            selection = first.packageURL
                        }
                        if let path = ProcessInfo.processInfo.environment["MDS_WINDOW_SHOT"] {
                            DebugWindowShot.capture(after: 4, to: path)
                        }
                    }
                }
            } else {
                PermissionsGateView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(BackdropView())
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { permissions.refresh() }
        }
        .onChange(of: selection) { _, newValue in loadEditor(newValue) }
        .onChange(of: recorder.lastProject?.packageURL) { _, url in
            if let url {
                library.refresh()
                selection = url
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if recorder.isRecording || recorder.isBusy {
            RecordingOverlayView(recorder: recorder)
        } else if let editorModel {
            EditorView(model: editorModel)
        } else {
            ContentUnavailableView {
                Label("No recording selected", systemImage: "film.stack")
            } description: {
                Text("Create a new recording or pick one from the sidebar.")
            } actions: {
                RecordButton(recorder: recorder)
                    .frame(width: 240)
            }
        }
    }

    private func loadEditor(_ url: URL?) {
        guard let url else { editorModel = nil; return }
        editorModel = ProjectEditorModel(project: DemoProject(packageURL: url))
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Bindable var library: LibraryModel
    @Bindable var recorder: RecordingCoordinator
    @Binding var selection: URL?
    @State private var showTargetPicker = false

    var body: some View {
        List(selection: $selection) {
            Section("Recordings") {
                ForEach(library.projects, id: \.packageURL) { project in
                    Label(project.name, systemImage: "film")
                        .lineLimit(1)
                        .tag(project.packageURL)
                        .contextMenu {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([project.packageURL])
                            } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                            }
                            Divider()
                            Button(role: .destructive) {
                                delete(project)
                            } label: {
                                Label("Move to Trash", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                delete(project)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                if library.projects.isEmpty {
                    Text("No recordings yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("MyDemoStudio")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                captureTargetPicker
                Toggle(isOn: $recorder.recordMicrophone) {
                    Label("Record microphone", systemImage: recorder.recordMicrophone ? "mic.fill" : "mic.slash")
                        .font(.callout)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(recorder.isRecording || recorder.isBusy)

                Toggle(isOn: $recorder.recordWebcam) {
                    Label("Record webcam", systemImage: recorder.recordWebcam ? "web.camera.fill" : "web.camera")
                        .font(.callout)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(recorder.isRecording || recorder.isBusy)

                RecordButton(recorder: recorder)
            }
            .padding(12)
        }
    }

    private func delete(_ project: DemoProject) {
        if selection == project.packageURL { selection = nil }
        library.delete(project)
    }

    private var captureTargetPicker: some View {
        Button {
            // Refresh the window list every time, so newly-focused apps appear.
            Task {
                await recorder.refreshWindows()
                showTargetPicker = true
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: captureIcon)
                Text(recorder.captureTarget.label).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .disabled(recorder.isRecording || recorder.isBusy)
        .popover(isPresented: $showTargetPicker, arrowEdge: .top) {
            targetList
        }
    }

    private var targetList: some View {
        VStack(alignment: .leading, spacing: 2) {
            targetRow(label: "Entire Screen", systemImage: "display") {
                recorder.captureTarget = .display
            }
            Divider().padding(.vertical, 4)
            if recorder.availableWindows.isEmpty {
                Text("No other app windows found.\nOpen the app you want to record, then reopen this menu.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            } else {
                ForEach(recorder.availableWindows) { window in
                    targetRow(label: window.displayName, systemImage: "macwindow") {
                        recorder.captureTarget = .window(window)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 300)
    }

    private func targetRow(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            showTargetPicker = false
        } label: {
            Label(label, systemImage: systemImage)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4).padding(.horizontal, 6)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var captureIcon: String {
        switch recorder.captureTarget {
        case .display: return "display"
        case .window: return "macwindow"
        }
    }
}

private struct RecordButton: View {
    @Bindable var recorder: RecordingCoordinator

    var body: some View {
        Button {
            recorder.toggle()
        } label: {
            Label(
                recorder.isRecording ? "Stop Recording" : "New Recording",
                systemImage: recorder.isRecording ? "stop.fill" : "record.circle.fill"
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(recorder.isRecording ? .red : .pink)
        .disabled(recorder.isBusy)
    }
}

// MARK: - Recording overlay

private struct RecordingOverlayView: View {
    @Bindable var recorder: RecordingCoordinator

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "record.circle")
                .font(.system(size: 64))
                .foregroundStyle(.red)
                .symbolEffect(.pulse, options: .repeating, isActive: recorder.isRecording)
            Text(recorder.isBusy ? "Finishing…" : "Recording…")
                .font(.largeTitle.weight(.semibold))
            Text(timeString(recorder.elapsed))
                .font(.system(size: 44, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.red)
            RecordButton(recorder: recorder)
                .frame(width: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BackdropView())
    }

    private func timeString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// A soft gradient backdrop that sits in the content layer, so the Liquid Glass
/// controls floating above it have something to refract.
private struct BackdropView: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.10, green: 0.11, blue: 0.18),
                Color(red: 0.18, green: 0.13, blue: 0.24),
                Color(red: 0.09, green: 0.14, blue: 0.20)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

// MARK: - Permissions onboarding

private struct PermissionsGateView: View {
    @Environment(PermissionsManager.self) private var permissions

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "record.circle")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(.pink.gradient)
                Text("MyDemoStudio")
                    .font(.largeTitle.weight(.semibold))
                Text("Two quick permissions and you're ready to record.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            GlassEffectContainer(spacing: 16) {
                VStack(spacing: 16) {
                    PermissionRow(
                        title: "Screen Recording",
                        detail: "Lets MyDemoStudio capture your display.",
                        systemImage: "rectangle.on.rectangle",
                        status: permissions.screenRecording,
                        action: { permissions.requestScreenRecording() },
                        openSettings: { permissions.openSettings(for: .screenRecording) }
                    )
                    PermissionRow(
                        title: "Accessibility",
                        detail: "Lets MyDemoStudio track clicks for automatic zoom.",
                        systemImage: "cursorarrow.rays",
                        status: permissions.accessibility,
                        action: { permissions.requestAccessibility() },
                        openSettings: { permissions.openSettings(for: .accessibility) }
                    )
                }
            }
            .frame(maxWidth: 520)

            if !permissions.screenRecording.isGranted {
                VStack(spacing: 10) {
                    Label {
                        Text("Turned Screen Recording on already? It only takes effect **after a relaunch**.")
                    } icon: {
                        Image(systemName: "info.circle")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                    Button {
                        permissions.relaunch()
                    } label: {
                        Label("Quit & Reopen", systemImage: "arrow.clockwise.circle.fill")
                            .padding(.horizontal, 10)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .tint(.blue)
                }
                .frame(maxWidth: 520)
                .padding(.top, 4)
            }

            Button {
                permissions.refresh()
            } label: {
                Label("Re-check permissions", systemImage: "arrow.clockwise")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        .padding(40)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let status: PermissionsManager.Status
    let action: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 40, height: 40)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if status.isGranted {
                Label("Granted", systemImage: "checkmark.seal.fill")
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Granted")
            } else {
                Menu {
                    Button("Request…", action: action)
                    Button("Open System Settings…", action: openSettings)
                } label: {
                    Text("Grant")
                } primaryAction: {
                    action()
                }
                .menuStyle(.button)
                .buttonStyle(.glassProminent)
                .fixedSize()
            }
        }
        .padding(16)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

