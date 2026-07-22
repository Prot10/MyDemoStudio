# Changelog

All notable changes to MyDemoStudio are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project will follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) from its first release.

## [Unreleased]

Everything so far. There is no tagged release yet — the app is built from source.

### Added

- **Recording.** ScreenCaptureKit capture of a display or a single window, the latter as
  a display crop so window chrome, shadow and corners render normally. App-owned windows
  are excluded from the shot.
- **Event log.** `CGEventTap` records every cursor move, click and keystroke, stamped on
  the mach host clock and anchored to the first delivered sample's PTS.
- **Metal compositor.** One fragment shader composes wallpaper, capture, drop shadow,
  camera transform, webcam bubble, cursor and caption pill. Preview and export share it.
- **Auto-zoom.** Clicks cluster into zoom segments with a smootherstep envelope; the
  camera follows the cursor through a fixed-timestep spring, clamped in bounds.
- **Cursor rendering.** Real macOS arrow and pointing-hand sprites, with smoothing,
  hide-when-idle, and a size control.
- **Backgrounds.** Six procedural mesh-gradient wallpapers, plus gradient and solid, with
  an optional blur.
- **Framing.** Padding, corner radius, drop shadow and 16:9 / 9:16 / 1:1 / original
  aspect ratios, all stored as fractions so they survive a resolution change.
- **Motion blur.** Radial zoom-blur whose strength comes from camera velocity.
- **Webcam bubble.** Circular overlay in any corner, center-cropped and mirrored.
- **Voiceover.** Microphone capture during recording, or recorded over the timeline
  afterwards.
- **Click and keystroke sounds.** Synthesised and mixed in at logged event times.
- **Captions.** On-device SpeechAnalyzer transcription rasterised into the frame.
- **Editor.** Multi-track timeline with trimming, `⌘B` split, 0.25×–4× speed, fades,
  ripple delete, close gaps, title cards, and images with a Ken Burns move.
- **Per-clip looks**, with copy-between-clips (`⇧⌘C` / `⇧⌘V`) and apply-to-all.
- **Export.** MP4, MOV and animated GIF at 4K / 1080p / 720p, with audio, to any
  destination.
- **MCP server.** The app binary speaks MCP over stdio with `--mcp`, exposing 24 tools.
  Setup UI for Claude Code, Claude Desktop, Codex, Cursor, VS Code and Windsurf.
- **CLI.** The same 24 verbs as one-shot subcommands, taking and returning JSON.
- **Live reload.** The app watches a project's `document.json`, so agent edits appear in
  an open project without a reload.
- **Headless self-tests.** `MDS_SELFTEST=algo|timeline|editor|1`, validating by rendering
  real files and reading pixels and samples back, plus a stability stress run.
- **Website.** Promo site in `site/`, deployed to GitHub Pages.
- **Documentation.** Guides in `docs/` covering recording, the look, the editor,
  exporting, agents, architecture and troubleshooting.

### Fixed

- Crash on stop, from a force-unwrapped thread in the event-tap loop.
- "Media damaged" on export, caused by reading the asset before it was readable after
  `stopCapture`.
- Sync anchor landing late on static screens — the anchor is now the first delivered
  sample, not the first complete frame.
- Audio export deadlock from feeding two inputs to one writer; audio is now muxed in a
  second pass.
- Audio track invalidated mid-mux because its asset was released; the asset is now
  retained for the length of the operation.
- Camera judder and teleporting from damping unevenly spaced event samples; the path is
  resampled at 120 Hz before damping.
- The macOS "you are sharing" pill appearing over recorded windows.
- Permission grants resetting on every rebuild, by moving to a stable signing identity.
