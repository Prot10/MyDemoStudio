# MyDemoStudio

A native macOS screen recorder that automatically produces polished product‑demo
videos — the kind of "recording on a gradient with smooth auto‑zoom" look, without
a subscription. Built in Swift/SwiftUI for macOS 26.

## Features

- **Record** the whole screen or a single app window (captured via a display crop, so
  window chrome renders normally).
- **Automatic zoom** that follows the cursor — the camera keeps the pointer centered,
  with a smooth fixed‑timestep follow and eased in/out transitions.
- **Smooth cursor** rendered as a real arrow or pointing‑hand sprite (hide‑when‑idle).
- **Polished look**: mesh‑gradient wallpapers, solid/gradient backgrounds, padding,
  rounded corners, drop shadow, and 16:9 / 9:16 / 1:1 / original aspect ratios.
- **Webcam bubble** — a circular camera overlay in any corner.
- **Voiceover** from the microphone, plus optional soft **click / keystroke sound
  effects** mixed into the export.
- **Captions** — on‑device transcription (SpeechAnalyzer) burned into the video.
- **Export** to MP4, MOV or animated GIF at 4K / 1080p / 720p, saved wherever you choose.
- A non‑destructive editor with live preview (the preview uses the same Metal
  compositor as the export).

## Two libraries

- **Clips** — every recording you make, kept as a `.mydemo` package in
  `~/Movies/MyDemoStudio`. Recordings are the originals: projects only ever reference
  them, so nothing is moved or rewritten.
- **Projects** — `.mdsproj` edit documents in `~/Movies/MyDemoStudio/Projects`, each
  assembling clips and imported media into a finished video.

## The editor

A project is a multi‑track timeline. Each clip has a source window (trim), a playback
speed, volume, fades, and an optional per‑clip look that overrides the project defaults —
so one clip can be zoomed and padded while the next is plain.

- **Tracks**: a main picture track, overlay tracks (webcam bubble, titles), and audio tracks.
- **Editing**: drag to move, drag either edge to trim, ⌘B to split at the playhead, speed
  from 0.25× to 4×, ripple delete, and “close gaps”.
- **Media**: screen recordings from the clip library, plus videos, images (with a Ken Burns
  move) and sounds — imported files are *copied into the project*, so it never breaks when
  the original moves.
- **Titles**: text cards on an overlay track, with fades.
- **Webcam and voiceover after the fact**: play the timeline and record a take over it;
  it lands at the playhead as an overlay or audio clip.
- **Reusing settings**: copy a clip's look, volume, fades, placement and Ken Burns and
  paste them onto another (⇧⌘C / ⇧⌘V), or push one clip's look onto *every* clip at once.
  Speed is never copied by default — it changes how long the video is.
- The inspector on the right collapses like the sidebar (⌥⌘I).

Speeding a clip up shortens that clip without moving the ones after it — use “close gaps
on this track” when you want the timeline to tighten up.

## Controlling it from an AI agent (MCP)

MyDemoStudio **is** an MCP server — the app speaks the protocol itself over stdio, so any
MCP-capable agent can drive it with nothing else installed: no runtime, no package
manager, no checkout of this repo.

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

In the app, **Connect an AI agent** (sidebar, or ⇧⌘M) shows this config with the real path
already filled in, per client — Claude Code, Claude Desktop, Codex, Cursor, VS Code, Windsurf —
with the config file location for each and a button to copy it. Two clients differ: VS Code
nests servers under `servers` and wants `"type": "stdio"`, and Codex configures MCP in TOML
(`[mcp_servers.mydemostudio]` in `~/.codex/config.toml`).

It exposes 24 tools covering the clip library (list / info / rename), projects (create /
get / delete / import / tracks), the timeline (add clip, add text, split, trim, speed,
move, delete, compact, per-clip settings), looks (per clip, project-wide, apply-to-all,
copy between clips) and output (export, render frame). `project_render_frame` is the
quickest feedback loop: it renders one frame to a PNG.

The app watches its `document.json`, so edits made by an agent appear live in an open
project.

The same verbs are available as a one-shot CLI, which is what scripts should use:

```sh
MyDemoStudio --cli clips.list --json '{}'
MyDemoStudio --cli project.export --json '{"project":"Demo","format":"mp4","preset":"1080p"}'
```

`mcp/` holds an earlier Node bridge that shells out to that CLI. It still works, but the
native server above supersedes it and needs no dependencies.

## Architecture

The core idea is **record raw, then re‑render**: capture a pristine master movie plus a
timestamped log of every cursor move, click, and keystroke (synced on the mach host
clock), then rebuild the polished video by applying every effect in a single Metal pass
at export/preview time. The master is never modified.

Multi‑clip projects build on the same idea: the timeline is cut into segments at every
clip boundary, and each segment is rendered by the *same* Metal compositor. A tiny looping
black “filler” track guarantees every instant has a frame, which is what lets still images,
text cards and gaps render at all.

- `Capture/` — ScreenCaptureKit recording, `CGEventTap` input logging, webcam and voiceover
  capture, permissions, and caption transcription.
- `Render/` — the Metal compositor and shaders, the auto‑zoom planner, cursor smoother, the
  single‑clip and timeline composition builders, the audio mixers, and the exporters.
- `Model/` — the `.mydemo` recording package, the `.mdsproj` edit document, and all
  Codable settings.
- `UI/` — the SwiftUI libraries, both editors, the multi‑lane timeline, and the inspector.
- `mcp/` — the MCP server.

## Tests

Everything is validated headlessly, by rendering real files and reading the pixels and
samples back out:

```sh
MDS_SELFTEST=algo     MyDemoStudio.app/Contents/MacOS/MyDemoStudio   # zoom + cursor maths
MDS_SELFTEST=timeline MyDemoStudio.app/Contents/MacOS/MyDemoStudio   # multi-clip render + export
MDS_SELFTEST=editor   MyDemoStudio.app/Contents/MacOS/MyDemoStudio   # editor glue, undo, autosave
MDS_SELFTEST=1        MyDemoStudio.app/Contents/MacOS/MyDemoStudio   # full record→export (needs permissions)

# Open a real project instead of a synthesized one:
MDS_SELFTEST=editor MDS_SELFTEST_PROJECT="My project" …

# Stability: 60 rounds of window resizing, real split-divider drags, and rapid
# edits/undo/split/seek against a live editor.
MDS_BYPASS_PERMS=1 MDS_STRESS=1 MDS_SELECT_PROJECT="My project" …
```

## Requirements

- macOS 26 or later, Xcode 26.
- The Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`).
- On first run, grant Screen Recording, Accessibility, and (optionally) Camera and
  Microphone. Screen Recording takes effect after a relaunch.

## Build

```sh
xcodebuild -project MyDemoStudio.xcodeproj -scheme MyDemoStudio -configuration Debug build
```
