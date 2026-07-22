# Architecture

## The one idea

**Record raw, then re-render.**

Capture a pristine master movie plus a timestamped log of every cursor move, click and
keystroke, synced on the mach host clock. Then rebuild the polished video by applying
every effect in a single Metal pass at preview and export time.

The master is never modified. Everything you can adjust — zoom, backdrop, padding,
corners, shadow, cursor, captions — is a number applied at render time, which is why any
of it can change at any point in the future.

Multi-clip projects build on the same idea: the timeline is cut into segments at every
clip boundary, and each segment is rendered by the *same* compositor. A looping black
filler track guarantees every instant has a frame, which is what lets still images, text
cards and gaps render at all.

## Sync

Capture and the event log come from different subsystems, so they are anchored together
explicitly:

- `HostClock` stamps events off the mach host clock.
- The anchor is the **first delivered sample's PTS**, not the first `.complete` frame.
  On a static screen the first complete frame can arrive noticeably late, which used to
  drag the whole event track out of alignment.

## The render pass

One fragment shader composes the entire frame, in this order:

1. Wallpaper — a procedural mesh gradient, or a linear gradient, or a solid, optionally blurred
2. The capture — sampled through the camera transform, with rounded corners
3. Drop shadow behind the capture plate
4. Radial zoom-blur, with strength taken from camera velocity, so it appears on ramps and vanishes on holds
5. Webcam bubble — center-cropped to a circle, mirrored, with a ring
6. Cursor — the real macOS sprite, at constant size, positioned through the same camera transform
7. Caption pill — text rasterised through Core Text into a texture

### The camera

The zoom is a **look-at** model, not a scale-about-a-corner:

```
srcUV = focusUV + (contentNorm - 0.5) / zoom
```

The focus point maps to the centre of the frame, so the cursor genuinely stays centred
rather than drifting toward an edge. `focusUV` is clamped to `[0.5/z, 1 - 0.5/z]` so the
frame never samples outside the capture.

The follow path is a fixed-timestep spring: the raw event track is resampled at 120 Hz
and then damped. Damping raw, unevenly spaced samples directly is what made earlier
versions teleport and judder.

## Source layout

| Directory | Holds |
| --- | --- |
| `Capture/` | ScreenCaptureKit recording, `CGEventTap` input logging, webcam and voiceover capture, permissions, caption transcription |
| `Render/` | The Metal compositor and shaders, the zoom planner, the cursor smoother, single-clip and timeline composition builders, audio mixers, exporters |
| `Model/` | The `.mydemo` recording package, the `.mdsproj` edit document, and all `Codable` settings |
| `UI/` | The SwiftUI libraries, both editors, the multi-lane timeline, the inspector |
| `MDSMCPServer.swift`, `MDSCLI.swift` | The MCP server and the one-shot CLI |

## File formats

```
~/Movies/MyDemoStudio/
├── Recording ….mydemo/          a recording — the original, never rewritten
│   ├── master.mov
│   ├── events.json
│   ├── captions.json
│   ├── camera.mov
│   └── project.json
└── Projects/
    └── Demo Cut.mdsproj/        an edit document
        ├── document.json        tracks, clips, timings, looks
        └── Media/               copies of imported files
```

Both are packages, and everything inside is JSON or standard media. Nothing is opaque:
you can read an edit with `cat`, and an agent can write one.

## Tests

Everything is validated headlessly, by rendering real files and reading the pixels and
samples back out. Set an environment variable and launch the binary directly:

| Flag | Checks |
| --- | --- |
| `MDS_SELFTEST=algo` | Zoom and cursor maths. Instant, no recording needed |
| `MDS_SELFTEST=timeline` | Multi-clip render and export |
| `MDS_SELFTEST=editor` | Editor glue, undo, autosave |
| `MDS_SELFTEST=1` | The full record → export loop. Needs permissions |

```sh
MDS_SELFTEST=algo /Applications/MyDemoStudio.app/Contents/MacOS/MyDemoStudio

# Open a real project instead of a synthesised one
MDS_SELFTEST=editor MDS_SELFTEST_PROJECT="My project" …

# Stability: 60 rounds of window resizing, real split-divider drags,
# and rapid edits / undo / split / seek against a live editor
MDS_BYPASS_PERMS=1 MDS_STRESS=1 MDS_SELECT_PROJECT="My project" …
```

## Known deprecation

`AVMutableVideoComposition` is deprecated in macOS 26 in favour of
`AVVideoComposition.Configuration`. It still works; the migration is deferred.
