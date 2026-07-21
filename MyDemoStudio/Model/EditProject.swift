import Foundation
import AVFoundation
import AppKit

/// An edit project on disk: a `.mdsproj` folder package holding the edit document plus
/// any media copied into it.
///
/// ```
/// <Name>.mdsproj/
///   document.json   the EditDocument
///   Media/          copied imports, post-hoc voiceover and camera takes
///   Renders/        exports
///   filler.mov      generated black timebase (see TimelineCompositionBuilder)
///   thumb.jpg
/// ```
///
/// Projects live in `~/Movies/MyDemoStudio/Projects/`, deliberately *beside* — never
/// inside — the `.mydemo` recordings, so the existing clip library is untouched.
struct EditProject: Sendable, Identifiable, Hashable {
    let packageURL: URL

    var id: String { packageURL.lastPathComponent }
    var name: String { packageURL.deletingPathExtension().lastPathComponent }

    var documentURL: URL { packageURL.appendingPathComponent("document.json") }
    var mediaDirectory: URL { packageURL.appendingPathComponent("Media", isDirectory: true) }
    var rendersDirectory: URL { packageURL.appendingPathComponent("Renders", isDirectory: true) }
    var fillerURL: URL { packageURL.appendingPathComponent("filler.mov") }
    var thumbnailURL: URL { packageURL.appendingPathComponent("thumb.jpg") }

    var exists: Bool { FileManager.default.fileExists(atPath: documentURL.path) }

    var modifiedDate: Date {
        (try? FileManager.default.attributesOfItem(atPath: documentURL.path)[.modificationDate] as? Date) ?? .distantPast
    }

    // MARK: Document I/O

    func read() throws -> EditDocument {
        let data = try Data(contentsOf: documentURL)
        return try JSONDecoder().decode(EditDocument.self, from: data)
    }

    func write(_ document: EditDocument) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: documentURL, options: .atomic)
    }

    /// Read → mutate → write, so the UI and the CLI share one code path (and one set of
    /// invariants) for every edit.
    @discardableResult
    func update(_ body: (inout EditDocument) throws -> Void) throws -> EditDocument {
        var document = try read()
        try body(&document)
        try write(document)
        return document
    }

    // MARK: Creation

    /// The projects folder, alongside (not inside) the recordings library.
    static func defaultProjectsDirectory() throws -> URL {
        let dir = try DemoProject.defaultLibraryDirectory()
            .appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func create(named name: String, canvas: Canvas = .fullHD, in directory: URL? = nil) throws -> EditProject {
        let parent = try directory ?? defaultProjectsDirectory()
        let package = uniqueURL(for: name, in: parent)
        let project = EditProject(packageURL: package)
        try FileManager.default.createDirectory(at: project.mediaDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.rendersDirectory, withIntermediateDirectories: true)
        try project.write(.makeDefault(name: name, canvas: canvas))
        return project
    }

    /// Avoids clobbering an existing project by suffixing " 2", " 3", …
    private static func uniqueURL(for name: String, in directory: URL) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        var candidate = directory.appendingPathComponent(safe).appendingPathExtension("mdsproj")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(safe) \(index)").appendingPathExtension("mdsproj")
            index += 1
        }
        return candidate
    }

    // MARK: Media

    /// Resolves a clip's source to a file on disk. Recordings resolve into the clip
    /// library; files resolve inside this package's `Media/`.
    func url(for source: MediaSource) -> URL? {
        switch source {
        case .recording(let id):
            guard let library = try? DemoProject.defaultLibraryDirectory() else { return nil }
            let master = library.appendingPathComponent(id).appendingPathComponent("master.mov")
            return FileManager.default.fileExists(atPath: master.path) ? master : nil
        case .file(let path, _):
            let url = mediaDirectory.appendingPathComponent(path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        case .text:
            return nil
        }
    }

    /// The `.mydemo` package backing a `.recording` source, for events/captions/camera.
    func recordingPackage(for source: MediaSource) -> DemoProject? {
        guard case .recording(let id) = source,
              let library = try? DemoProject.defaultLibraryDirectory() else { return nil }
        let package = library.appendingPathComponent(id)
        let project = DemoProject(packageURL: package)
        return project.isComplete ? project : nil
    }

    /// Copies an external file into `Media/` and returns the source that references it.
    /// Copying (rather than referencing) is what keeps a project self-contained.
    func importMedia(from url: URL) throws -> MediaSource {
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let kind = MediaKind.infer(from: url)
        var destination = mediaDirectory.appendingPathComponent(url.lastPathComponent)
        var index = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = url.deletingPathExtension().lastPathComponent
            destination = mediaDirectory
                .appendingPathComponent("\(base) \(index)")
                .appendingPathExtension(url.pathExtension)
            index += 1
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return .file(path: destination.lastPathComponent, kind: kind)
    }

    /// Reserves a fresh path inside `Media/` for something we're about to record.
    func newMediaURL(prefix: String, extension ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        return mediaDirectory
            .appendingPathComponent("\(prefix)-\(stamp)")
            .appendingPathExtension(ext)
    }
}

extension MediaKind {
    /// Classifies a file by extension — good enough for import, and avoids loading the
    /// asset just to find out what it is.
    static func infer(from url: URL) -> MediaKind {
        switch url.pathExtension.lowercased() {
        case "mov", "mp4", "m4v", "avi", "mkv", "webm": return .video
        case "png", "jpg", "jpeg", "heic", "gif", "tiff", "bmp", "webp": return .image
        default: return .audio
        }
    }
}

/// Scans `~/Movies/MyDemoStudio/Projects` for `.mdsproj` packages.
enum ProjectLibrary {
    static func all() -> [EditProject] {
        guard let dir = try? EditProject.defaultProjectsDirectory(),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return contents
            .filter { $0.pathExtension == "mdsproj" }
            .map { EditProject(packageURL: $0) }
            .filter(\.exists)
            .sorted { $0.modifiedDate > $1.modifiedDate }
    }
}
