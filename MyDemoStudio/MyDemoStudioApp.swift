import SwiftUI

@main
struct MyDemoStudioApp: App {
    @State private var permissions = PermissionsManager()

    init() {
        switch ProcessInfo.processInfo.environment["MDS_SELFTEST"] {
        case "1":
            Task { @MainActor in exit(await SelfTest.run() ? 0 : 2) }
        case "algo":
            // Deterministic pure-logic checks (ZoomPlanner / CursorSmoother); no recording.
            exit(SelfTest.runAlgo() ? 0 : 2)
        case "audioexport":
            Task { @MainActor in exit(await SelfTest.runAudioExport() ? 0 : 2) }
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
    }
}
