import Foundation
import Observation

/// Scans the recordings library (~/Movies/MyDemoStudio) for `.mydemo` packages.
@MainActor
@Observable
final class LibraryModel {
    private(set) var projects: [DemoProject] = []

    init() {
        refresh()
    }

    /// Moves a recording to the Trash (recoverable), then refreshes.
    func delete(_ project: DemoProject) {
        try? FileManager.default.trashItem(at: project.packageURL, resultingItemURL: nil)
        refresh()
    }

    func refresh() {
        guard let dir = try? DemoProject.defaultLibraryDirectory(),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            projects = []
            return
        }
        projects = contents
            .filter { $0.pathExtension == "mydemo" }
            .map { DemoProject(packageURL: $0) }
            .filter { $0.isComplete }
            .sorted { $0.modifiedDate > $1.modifiedDate }
    }
}
