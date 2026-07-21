import Foundation

/// A recording on disk. A `.mydemo` package is a plain folder holding the pristine
/// master movie, the input event log, and (from M2 onward) the non-destructive edit
/// settings. The master is never mutated — every effect is applied at render time.
struct DemoProject: Sendable {
    let packageURL: URL

    var masterURL: URL { packageURL.appendingPathComponent("master.mov") }
    var eventsURL: URL { packageURL.appendingPathComponent("events.json") }
    var settingsURL: URL { packageURL.appendingPathComponent("project.json") }
    var cameraURL: URL { packageURL.appendingPathComponent("camera.mov") }
    var captionsURL: URL { packageURL.appendingPathComponent("captions.json") }

    /// True if a webcam recording exists for this project.
    var hasCamera: Bool { FileManager.default.fileExists(atPath: cameraURL.path) }

    func writeCaptions(_ track: CaptionTrack) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(track).write(to: captionsURL, options: .atomic)
    }

    func readCaptions() -> CaptionTrack? {
        guard let data = try? Data(contentsOf: captionsURL) else { return nil }
        return try? JSONDecoder().decode(CaptionTrack.self, from: data)
    }

    var name: String { packageURL.deletingPathExtension().lastPathComponent }

    /// Creates a fresh, empty `.mydemo` package under `directory`.
    static func create(named name: String, in directory: URL) throws -> DemoProject {
        let package = directory
            .appendingPathComponent(name)
            .appendingPathExtension("mydemo")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        return DemoProject(packageURL: package)
    }

    /// The app's default home for recordings: ~/Movies/MyDemoStudio.
    static func defaultLibraryDirectory() throws -> URL {
        let movies = try FileManager.default.url(
            for: .moviesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = movies.appendingPathComponent("MyDemoStudio", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func writeEventTrack(_ track: EventTrack) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(track).write(to: eventsURL, options: .atomic)
    }

    func readEventTrack() throws -> EventTrack {
        let data = try Data(contentsOf: eventsURL)
        return try JSONDecoder().decode(EventTrack.self, from: data)
    }

    func writeSettings(_ settings: RenderSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: settingsURL, options: .atomic)
    }

    /// Loads saved settings, or defaults derived from the recording's master size.
    func readSettings() -> RenderSettings? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return try? JSONDecoder().decode(RenderSettings.self, from: data)
    }

    /// True if this package holds a finished recording (master + events).
    var isComplete: Bool {
        FileManager.default.fileExists(atPath: masterURL.path)
            && FileManager.default.fileExists(atPath: eventsURL.path)
    }

    var modifiedDate: Date {
        (try? FileManager.default.attributesOfItem(atPath: packageURL.path)[.modificationDate] as? Date) ?? .distantPast
    }
}
