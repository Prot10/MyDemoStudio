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
    @State private var selection: LibrarySelection?
    @Environment(\.openWindow) private var openWindowRoot
    @State private var clipEditor: ProjectEditorModel?
    @State private var timelineEditor: TimelineEditorModel?

    var body: some View {
        Group {
            if permissions.allGranted {
                NavigationSplitView {
                    SidebarView(library: library, recorder: recorder, selection: $selection)
                        .navigationSplitViewColumnWidth(min: 230, ideal: 262, max: 340)
                } detail: {
                    detail
                }
                .task {
                    // Editor-preview testing: jump straight into the first recording.
                    if ProcessInfo.processInfo.environment["MDS_BYPASS_PERMS"] == "1" {
                        NSApplication.shared.activate()
                        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
                        if let name = ProcessInfo.processInfo.environment["MDS_SELECT_PROJECT"],
                           let match = library.projects.first(where: { $0.name == name || $0.id == name }) {
                            selection = .project(match.id)
                        } else if selection == nil, let first = library.clips.first {
                            selection = .clip(first.id)
                        }
                        if let path = ProcessInfo.processInfo.environment["MDS_WINDOW_SHOT"] {
                            DebugWindowShot.capture(after: 4, to: path)
                        }
                        if ProcessInfo.processInfo.environment["MDS_OPEN_MCP"] == "1" {
                            openWindowRoot(id: MyDemoStudioApp.mcpWindowID)
                        }
                        if ProcessInfo.processInfo.environment["MDS_STRESS"] == "1" {
                            StabilityStress.run()
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
                selection = .clip(url.lastPathComponent)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if recorder.isRecording || recorder.isBusy {
            RecordingOverlayView(recorder: recorder)
        } else if let timelineEditor {
            TimelineEditorView(model: timelineEditor, clips: library.clips)
        } else if let clipEditor {
            EditorView(model: clipEditor)
        } else {
            ContentUnavailableView {
                Label("Nothing selected", systemImage: "film.stack")
            } description: {
                Text("Pick a project to edit, open a recording, or record something new.")
            } actions: {
                RecordButton(recorder: recorder)
                    .frame(width: 240)
            }
        }
    }

    private func loadEditor(_ selection: LibrarySelection?) {
        clipEditor = nil
        timelineEditor = nil
        switch selection {
        case .clip(let id):
            guard let clip = library.clip(id: id) else { return }
            clipEditor = ProjectEditorModel(project: clip.project)
        case .project(let id):
            guard let project = library.project(id: id) else { return }
            let model = TimelineEditorModel(project: project)
            timelineEditor = model
            if ProcessInfo.processInfo.environment["MDS_STRESS"] == "1" {
                StabilityStress.editorModel = model
            }
        case nil:
            break
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Bindable var library: LibraryModel
    @Bindable var recorder: RecordingCoordinator
    @Binding var selection: LibrarySelection?
    @Environment(\.openWindow) private var openWindow
    @State private var showTargetPicker = false
    @State private var renaming: LibrarySelection?
    @State private var renameText = ""
    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(library.projects) { project in
                    Label(project.name, systemImage: "square.stack.3d.down.right")
                        .lineLimit(1)
                        .tag(LibrarySelection.project(project.id))
                        .contextMenu {
                            Button {
                                renameText = project.name
                                renaming = .project(project.id)
                            } label: {
                                Label("Rename…", systemImage: "pencil")
                            }
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([project.packageURL])
                            } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                            }
                            Divider()
                            Button(role: .destructive) {
                                if selection == .project(project.id) { selection = nil }
                                library.deleteProject(project)
                            } label: {
                                Label("Move to Trash", systemImage: "trash")
                            }
                        }
                }
                if library.projects.isEmpty {
                    Text("No projects yet — create one from a recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    newProject(from: nil)
                } label: {
                    Label("New project", systemImage: "plus")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            } header: {
                Text("Projects")
            }

            Section {
                ForEach(library.clips) { clip in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(clip.name).lineLimit(1)
                            Text(durationText(clip.duration))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "film")
                    }
                    .tag(LibrarySelection.clip(clip.id))
                    .contextMenu {
                        Button {
                            renameText = clip.name
                            renaming = .clip(clip.id)
                        } label: {
                            Label("Rename…", systemImage: "pencil")
                        }
                        Button {
                            newProject(from: clip)
                        } label: {
                            Label("New project from this clip", systemImage: "square.stack.3d.down.right")
                        }
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([clip.packageURL])
                        } label: {
                            Label("Reveal in Finder", systemImage: "folder")
                        }
                        Divider()
                        Button(role: .destructive) {
                            if selection == .clip(clip.id) { selection = nil }
                            library.deleteClip(clip)
                        } label: {
                            Label("Move to Trash", systemImage: "trash")
                        }
                    }
                }
                if library.clips.isEmpty {
                    Text("No recordings yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Clips")
            }
        }
        .navigationTitle("MyDemoStudio")
        .alert("Rename", isPresented: isRenaming) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") { commitRename() }
        } message: {
            Text("Recordings keep their file on disk — only the name shown here changes, so projects using the clip keep working. Clear the field to restore the original name.")
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button {
                    openWindow(id: MyDemoStudioApp.mcpWindowID)
                } label: {
                    Label("Connect an AI agent", systemImage: "sparkles")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Let Claude, Cursor, VS Code or any MCP agent edit your videos")

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

    private func commitRename() {
        defer { renaming = nil }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch renaming {
        case .clip(let id):
            // Clearing the field restores the recording's original name.
            guard let clip = library.clip(id: id) else { return }
            library.renameClip(clip, to: name)
        case .project(let id):
            guard !name.isEmpty, let project = library.project(id: id) else { return }
            let renamed = library.renameProject(project, to: name)
            // The package moved, so the selection has to follow it.
            if selection == .project(id), let renamed { selection = .project(renamed.id) }
        case nil:
            break
        }
    }

    /// Creates a project, optionally seeded with a recording already on the timeline,
    /// and opens it.
    private func newProject(from clip: LibraryClip?) {
        let name = clip?.name ?? "Untitled project"
        guard let project = library.createProject(named: name, seededWith: clip) else { return }
        selection = .project(project.id)
    }

    private func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// A pop-up-button-shaped control sized to match the record button beneath it. It
    /// stays a button + popover rather than a `Menu` so the window list can be refreshed
    /// each time it opens — newly-focused apps have to appear without relaunching.
    private var captureTargetPicker: some View {
        Button {
            Task {
                await recorder.refreshWindows()
                showTargetPicker = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: captureIcon)
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                Text(recorder.captureTarget.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .disabled(recorder.isRecording || recorder.isBusy)
        .help("Choose what to record")
        .popover(isPresented: $showTargetPicker, arrowEdge: .top) {
            targetList
        }
    }

    private var targetList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Screen")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            targetRow(label: "Entire Screen", systemImage: "display",
                      isSelected: !recorder.captureTarget.isWindow) {
                recorder.captureTarget = .display
            }

            Text("Windows")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.top, 8)

            if recorder.availableWindows.isEmpty {
                Text("No other app windows found.\nOpen the app you want to record, then reopen this menu.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6).padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(recorder.availableWindows) { window in
                            targetRow(label: window.displayName, systemImage: "macwindow",
                                      isSelected: recorder.captureTarget.windowID == window.id) {
                                recorder.captureTarget = .window(window)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(10)
        .frame(width: 320)
    }

    private func targetRow(label: String, systemImage: String, isSelected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button {
            action()
            showTargetPicker = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage).frame(width: 18)
                Text(label).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 6))
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

