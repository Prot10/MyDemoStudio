import Foundation
import Observation
import CoreGraphics

/// What the sidebar has selected — an edit project, or a raw recording from the clip
/// library (which still opens the original single-recording editor).
enum LibrarySelection: Hashable {
    case project(String)
    case clip(String)
}

/// The app's two libraries.
///
/// - **Clips**: every `.mydemo` recording in `~/Movies/MyDemoStudio`. These are the
///   originals — the editor only ever references them, never rewrites or moves them, so
///   recordings made before projects existed keep working exactly as before.
/// - **Projects**: `.mdsproj` edit documents in `~/Movies/MyDemoStudio/Projects`, each
///   assembling clips (plus imported media) into a finished video.
@MainActor
@Observable
final class LibraryModel {
    private(set) var clips: [LibraryClip] = []
    private(set) var projects: [EditProject] = []

    init() {
        refresh()
    }

    func refresh() {
        clips = ClipLibrary.all()
        projects = ProjectLibrary.all()
    }

    func clip(id: String) -> LibraryClip? { clips.first { $0.id == id } }
    func project(id: String) -> EditProject? { projects.first { $0.id == id } }

    /// Moves a recording to the Trash (recoverable). Projects that referenced it keep
    /// their clips, which simply render as missing media.
    func deleteClip(_ clip: LibraryClip) {
        try? FileManager.default.trashItem(at: clip.packageURL, resultingItemURL: nil)
        refresh()
    }

    func deleteProject(_ project: EditProject) {
        try? FileManager.default.trashItem(at: project.packageURL, resultingItemURL: nil)
        refresh()
    }

    /// Renames a recording. The package folder keeps its name — that name is the id
    /// projects reference — so only the display name changes.
    func renameClip(_ clip: LibraryClip, to newName: String) {
        ClipLibrary.rename(clipID: clip.id, to: newName)
        refresh()
    }

    /// Renames a project, moving its package to match. Nothing references a project by
    /// name, so the folder can safely follow the title.
    @discardableResult
    func renameProject(_ project: EditProject, to newName: String) -> EditProject? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != project.name else { return project }

        // Update the title inside the document first, so it stays in step with the folder.
        try? project.update { $0.name = trimmed }

        let destination = project.packageURL
            .deletingLastPathComponent()
            .appendingPathComponent(trimmed.replacingOccurrences(of: "/", with: "-"))
            .appendingPathExtension("mdsproj")
        guard destination != project.packageURL,
              !FileManager.default.fileExists(atPath: destination.path) else {
            refresh()
            return project
        }
        do {
            try FileManager.default.moveItem(at: project.packageURL, to: destination)
        } catch {
            refresh()
            return project
        }
        refresh()
        return EditProject(packageURL: destination)
    }

    @discardableResult
    func createProject(named name: String, aspect: OutputAspect = .wide, seededWith clip: LibraryClip? = nil) -> EditProject? {
        let base = clip.map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) } ?? CGSize(width: 1920, height: 1080)
        let canvas = Canvas.make(aspect: aspect, masterWidth: Int(base.width), masterHeight: Int(base.height))
        guard let project = try? EditProject.create(named: name, canvas: canvas) else { return nil }
        if let clip {
            try? project.update { document in
                guard let track = document.tracks.first(where: { $0.kind == .main }) else { return }
                document.add(clip.makeTimelineClip(), toTrack: track.id, at: 0)
            }
        }
        refresh()
        return project
    }
}
