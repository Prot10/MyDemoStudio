import SwiftUI
import AppKit

/// One MCP-capable agent, and what it needs in order to talk to MyDemoStudio.
///
/// Every client speaks the same protocol; they differ only in *where* the config lives
/// and, for VS Code, the shape of the JSON (`servers` with an explicit `type`, rather
/// than `mcpServers`).
struct AgentClient: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    /// Where the config file lives, `~` kept for readability.
    let configPath: String
    /// True when the config file is per-project rather than global.
    let isProjectScoped: Bool
    /// Clients agree on the protocol but not on how the server is declared.
    let style: ConfigStyle

    enum ConfigStyle {
        /// The common shape: `{ "mcpServers": { … } }`.
        case mcpServersJSON
        /// VS Code nests servers under `servers` and wants an explicit transport type.
        case serversJSON
        /// Codex configures MCP in TOML, under `[mcp_servers.<name>]`.
        case toml

        var caption: String {
            switch self {
            case .mcpServersJSON: return "JSON"
            case .serversJSON: return "mcp.json"
            case .toml: return "TOML"
            }
        }
    }
    /// A one-line command that registers the server, where the client offers one.
    let command: String?
    let note: String

    static let all: [AgentClient] = [
        AgentClient(
            id: "claude-code", name: "Claude Code", icon: "terminal",
            configPath: "<your project>/.mcp.json", isProjectScoped: true,
            style: .mcpServersJSON,
            command: "claude mcp add mydemostudio -- \"BINARY\" --mcp",
            note: "The command registers it for every project. For one project only, save the JSON as .mcp.json in the project root — Claude Code asks you to approve it on next launch."),
        AgentClient(
            id: "claude-desktop", name: "Claude Desktop", icon: "bubble.left.and.text.bubble.right",
            configPath: "~/Library/Application Support/Claude/claude_desktop_config.json",
            isProjectScoped: false, style: .mcpServersJSON, command: nil,
            note: "Quit and reopen Claude Desktop afterwards. The tools appear under the connectors icon in the composer."),
        AgentClient(
            id: "codex", name: "Codex", icon: "curlybraces",
            configPath: "~/.codex/config.toml", isProjectScoped: false,
            style: .toml,
            command: "codex mcp add mydemostudio -- \"BINARY\" --mcp",
            note: "Codex configures MCP in TOML, not JSON. Scope it to one project with .codex/config.toml instead (trusted projects only). Run /mcp inside Codex to check it connected."),
        AgentClient(
            id: "cursor", name: "Cursor", icon: "cursorarrow.rays",
            configPath: "~/.cursor/mcp.json", isProjectScoped: false, style: .mcpServersJSON,
            command: nil,
            note: "Use .cursor/mcp.json inside a project instead if you'd rather scope it to one workspace."),
        AgentClient(
            id: "vscode", name: "VS Code", icon: "chevron.left.forwardslash.chevron.right",
            configPath: "<your project>/.vscode/mcp.json", isProjectScoped: true,
            style: .serversJSON, command: nil,
            note: "VS Code nests servers under \"servers\" and wants an explicit \"type\". Start the server from the ▶ button that appears above the entry, then use Agent mode."),
        AgentClient(
            id: "windsurf", name: "Windsurf", icon: "wind",
            configPath: "~/.codeium/windsurf/mcp_config.json", isProjectScoped: false,
            style: .mcpServersJSON, command: nil,
            note: "Reload Windsurf, then refresh the MCP list in Cascade's settings."),
        AgentClient(
            id: "other", name: "Any other agent", icon: "sparkles",
            configPath: "your client's MCP config", isProjectScoped: false,
            style: .mcpServersJSON, command: nil,
            note: "Any client that supports MCP over stdio works. If it asks for a command and arguments rather than JSON, use the command and argument shown above.")
    ]
}

/// Explains how to connect an AI agent to MyDemoStudio, with the exact config for each
/// client — paths already filled in and one click to copy.
struct MCPSetupView: View {
    @State private var selection: AgentClient = AgentClient.all.first {
        $0.id == ProcessInfo.processInfo.environment["MDS_MCP_CLIENT"]
    } ?? AgentClient.all[0]
    @State private var copied: String?

    private var binaryPath: String { Bundle.main.executableURL?.path ?? "/Applications/MyDemoStudio.app/Contents/MacOS/MyDemoStudio" }

