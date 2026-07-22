# Agents and the CLI

MyDemoStudio **is** an MCP server. The app binary speaks the Model Context Protocol over
stdio when you launch it with `--mcp`, so any MCP-capable agent can drive it with nothing
else installed — no runtime, no package manager, no checkout of this repo.

The same verbs are also available as one-shot CLI subcommands, which is what shell
scripts and CI should use.

## Connect a client

In the app, **Connect an AI agent** (sidebar, or `⇧⌘M`) shows the config for each client
with the real binary path already filled in, plus a button to copy it. What follows is the
same thing, written out.

The binary is at `/Applications/MyDemoStudio.app/Contents/MacOS/MyDemoStudio` if you
installed it there.

### Claude Code, Claude Desktop, Cursor, Windsurf

```json
{
  "mcpServers": {
    "mydemostudio": {
      "command": "/Applications/MyDemoStudio.app/Contents/MacOS/MyDemoStudio",
      "args": ["--mcp"]
    }
  }
}
```

| Client | Config file |
| --- | --- |
| Claude Code | `<your project>/.mcp.json`, or `claude mcp add mydemostudio -- "<binary>" --mcp` to register it everywhere |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` — quit and reopen afterwards |
| Cursor | `~/.cursor/mcp.json`, or `.cursor/mcp.json` inside a project |
| Windsurf | `~/.codeium/windsurf/mcp_config.json` — reload, then refresh the MCP list in Cascade |

### VS Code

Nests servers under `servers` and wants an explicit type. Put this in
`<your project>/.vscode/mcp.json`, start the server from the ▶ button that appears above
the entry, then use Agent mode.

```json
{
  "servers": {
    "mydemostudio": {
      "type": "stdio",
      "command": "/Applications/MyDemoStudio.app/Contents/MacOS/MyDemoStudio",
      "args": ["--mcp"]
    }
  }
}
```

### Codex

Configures MCP in TOML. Add to `~/.codex/config.toml`, then run `/mcp` inside Codex to
check it connected.

```toml
[mcp_servers.mydemostudio]
command = "/Applications/MyDemoStudio.app/Contents/MacOS/MyDemoStudio"
args = ["--mcp"]
```

Any other client that supports MCP over stdio works too. If it asks for a command and
arguments rather than JSON, the command is the binary path and the argument is `--mcp`.

## The tools

24 of them. Every tool `x_y` is also the CLI verb `x.y`.

### Clips — the recording library

| Tool | Does |
| --- | --- |
| `clips_list` | List every screen recording, reusable across projects |
| `clips_info` | Details for one recording |
| `clips_rename` | Rename a recording. Only the displayed name changes — the package keeps its id, so projects keep working. An empty name restores the original |

### Projects

| Tool | Does |
| --- | --- |
| `projects_list` | List all edit projects |
| `project_create` | Create an empty project with Video / Overlays / Voiceover / Music tracks |
| `project_get` | The full edit document: tracks, clips, timings, look. **Start here** — it is where clip UUIDs come from |
| `project_delete` | Move a project to the Trash. Source recordings are never touched |
| `project_import` | Copy an external video / image / audio file into the project's Media folder |
| `project_add_track` | Add a lane to the timeline |

### Timeline

| Tool | Does |
| --- | --- |
| `timeline_add_clip` | Place media. Give exactly one of `clip` (library id), `path` (file to import) or `media` (file already in the project) |
| `timeline_add_text` | Add a text card on an overlay track |
| `timeline_split` | Cut a clip in two at a timeline instant |
| `timeline_trim` | Retrim a clip's source window, in seconds inside the source media |
| `timeline_set_speed` | Speed up or slow down. `2` = twice as fast |
| `timeline_move` | New start time, optionally on another track |
| `timeline_delete` | Remove a clip. With `ripple`, later clips slide left to close the gap |
| `timeline_compact` | Remove all gaps on a track |
| `timeline_set_clip` | Volume, fades, name, on-screen transform, Ken Burns move, or text |

### Look

| Tool | Does |
| --- | --- |
| `project_set_look` | Change the project-wide default |
| `clip_set_look` | Override the look for one clip |
| `project_apply_look_to_all` | Make one look the project default *and* clear every per-clip override. Pass `clip` to adopt that clip's look, and/or `look` to set fields directly |
| `clip_copy_settings` | Copy look, volume, fades, placement and Ken Burns from one clip onto others. Source, position and trim are never copied; speed only with `includeSpeed` |

### Output

| Tool | Does |
| --- | --- |
| `project_export` | Render to a video. Returns the output path |
| `project_render_frame` | Render one frame to a PNG |

## Working with it

**It edits live.** The app watches the project's `document.json`, so an agent's changes
appear in an open project without a reload.

**Render a frame, then look at it.** `project_render_frame` is the fastest feedback loop
available — far quicker than an export, and an agent can inspect the PNG it produces.

A good first prompt, once connected:

> Add a title saying "Kosmico" for the first 3 seconds, then show me frame 4.

## The CLI

```sh
MyDemoStudio --cli clips.list --json '{}'

MyDemoStudio --cli project.get --json '{"project":"Demo"}'

MyDemoStudio --cli timeline.setSpeed \
  --json '{"project":"Demo","clip":"<uuid>","speed":2}'

MyDemoStudio --cli project.export \
  --json '{"project":"Demo","format":"mp4","preset":"1080p"}'
```

Arguments are the same JSON object the MCP tool takes, and the result is JSON on stdout.

## The old Node bridge

`mcp/` holds an earlier Node server that shelled out to the CLI. It still works, but the
native server above supersedes it and needs no dependencies. There is no reason to use it
in new setups.

---

Next: [architecture](architecture.md).
