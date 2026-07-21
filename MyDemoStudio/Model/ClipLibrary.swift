import Foundation
import AVFoundation
import AppKit

/// One recording in the clip library, with the metadata the timeline editor needs to
/// place it without loading the whole asset.
struct LibraryClip: Sendable, Identifiable, Hashable {
    /// The `.mydemo` package folder name — also the stable id stored in `MediaSource.recording`.
    let id: String
    let name: String
    let packageURL: URL
    let duration: Double
    let pixelWidth: Int
    let pixelHeight: Int
    let hasCamera: Bool
    let hasEvents: Bool
    let modifiedDate: Date

    var project: DemoProject { DemoProject(packageURL: packageURL) }
    var masterURL: URL { project.masterURL }
    var thumbnailURL: URL { packageURL.appendingPathComponent("thumb.jpg") }

    var source: MediaSource { .recording(id: id) }

    /// A whole-clip timeline clip, ready to drop on the main track.
    func makeTimelineClip() -> TimelineClip {
        TimelineClip(source: source, start: 0, sourceIn: 0, sourceOut: duration, name: name)
    }
}

/// Reads `~/Movies/MyDemoStudio/*.mydemo` — the recordings the app has always produced.
///
/// Nothing here moves, renames or rewrites an existing recording: the only file it ever
/// adds to a package is a cached `meta.json` + `thumb.jpg` alongside the originals, so
/// every recording made before the editor existed keeps working untouched.
enum ClipLibrary {

    /// Cached metadata written next to the master so the sidebar doesn't have to open
    /// every movie on each launch.
    private struct CachedMeta: Codable {
        var duration: Double
        var pixelWidth: Int
        var pixelHeight: Int
        /// What the user renamed this recording to. The package folder is never renamed:
        /// projects reference recordings by folder name, so renaming on disk would break
        /// every project that used the clip.
        var displayName: String?
    }

    static func all() -> [LibraryClip] {
        guard let dir = try? DemoProject.defaultLibraryDirectory(),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return contents
            .filter { $0.pathExtension == "mydemo" }
            .map { DemoProject(packageURL: $0) }
            .filter(\.isComplete)
            .compactMap(clip(for:))
            .sorted { $0.modifiedDate > $1.modifiedDate }
    }

    static func clip(id: String) -> LibraryClip? {
        guard let dir = try? DemoProject.defaultLibraryDirectory() else { return nil }
        let project = DemoProject(packageURL: dir.appendingPathComponent(id))
        guard project.isComplete else { return nil }
        return clip(for: project)
    }

    static func clip(for project: DemoProject) -> LibraryClip? {
        let track = try? project.readEventTrack()
        let meta = cachedMeta(for: project, eventTrack: track)
        return LibraryClip(
            id: project.packageURL.lastPathComponent,
            name: meta.displayName?.isEmpty == false ? meta.displayName! : project.name,
            packageURL: project.packageURL,
            duration: meta.duration,
            pixelWidth: meta.pixelWidth,
            pixelHeight: meta.pixelHeight,
            hasCamera: project.hasCamera,
            hasEvents: (track?.events.isEmpty == false),
            modifiedDate: project.modifiedDate
        )
    }

    private static func metaURL(_ project: DemoProject) -> URL {
        project.packageURL.appendingPathComponent("meta.json")
    }

    /// Returns cached duration/size, computing (and caching) it on first use. The event
    /// track already knows the pixel size, so only the duration needs the asset.
    private static func cachedMeta(for project: DemoProject, eventTrack: EventTrack?) -> CachedMeta {
        if let data = try? Data(contentsOf: metaURL(project)),
           let cached = try? JSONDecoder().decode(CachedMeta.self, from: data),
           cached.duration > 0 {
            return cached
        }
        let asset = AVURLAsset(url: project.masterURL)
        // Synchronous duration read: this runs once per recording, then it's cached.
        let duration = CMTimeGetSeconds(asset.duration)
        let meta = CachedMeta(
            duration: duration.isFinite && duration > 0 ? duration : 0,
            pixelWidth: eventTrack?.pixelWidth ?? 1920,
            pixelHeight: eventTrack?.pixelHeight ?? 1080,
            displayName: nil
        )
        if meta.duration > 0, let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: metaURL(project), options: .atomic)
        }
        return meta
    }

    /// Renames a recording for display. Only the cached metadata inside the package
    /// changes — the folder keeps its name, so projects referencing this clip keep
    /// working. Passing an empty name restores the original.
    @discardableResult
    static func rename(clipID: String, to newName: String) -> Bool {
        guard let dir = try? DemoProject.defaultLibraryDirectory() else { return false }
        let project = DemoProject(packageURL: dir.appendingPathComponent(clipID))
        guard project.isComplete else { return false }

        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        var meta = cachedMeta(for: project, eventTrack: try? project.readEventTrack())
        meta.displayName = trimmed.isEmpty ? nil : trimmed
        guard let data = try? JSONEncoder().encode(meta) else { return false }
        do {
            try data.write(to: metaURL(project), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Renders (and caches) a poster frame for a recording. Additive — the package is
    /// otherwise untouched.
    @discardableResult
    static func thumbnail(for clip: LibraryClip) -> NSImage? {
        if let image = NSImage(contentsOf: clip.thumbnailURL) { return image }
        let asset = AVURLAsset(url: clip.masterURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        let time = CMTime(seconds: min(1.0, max(clip.duration * 0.1, 0.05)), preferredTimescale: 600)
        guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            try? jpeg.write(to: clip.thumbnailURL, options: .atomic)
        }
        return image
    }
}
