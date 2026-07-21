import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

/// Headless command surface: `MyDemoStudio --cli <verb> --json '{…}'`.
///
/// Every verb reads the project, mutates the `EditDocument` through the *same* methods
/// the editor UI calls, writes it back atomically, and prints one JSON object. That's
/// what lets the MCP server stay a thin adapter — all document logic lives here, so the
/// two surfaces can never drift apart.
enum MDSCLI {

    /// True when the process was launched as a CLI rather than as the app.
    static var isCLI: Bool { CommandLine.arguments.contains("--cli") }

    struct CLIError: Error { let message: String }

    static func run() async -> Int32 {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--cli"), index + 1 < args.count else {
            emit(["ok": false, "error": "usage: --cli <verb> [--json <payload>]", "verbs": verbs])
            return 2
        }
        let verb = args[index + 1]
        let payload: [String: Any]
        do {
            payload = try readPayload(args)
        } catch let error as CLIError {
            emit(["ok": false, "error": error.message]); return 2
        } catch {
            emit(["ok": false, "error": "\(error)"]); return 2
        }

        do {
            var result = try await dispatch(verb: verb, payload: payload)
            result["ok"] = true
            emit(result)
            return 0
        } catch let error as CLIError {
            emit(["ok": false, "error": error.message, "verb": verb])
            return 1
        } catch {
            emit(["ok": false, "error": "\(error)", "verb": verb])
            return 1
        }
    }

    static let verbs = [
        "clips.list", "clips.info", "clips.rename",
        "projects.list", "project.create", "project.get", "project.delete",
        "project.import", "project.setLook", "project.addTrack",
        "timeline.addClip", "timeline.addText", "timeline.split", "timeline.trim",
        "timeline.setSpeed", "timeline.move", "timeline.delete", "timeline.setClip",
        "timeline.compact", "clip.setLook", "clip.copySettings", "project.applyLookToAll",
        "project.export", "project.renderFrame"
    ]

    // MARK: Dispatch

    static func dispatch(verb: String, payload: [String: Any]) async throws -> [String: Any] {
        switch verb {

        case "clips.list":
            return ["clips": ClipLibrary.all().map(describe)]

        case "clips.info":
            let id = try string(payload, "id")
            guard let clip = ClipLibrary.clip(id: id) else { throw CLIError(message: "no such clip: \(id)") }
            return ["clip": describe(clip)]

        case "clips.rename":
            // Renames the display name only; the package folder is the id projects
            // reference, so it never moves.
            let id = try string(payload, "id")
            // An empty name is meaningful here: it clears the override and restores the
            // recording's original, file-derived name.
            guard let name = payload["name"] as? String else {
                throw CLIError(message: "missing required string 'name' (empty restores the original)")
            }
            guard ClipLibrary.rename(clipID: id, to: name) else {
                throw CLIError(message: "could not rename '\(id)'")
            }
            guard let clip = ClipLibrary.clip(id: id) else { throw CLIError(message: "no such clip: \(id)") }
            return ["clip": describe(clip)]

        case "projects.list":
            return ["projects": ProjectLibrary.all().map { project in
                [
                    "id": project.id,
                    "name": project.name,
                    "path": project.packageURL.path,
                    "duration": (try? project.read().duration) ?? 0,
                    "modified": ISO8601DateFormatter().string(from: project.modifiedDate)
                ] as [String: Any]
            }]

        case "project.create":
            let name = try string(payload, "name")
            let aspect = OutputAspect(rawValue: payload["aspect"] as? String ?? "wide") ?? .wide
            let fps = payload["fps"] as? Int ?? 60
            let size = aspect.canvasSize(masterWidth: 1920, masterHeight: 1080)
            let canvas = Canvas(width: size.width, height: size.height, aspect: aspect, fps: fps)
            let project = try EditProject.create(named: name, canvas: canvas)
            return ["project": project.id, "path": project.packageURL.path,
                    "tracks": try project.read().tracks.map(describe)]

        case "project.get":
            let project = try resolveProject(payload)
            let document = try project.read()
            return ["project": project.id, "path": project.packageURL.path,
                    "document": try encodeDocument(document)]

        case "project.delete":
            let project = try resolveProject(payload)
            try FileManager.default.trashItem(at: project.packageURL, resultingItemURL: nil)
            return ["deleted": project.id]

        case "project.import":
            let project = try resolveProject(payload)
            let path = try string(payload, "path")
            let source = try project.importMedia(from: URL(fileURLWithPath: path))
            return ["source": try encode(source)]

        case "project.addTrack":
            let project = try resolveProject(payload)
            let kind = TrackKind(rawValue: payload["kind"] as? String ?? "audio") ?? .audio
            let name = payload["name"] as? String ?? kind.rawValue.capitalized
            var newID = UUID()
            let document = try project.update { document in
                let track = Track(kind: kind, name: name)
                newID = track.id
                document.tracks.append(track)
            }
            return ["track": newID.uuidString, "tracks": document.tracks.map(describe)]

        case "project.setLook":
            let project = try resolveProject(payload)
            let look = try lookOverride(payload["look"])
            let document = try project.update { document in
                document.defaultLook = look.applied(to: document.defaultLook)
            }
            return ["defaultLook": try encode(document.defaultLook)]

        case "timeline.addClip":
            let project = try resolveProject(payload)
            var clipID = UUID()
            let document = try project.update { document in
                var clip = try makeClip(payload, document: document, project: project)
                clipID = clip.id
                let trackID = try resolveTrack(payload, document: document, preferring: defaultKind(for: clip.source))
                let start = payload["start"] as? Double
                clip.start = start ?? (document.track(id: trackID)?.end ?? 0)
                document.add(clip, toTrack: trackID, at: clip.start)
            }
            return ["clip": clipID.uuidString, "duration": document.duration,
                    "document": try encodeDocument(document)]

        case "timeline.addText":
            let project = try resolveProject(payload)
            var clipID = UUID()
            let document = try project.update { document in
                let trackID = try resolveTrack(payload, document: document, preferring: .overlay)
                var clip = TimelineClip(source: .text, start: payload["start"] as? Double ?? 0,
                                        sourceIn: 0, sourceOut: payload["duration"] as? Double ?? 3,
                                        name: "Text")
                clip.text = TextOverlay(
                    string: (payload["text"] as? String) ?? "Text",
                    fontSize: payload["fontSize"] as? Double ?? 0.07,
                    x: payload["x"] as? Double ?? 0.5,
                    y: payload["y"] as? Double ?? 0.5,
                    pill: payload["pill"] as? Bool ?? false
                )
                clip.fadeIn = payload["fadeIn"] as? Double ?? 0.3
                clip.fadeOut = payload["fadeOut"] as? Double ?? 0.3
                clipID = clip.id
                document.add(clip, toTrack: trackID, at: clip.start)
            }
            return ["clip": clipID.uuidString, "duration": document.duration]

        case "timeline.split":
            let project = try resolveProject(payload)
            let clipID = try uuid(payload, "clip")
            let at = try double(payload, "at")
            var newID: UUID?
            _ = try project.update { document in newID = document.split(clipID: clipID, at: at) }
            guard let newID else { throw CLIError(message: "cannot split there (outside the clip)") }
            return ["newClip": newID.uuidString]

        case "timeline.trim":
            let project = try resolveProject(payload)
            let clipID = try uuid(payload, "clip")
            let document = try project.update { document in
                document.trim(clipID: clipID, sourceIn: payload["sourceIn"] as? Double,
                              sourceOut: payload["sourceOut"] as? Double)
            }
            return ["clip": try encodeClip(document, clipID)]

        case "timeline.setSpeed":
            let project = try resolveProject(payload)
            let clipID = try uuid(payload, "clip")
            let speed = try double(payload, "speed")
            let document = try project.update { $0.setSpeed(clipID: clipID, speed: speed) }
            return ["clip": try encodeClip(document, clipID), "duration": document.duration]

        case "timeline.move":
            let project = try resolveProject(payload)
            let clipID = try uuid(payload, "clip")
            let start = try double(payload, "start")
            let document = try project.update { document in
                let trackID = (payload["track"] as? String).flatMap(UUID.init(uuidString:))
                document.move(clipID: clipID, to: start, trackID: trackID)
            }
            return ["clip": try encodeClip(document, clipID), "duration": document.duration]

        case "timeline.delete":
            let project = try resolveProject(payload)
            let clipID = try uuid(payload, "clip")
            let ripple = payload["ripple"] as? Bool ?? false
            let document = try project.update { document in
                if ripple { document.rippleDelete(clipID: clipID) } else { document.remove(clipID: clipID) }
            }
            return ["deleted": clipID.uuidString, "duration": document.duration]

        case "timeline.compact":
            let project = try resolveProject(payload)
            let document = try project.update { document in
                let trackID = try? resolveTrack(payload, document: document, preferring: .main)
                if let trackID { document.compact(trackID: trackID) }
            }
            return ["duration": document.duration]

        case "timeline.setClip":
            let project = try resolveProject(payload)
            let clipID = try uuid(payload, "clip")
            let document = try project.update { document in
                guard let ti = document.trackIndex(containingClip: clipID),
                      let ci = document.tracks[ti].clips.firstIndex(where: { $0.id == clipID }) else { return }
                var clip = document.tracks[ti].clips[ci]
                if let v = payload["volume"] as? Double { clip.volume = max(0, min(v, 2)) }
                if let v = payload["fadeIn"] as? Double { clip.fadeIn = max(0, v) }
                if let v = payload["fadeOut"] as? Double { clip.fadeOut = max(0, v) }
                if let v = payload["name"] as? String { clip.name = v }
                if let t = payload["transform"] as? [String: Any] {
                    if let v = t["centerX"] as? Double { clip.transform.centerX = v }
                    if let v = t["centerY"] as? Double { clip.transform.centerY = v }
                    if let v = t["scale"] as? Double { clip.transform.scale = v }
                    if let v = t["opacity"] as? Double { clip.transform.opacity = v }
                    if let v = t["circular"] as? Bool { clip.transform.circular = v }
                }
                if let k = payload["kenBurns"] as? [String: Any] {
                    var ken = clip.kenBurns ?? KenBurns()
                    if let v = k["startScale"] as? Double { ken.startScale = v }
                    if let v = k["endScale"] as? Double { ken.endScale = v }
                    if let v = k["startX"] as? Double { ken.startX = v }
                    if let v = k["startY"] as? Double { ken.startY = v }
                    if let v = k["endX"] as? Double { ken.endX = v }
                    if let v = k["endY"] as? Double { ken.endY = v }
                    clip.kenBurns = ken
                } else if payload["kenBurns"] is NSNull {
                    clip.kenBurns = nil
                }
                if let t = payload["text"] as? [String: Any] {
                    var text = clip.text ?? TextOverlay(string: "")
                    if let v = t["string"] as? String { text.string = v }
                    if let v = t["fontSize"] as? Double { text.fontSize = v }
                    if let v = t["x"] as? Double { text.x = v }
                    if let v = t["y"] as? Double { text.y = v }
                    if let v = t["pill"] as? Bool { text.pill = v }
                    clip.text = text
                }
                document.tracks[ti].clips[ci] = clip
            }
            return ["clip": try encodeClip(document, clipID)]

        case "clip.setLook":
            let project = try resolveProject(payload)
            let clipID = try uuid(payload, "clip")
            let look = try lookOverride(payload["look"])
            let document = try project.update { document in
                guard let ti = document.trackIndex(containingClip: clipID),
                      let ci = document.tracks[ti].clips.firstIndex(where: { $0.id == clipID }) else { return }
                document.tracks[ti].clips[ci].look = look
            }
            return ["clip": try encodeClip(document, clipID)]

        case "project.applyLookToAll":
            // Promote a look to the project default and clear every per-clip override, so
            // one zoom / cursor / background treatment applies to the whole video.
            let project = try resolveProject(payload)
            let sourceClip = (payload["clip"] as? String).flatMap(UUID.init(uuidString:))
            let override = try lookOverride(payload["look"])
            let document = try project.update { document in
                var base = document.defaultLook
                if let sourceClip, let clip = document.clip(id: sourceClip), let look = clip.look {
                    base = look.applied(to: base)
                }
                base = override.applied(to: base)
                base.outputWidth = document.canvas.width
                base.outputHeight = document.canvas.height
                base.aspect = document.canvas.aspect
                document.defaultLook = base
                for ti in document.tracks.indices {
                    for ci in document.tracks[ti].clips.indices {
                        document.tracks[ti].clips[ci].look = nil
                    }
                }
            }
            return ["defaultLook": try encode(document.defaultLook),
                    "clipsCleared": document.tracks.reduce(0) { $0 + $1.clips.count }]

        case "clip.copySettings":
            // Copies look, volume, fades, placement and Ken Burns from one clip to others.
            // Speed is opt-in: it is a per-clip editorial choice, and stamping it onto
            // every clip silently changes the length of the whole video.
            let project = try resolveProject(payload)
            let from = try uuid(payload, "from")
            let toAll = payload["all"] as? Bool ?? false
            let targets = (payload["to"] as? [String])?.compactMap(UUID.init(uuidString:)) ?? []
            guard toAll || !targets.isEmpty else {
                throw CLIError(message: "need 'to' (array of clip ids) or 'all': true")
            }
            let includeSpeed = payload["includeSpeed"] as? Bool ?? false
            var applied = 0
            let document = try project.update { document in
                guard let source = document.clip(id: from) else { return }
                for ti in document.tracks.indices {
                    for ci in document.tracks[ti].clips.indices {
                        let clip = document.tracks[ti].clips[ci]
                        guard clip.id != from, toAll || targets.contains(clip.id) else { continue }
                        document.tracks[ti].clips[ci].look = source.look
                        if includeSpeed { document.tracks[ti].clips[ci].speed = source.speed }
                        document.tracks[ti].clips[ci].volume = source.volume
                        document.tracks[ti].clips[ci].fadeIn = source.fadeIn
                        document.tracks[ti].clips[ci].fadeOut = source.fadeOut
                        document.tracks[ti].clips[ci].transform = source.transform
                        document.tracks[ti].clips[ci].kenBurns = source.kenBurns
                        applied += 1
                    }
                }
            }
            return ["applied": applied, "duration": document.duration]

        case "project.export":
            let project = try resolveProject(payload)
            let document = try project.read()
            let format = ExportFormat(rawValue: (payload["format"] as? String ?? "mp4").lowercased()) ?? .mp4
            let preset = ExportPreset(rawValue: payload["preset"] as? String ?? "1080p") ?? .fullHD
            let output: URL
            if let path = payload["path"] as? String {
                var url = URL(fileURLWithPath: path)
                if url.pathExtension.lowercased() != format.fileExtension {
                    url = url.deletingPathExtension().appendingPathExtension(format.fileExtension)
                }
                output = url
            } else {
                try? FileManager.default.createDirectory(at: project.rendersDirectory, withIntermediateDirectories: true)
                output = project.rendersDirectory
                    .appendingPathComponent(project.name)
                    .appendingPathExtension(format.fileExtension)
            }
            try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            if format.isGIF {
                try await VideoExporter.exportTimelineGIF(project: project, document: document,
                                                          frameRate: format.gifFrameRate, to: output) { _ in }
            } else {
                let size = preset.outputSize(canvasWidth: document.canvas.width, canvasHeight: document.canvas.height)
                try await VideoExporter.exportTimeline(project: project, document: document,
                                                       size: (size.width, size.height), format: format,
                                                       to: output) { _ in }
            }
            return ["path": output.path, "format": format.rawValue,
                    "preset": preset.rawValue, "duration": document.duration]

        case "project.renderFrame":
            let project = try resolveProject(payload)
            let document = try project.read()
            let at = payload["at"] as? Double ?? 0
            let output = URL(fileURLWithPath: payload["path"] as? String
                             ?? project.rendersDirectory.appendingPathComponent("frame.png").path)
            try await renderFrame(project: project, document: document, at: at, to: output)
            return ["path": output.path]

        default:
            throw CLIError(message: "unknown verb '\(verb)'; known: \(verbs.joined(separator: ", "))")
        }
    }

    // MARK: Frame rendering

    @concurrent
    private static func renderFrame(project: EditProject, document: EditDocument, at seconds: Double, to output: URL) async throws {
        let built = try await TimelineCompositionBuilder.build(project: project, document: document)
        let generator = AVAssetImageGenerator(asset: built.asset)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: document.canvas.width, height: document.canvas.height)
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CLIError(message: "cannot write \(output.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CLIError(message: "cannot finalize \(output.path)")
        }
    }

    // MARK: Payload helpers

    private static func readPayload(_ args: [String]) throws -> [String: Any] {
        guard let index = args.firstIndex(of: "--json"), index + 1 < args.count else { return [:] }
        let raw = args[index + 1]
        let text: String
        if raw == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            text = String(data: data, encoding: .utf8) ?? "{}"
        } else {
            text = raw
        }
        guard let data = text.data(using: .utf8) else { throw CLIError(message: "payload is not UTF-8") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError(message: "payload must be a JSON object")
        }
        return object
    }

    private static func string(_ payload: [String: Any], _ key: String) throws -> String {
        guard let value = payload[key] as? String, !value.isEmpty else {
            throw CLIError(message: "missing required string '\(key)'")
        }
        return value
    }

    private static func double(_ payload: [String: Any], _ key: String) throws -> Double {
        if let v = payload[key] as? Double { return v }
        if let v = payload[key] as? Int { return Double(v) }
        throw CLIError(message: "missing required number '\(key)'")
    }

    private static func uuid(_ payload: [String: Any], _ key: String) throws -> UUID {
        guard let value = UUID(uuidString: try string(payload, key)) else {
            throw CLIError(message: "'\(key)' must be a UUID")
        }
        return value
    }

    /// Accepts a project id (`Name.mdsproj`), a bare name, or an absolute path.
    private static func resolveProject(_ payload: [String: Any]) throws -> EditProject {
        let reference = try string(payload, "project")
        if reference.hasPrefix("/") {
            let project = EditProject(packageURL: URL(fileURLWithPath: reference))
            guard project.exists else { throw CLIError(message: "no project at \(reference)") }
            return project
        }
        let all = ProjectLibrary.all()
        if let match = all.first(where: { $0.id == reference || $0.name == reference }) { return match }
        throw CLIError(message: "no such project '\(reference)'; have: \(all.map(\.name).joined(separator: ", "))")
    }

    private static func resolveTrack(_ payload: [String: Any], document: EditDocument, preferring kind: TrackKind) throws -> UUID {
        if let raw = payload["track"] as? String {
            if let id = UUID(uuidString: raw), document.track(id: id) != nil { return id }
            if let named = document.tracks.first(where: { $0.name.caseInsensitiveCompare(raw) == .orderedSame }) {
                return named.id
            }
            throw CLIError(message: "no such track '\(raw)'")
        }
        guard let track = document.tracks.first(where: { $0.kind == kind }) ?? document.tracks.first else {
            throw CLIError(message: "project has no tracks")
        }
        return track.id
    }

    private static func defaultKind(for source: MediaSource) -> TrackKind {
        switch source {
        case .recording: return .main
        case .text: return .overlay
        case .file(_, let kind): return kind == .audio ? .audio : .main
        }
    }

    /// Builds a clip from `{clip: "<library id>"}` or `{source: {...}}`, defaulting the
    /// source window to the media's full length.
    private static func makeClip(_ payload: [String: Any], document: EditDocument, project: EditProject) throws -> TimelineClip {
        var source: MediaSource
        var naturalDuration: Double
        var name = payload["name"] as? String ?? ""

        if let libraryID = payload["clip"] as? String {
            guard let libraryClip = ClipLibrary.clip(id: libraryID) else {
                throw CLIError(message: "no such library clip '\(libraryID)'")
            }
            source = libraryClip.source
            naturalDuration = libraryClip.duration
            if name.isEmpty { name = libraryClip.name }
        } else if let path = payload["path"] as? String {
            // A file on disk: import it into the project, then reference the copy.
            source = try project.importMedia(from: URL(fileURLWithPath: path))
            naturalDuration = mediaDuration(project: project, source: source)
            if name.isEmpty { name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
        } else if let media = payload["media"] as? String {
            // Already inside the project's Media/ folder.
            let url = project.mediaDirectory.appendingPathComponent(media)
            source = .file(path: media, kind: MediaKind.infer(from: url))
            naturalDuration = mediaDuration(project: project, source: source)
            if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
        } else {
            throw CLIError(message: "need one of 'clip' (library id), 'path' (file to import) or 'media'")
        }

        let sourceIn = payload["sourceIn"] as? Double ?? 0
        let sourceOut = payload["sourceOut"] as? Double ?? max(naturalDuration, sourceIn + 1)
        var clip = TimelineClip(source: source, start: payload["start"] as? Double ?? 0,
                                sourceIn: sourceIn, sourceOut: sourceOut, name: name)
        clip.speed = payload["speed"] as? Double ?? 1
        clip.volume = payload["volume"] as? Double ?? 1
        clip.fadeIn = payload["fadeIn"] as? Double ?? 0
        clip.fadeOut = payload["fadeOut"] as? Double ?? 0
        if case .file(_, let kind) = source, kind == .image {
            // Stills have no intrinsic length; default to a readable 4 seconds.
            if payload["sourceOut"] == nil { clip.sourceOut = clip.sourceIn + 4 }
            clip.kenBurns = KenBurns()
        }
        if defaultKind(for: source) == .overlay || (payload["overlay"] as? Bool == true) {
            clip.transform = .bubbleBottomLeading
        }
        return clip
    }

    private static func mediaDuration(project: EditProject, source: MediaSource) -> Double {
        guard let url = project.url(for: source) else { return 4 }
        if case .file(_, let kind) = source, kind == .image { return 4 }
        let duration = CMTimeGetSeconds(AVURLAsset(url: url).duration)
        return duration.isFinite && duration > 0 ? duration : 4
    }

    private static func lookOverride(_ raw: Any?) throws -> LookOverride {
        guard let dictionary = raw as? [String: Any] else { return LookOverride() }
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        return try JSONDecoder().decode(LookOverride.self, from: data)
    }

    // MARK: Encoding

    private static func describe(_ clip: LibraryClip) -> [String: Any] {
        [
            "id": clip.id, "name": clip.name, "duration": clip.duration,
            "width": clip.pixelWidth, "height": clip.pixelHeight,
            "hasCamera": clip.hasCamera, "hasEvents": clip.hasEvents,
            "path": clip.packageURL.path
        ]
    }

    private static func describe(_ track: Track) -> [String: Any] {
        ["id": track.id.uuidString, "kind": track.kind.rawValue, "name": track.name,
         "muted": track.muted, "hidden": track.hidden, "volume": track.volume,
         "clips": track.clips.count, "end": track.end]
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func encodeDocument(_ document: EditDocument) throws -> Any {
        try encode(document)
    }

    private static func encodeClip(_ document: EditDocument, _ id: UUID) throws -> Any {
        guard let clip = document.clip(id: id) else { throw CLIError(message: "no such clip \(id)") }
        return try encode(clip)
    }

    private static func emit(_ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"error":"could not encode result"}"#.utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
