import Foundation

/// Speaks the Model Context Protocol over stdio, so **any** MCP-capable agent can drive
/// MyDemoStudio: `MyDemoStudio.app/Contents/MacOS/MyDemoStudio --mcp`.
///
/// Serving the protocol from the app itself — rather than from a Node adapter — means an
/// agent needs nothing installed beyond the app: no runtime, no package manager, no
/// checkout of this repo. Every tool forwards to the same `MDSCLI` verbs the app's own
/// editor uses, so the two can't drift apart.
enum MDSMCPServer {

    static var isMCP: Bool { CommandLine.arguments.contains("--mcp") }

    private static let protocolVersion = "2024-11-05"

    // MARK: Run loop

    static func run() async -> Never {
        // Requests are handled one at a time: every verb is a read-modify-write of the
        // project document, so serialising them keeps concurrent tool calls safe.
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            await handle(message)
        }
        exit(0)
    }

    private static func handle(_ message: [String: Any]) async {
        let method = message["method"] as? String ?? ""
        let id = message["id"]

        // Notifications carry no id and must never be answered.
        guard id != nil else { return }

        switch method {
        case "initialize":
            respond(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "mydemostudio", "version": appVersion]
            ])

        case "ping":
            respond(id: id, result: [:])

        case "tools/list":
            respond(id: id, result: ["tools": tools.map(\.schema)])

        case "tools/call":
            let params = message["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let tool = tools.first(where: { $0.name == name }) else {
                respond(id: id, error: -32602, message: "unknown tool '\(name)'")
                return
            }
            do {
                var result = try await MDSCLI.dispatch(verb: tool.verb, payload: arguments)
                result["ok"] = true
                respond(id: id, result: content(result, isError: false))
            } catch let error as MDSCLI.CLIError {
                respond(id: id, result: content(["ok": false, "error": error.message], isError: true))
            } catch {
                respond(id: id, result: content(["ok": false, "error": "\(error)"], isError: true))
            }

        default:
            respond(id: id, error: -32601, message: "method not found: \(method)")
        }
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    // MARK: Encoding

    private static func content(_ payload: [String: Any], isError: Bool) -> [String: Any] {
        let text = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private static func respond(id: Any?, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private static func respond(id: Any?, error code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    // MARK: Tool catalogue

    private struct Tool {
        let name: String
        let verb: String
        let description: String
        let required: [String]
        let properties: [String: [String: Any]]

        var schema: [String: Any] {
            [
                "name": name,
                "description": description,
                "inputSchema": [
                    "type": "object",
                    "properties": properties,
                    "required": required
                ] as [String: Any]
            ]
        }
    }

    private static func str(_ description: String, _ options: [String]? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "string", "description": description]
        if let options { schema["enum"] = options }
        return schema
    }
    private static func num(_ description: String) -> [String: Any] {
        ["type": "number", "description": description]
    }
    private static func flag(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }
    private static func object(_ description: String) -> [String: Any] {
        ["type": "object", "description": description]
    }

    private static var projectArg: [String: Any] { str("Project name, id ('X.mdsproj') or absolute path") }
    private static var clipArg: [String: Any] { str("Clip UUID from the timeline (see project_get)") }
    private static var trackArg: [String: Any] { str("Track UUID or name; defaults to a sensible track for the media kind") }
    private static var lookArg: [String: Any] { object(
        "Look settings — background, paddingFraction, cornerRadiusFraction, shadowOpacity, "
        + "zoomEnabled, zoomScale, cursorStyle (arrow|hand|handOnClick), cursorScale, "
        + "cursorSmoothing, sfxEnabled, sfxVolume, captionsEnabled. Omitted fields inherit.") }

    private static var tools: [Tool] { [
        Tool(name: "clips_list", verb: "clips.list",
             description: "List every screen recording in the clip library (reusable across projects).",
             required: [], properties: [:]),
        Tool(name: "clips_info", verb: "clips.info",
             description: "Details for one library recording.",
             required: ["id"], properties: ["id": str("Library recording id")]),
        Tool(name: "clips_rename", verb: "clips.rename",
             description: "Rename a recording. Only the displayed name changes — the package keeps its id, so projects using the clip keep working. An empty name restores the original.",
             required: ["id", "name"], properties: ["id": str("Library recording id"), "name": str("New name")]),

        Tool(name: "projects_list", verb: "projects.list",
             description: "List all edit projects.", required: [], properties: [:]),
        Tool(name: "project_create", verb: "project.create",
             description: "Create an empty edit project with Video / Overlays / Voiceover / Music tracks.",
             required: ["name"],
             properties: ["name": str("Project name"),
                          "aspect": str("Canvas shape", ["wide", "vertical", "square", "original"]),
                          "fps": num("Frames per second (default 60)")]),
        Tool(name: "project_get", verb: "project.get",
             description: "Full edit document: tracks, clips, timings, look. Start here to find clip UUIDs.",
             required: ["project"], properties: ["project": projectArg]),
        Tool(name: "project_delete", verb: "project.delete",
             description: "Move a project to the Trash. Source recordings are never touched.",
             required: ["project"], properties: ["project": projectArg]),
        Tool(name: "project_import", verb: "project.import",
             description: "Copy an external video/image/audio file into the project's Media folder.",
             required: ["project", "path"],
             properties: ["project": projectArg, "path": str("Absolute path to the file")]),
        Tool(name: "project_set_look", verb: "project.setLook",
             description: "Change the project-wide default look.",
             required: ["project", "look"], properties: ["project": projectArg, "look": lookArg]),
        Tool(name: "project_add_track", verb: "project.addTrack",
             description: "Add a track (lane) to the timeline.",
             required: ["project", "kind"],
             properties: ["project": projectArg,
                          "kind": str("Track kind", ["main", "overlay", "audio"]),
                          "name": str("Track name")]),

        Tool(name: "timeline_add_clip", verb: "timeline.addClip",
             description: "Place media on the timeline. Give exactly one of: clip (library recording id), path (file to import), media (file already in the project).",
             required: ["project"],
             properties: ["project": projectArg,
                          "clip": str("Library recording id from clips_list"),
                          "path": str("Absolute path of a file to import and place"),
                          "media": str("Filename already inside the project's Media folder"),
                          "track": trackArg,
                          "start": num("Timeline position in seconds; defaults to the end of the track"),
                          "sourceIn": num("Trim: start offset inside the source, seconds"),
                          "sourceOut": num("Trim: end offset inside the source, seconds"),
                          "speed": num("1 = normal, 2 = twice as fast (halves the timeline length)"),
                          "volume": num("0…1.5"),
                          "fadeIn": num("Seconds"), "fadeOut": num("Seconds"),
                          "name": str("Clip name"),
                          "overlay": flag("Place as a picture-in-picture overlay (webcam bubble style)")]),
        Tool(name: "timeline_add_text", verb: "timeline.addText",
             description: "Add a text card / title on an overlay track.",
             required: ["project", "text"],
             properties: ["project": projectArg, "text": str("The text to show"),
                          "start": num("Timeline seconds"), "duration": num("Seconds on screen"),
                          "x": num("0…1 across the canvas, 0.5 = centre"),
                          "y": num("0…1 down the canvas, 0.5 = centre"),
                          "fontSize": num("Fraction of canvas height, e.g. 0.07"),
                          "pill": flag("Dark rounded background behind the text"),
                          "fadeIn": num("Seconds"), "fadeOut": num("Seconds"), "track": trackArg]),
        Tool(name: "timeline_split", verb: "timeline.split",
             description: "Cut a clip in two at a timeline instant.",
             required: ["project", "clip", "at"],
             properties: ["project": projectArg, "clip": clipArg, "at": num("Timeline seconds")]),
        Tool(name: "timeline_trim", verb: "timeline.trim",
             description: "Retrim a clip's source window (seconds inside the source media).",
             required: ["project", "clip"],
             properties: ["project": projectArg, "clip": clipArg,
                          "sourceIn": num("Seconds"), "sourceOut": num("Seconds")]),
        Tool(name: "timeline_set_speed", verb: "timeline.setSpeed",
             description: "Speed a clip up or slow it down. 2 = twice as fast.",
             required: ["project", "clip", "speed"],
             properties: ["project": projectArg, "clip": clipArg, "speed": num("0.1…10")]),
        Tool(name: "timeline_move", verb: "timeline.move",
             description: "Move a clip to a new start time, optionally to another track.",
             required: ["project", "clip", "start"],
             properties: ["project": projectArg, "clip": clipArg,
                          "start": num("Timeline seconds"), "track": trackArg]),
        Tool(name: "timeline_delete", verb: "timeline.delete",
             description: "Remove a clip. With ripple, later clips on that track slide left to close the gap.",
             required: ["project", "clip"],
             properties: ["project": projectArg, "clip": clipArg, "ripple": flag("Close the gap")]),
        Tool(name: "timeline_compact", verb: "timeline.compact",
             description: "Remove all gaps on a track so its clips play back to back.",
             required: ["project"], properties: ["project": projectArg, "track": trackArg]),
        Tool(name: "timeline_set_clip", verb: "timeline.setClip",
             description: "Set a clip's volume, fades, name, on-screen transform, Ken Burns move, or text.",
             required: ["project", "clip"],
             properties: ["project": projectArg, "clip": clipArg,
                          "volume": num("0…2"), "fadeIn": num("Seconds"), "fadeOut": num("Seconds"),
                          "name": str("Clip name"),
                          "transform": object("centerX, centerY, scale, opacity, circular — overlay placement, normalized to the canvas"),
                          "kenBurns": object("startScale, endScale, startX, startY, endX, endY — slow pan/zoom for stills"),
                          "text": object("string, fontSize, x, y, pill")]),
        Tool(name: "clip_set_look", verb: "clip.setLook",
             description: "Override the look for one clip.",
             required: ["project", "clip", "look"],
             properties: ["project": projectArg, "clip": clipArg, "look": lookArg]),
        Tool(name: "project_apply_look_to_all", verb: "project.applyLookToAll",
             description: "Apply one look to the whole video: make it the project default and clear every per-clip override. Pass 'clip' to adopt that clip's look, and/or 'look' to set fields directly.",
             required: ["project"],
             properties: ["project": projectArg,
                          "clip": str("Clip whose look becomes the project default"),
                          "look": lookArg]),
        Tool(name: "clip_copy_settings", verb: "clip.copySettings",
             description: "Copy look, volume, fades, placement and Ken Burns from one clip onto others. Give 'to' (clip ids) or 'all'. Source, position and trim are never copied; speed only with includeSpeed.",
             required: ["project", "from"],
             properties: ["project": projectArg, "from": clipArg,
                          "to": ["type": "array", "items": ["type": "string"],
                                 "description": "Target clip ids"] as [String: Any],
                          "all": flag("Apply to every other clip"),
                          "includeSpeed": flag("Also copy the playback speed")]),

        Tool(name: "project_export", verb: "project.export",
             description: "Render the project to a video. Returns the output path.",
             required: ["project"],
             properties: ["project": projectArg,
                          "format": str("Container; defaults to mp4", ["mp4", "mov", "gif"]),
                          "preset": str("Resolution; defaults to 1080p", ["4K", "1080p", "720p"]),
                          "path": str("Destination file; defaults to the project's Renders folder")]),
        Tool(name: "project_render_frame", verb: "project.renderFrame",
             description: "Render a single frame to a PNG — the quickest way to see what the timeline looks like.",
             required: ["project", "at"],
             properties: ["project": projectArg, "at": num("Timeline seconds"),
                          "path": str("Destination PNG")])
    ] }

    /// Tool count, for the setup UI.
    static var toolCount: Int { tools.count }
}