    var body: some View {
        HSplitView {
            clientList
                .frame(minWidth: 190, idealWidth: 210, maxWidth: 260)
            detail
                .frame(minWidth: 430)
        }
        .frame(minWidth: 680, minHeight: 560)
    }

    // MARK: Clients

    private var clientList: some View {
        List(AgentClient.all, selection: $selection) { client in
            Label(client.name, systemImage: client.icon)
                .tag(client)
        }
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Connect an agent")
                    .font(.headline)
                Text("Let an AI assistant edit your videos.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.bar)
        }
    }

    // MARK: Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statusCard

                step(1, "Add MyDemoStudio to \(selection.name)") {
                    if let command = selection.command {
                        Text("Run this in Terminal:")
                            .font(.callout).foregroundStyle(.secondary)
                        codeBlock(command.replacingOccurrences(of: "BINARY", with: binaryPath), id: "command", caption: "Terminal")
                        Text("— or —").font(.caption).foregroundStyle(.secondary)
                    }

                    Text(selection.id == "other"
                         ? "Point your client at this command:"
                         : "Add this to \(selection.configPath):")
                        .font(.callout).foregroundStyle(.secondary)
                    codeBlock(configSnippet, id: "json", caption: selection.style.caption)

                    if selection.id != "other", !selection.isProjectScoped {
                        Button {
                            revealConfig()
                        } label: {
                            Label("Open the folder that holds this file", systemImage: "folder")
                        }
                        .buttonStyle(.link)
                    }
                }

                step(2, "Restart \(selection.name)") {
                    Text(selection.note)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                step(3, "Ask for what you want") {
                    Text("The agent gets \(MDSMCPServer.toolCount) tools covering the clip library, projects, the timeline, the look, and export.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(examplePrompts, id: \.self) { prompt in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "quote.opening")
                                .font(.caption2).foregroundStyle(.tertiary)
                            Text(prompt).font(.callout).italic()
                        }
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var examplePrompts: [String] {
        [
            "List my recordings and make a vertical project from the newest one.",
            "Trim the first clip to 5–20 seconds and speed the second one to 2×.",
            "Add a title saying “Kosmico” for the first 3 seconds, then show me frame 4.",
            "Apply the first clip's look to every clip and export it as a 1080p MP4."
        ]
    }

    // MARK: Status

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text("Ready to connect")
                    .font(.headline)
                Text("MyDemoStudio speaks MCP itself — there's nothing to install. Any agent that supports MCP over stdio can drive it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(binaryPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Button {
                        copy(binaryPath, id: "binary")
                    } label: {
                        Image(systemName: copied == "binary" ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the path to MyDemoStudio")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
    }

    // MARK: Building blocks

    @ViewBuilder
    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(.tint, in: .circle)
                Text(title).font(.headline)
            }
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(.leading, 28)
        }
    }

    /// A copyable snippet. The copy button lives in its own header row rather than
    /// floating over the code — long lines scroll horizontally, and an overlaid button
    /// would sit on top of the text as it slid underneath.
    private func codeBlock(_ text: String, id: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(caption)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    copy(text, id: id)
                } label: {
                    Label(copied == id ? "Copied" : "Copy",
                          systemImage: copied == id ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(copied == id ? Color.green : Color.accentColor)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)

            Divider().opacity(0.35)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .background(.black.opacity(0.25), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.08)))
    }

    /// The config snippet, with this app's real path already substituted.
    private var configSnippet: String {
        switch selection.style {
        case .serversJSON:
            return """
            {
              "servers": {
                "mydemostudio": {
                  "type": "stdio",
                  "command": "\(binaryPath)",
                  "args": ["--mcp"]
                }
              }
            }
            """
        case .toml:
            return """
            [mcp_servers.mydemostudio]
            command = "\(binaryPath)"
            args = ["--mcp"]
            """
        case .mcpServersJSON:
            return """
            {
              "mcpServers": {
                "mydemostudio": {
                  "command": "\(binaryPath)",
                  "args": ["--mcp"]
                }
              }
            }
            """
        }
    }

    // MARK: Actions

    private func copy(_ text: String, id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copied = id }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { if copied == id { copied = nil } }
        }
    }

    private func revealConfig() {
        let expanded = (selection.configPath as NSString).expandingTildeInPath
        let folder = (expanded as NSString).deletingLastPathComponent
        // The folder may not exist yet for a client that has never been configured.
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(expanded, inFileViewerRootedAtPath: folder)
    }
}
