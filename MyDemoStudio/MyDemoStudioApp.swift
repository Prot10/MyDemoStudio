import SwiftUI
import AppKit

@main
struct MyDemoStudioApp: App {
    static let mcpWindowID = "mcp-setup"

    @State private var permissions = PermissionsManager()
    @Environment(\.openWindow) private var openWindow

    private func openMCPSetup() { openWindow(id: MyDemoStudioApp.mcpWindowID) }

    init() {
        // An uncaught Objective-C exception aborts the process, and the crash report
        // records only "abort() called" — no name, no reason. Logging it first turns a
        // silent abort into something diagnosable.
        CrashDiagnostics.install()

        // MCP stdio server: stay resident, speak the protocol, never show a window.
        if MDSMCPServer.isMCP {
            NSApplication.shared.setActivationPolicy(.prohibited)
            Task.detached { await MDSMCPServer.run() }
        }

        // Headless command surface (one verb, then exit) — used by scripts and by the
        // Node bridge.
        if MDSCLI.isCLI {
            Task { @MainActor in exit(await MDSCLI.run()) }
        }
        switch ProcessInfo.processInfo.environment["MDS_SELFTEST"] {
        case "1":
            Task { @MainActor in exit(await SelfTest.run() ? 0 : 2) }
        case "algo":
            // Deterministic pure-logic checks (ZoomPlanner / CursorSmoother); no recording.
            exit(SelfTest.runAlgo() ? 0 : 2)
        case "audioexport":
            Task { @MainActor in exit(await SelfTest.runAudioExport() ? 0 : 2) }
        case "editor":
            // Editor glue: project load, live preview, edits, undo, autosave, MCP reload.
            Task { @MainActor in exit(await SelfTestEditor.run() ? 0 : 2) }
        case "timeline":
            // Multi-clip timeline: document math, then a real export probed pixel by pixel.
            Task { @MainActor in exit(await SelfTestTimeline.run() ? 0 : 2) }
        default:
            break
        }
    }

    var body: some Scene {
        Window("MyDemoStudio", id: "main") {
            RootView()
                .environment(permissions)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Connect an AI Agent…") { openMCPSetup() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }

        Window("Connect an AI Agent", id: MyDemoStudioApp.mcpWindowID) {
            MCPSetupView()
        }
        .windowResizability(.contentMinSize)
    }
}
