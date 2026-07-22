# Roadmap

Status as of July 2026. MyDemoStudio is pre-release: it is built from source, and there
is no signed download yet.

## Done

| Area | State |
| --- | --- |
| Screen and window recording | Done. Window capture uses a display crop, so chrome, shadow and corners survive |
| Event log | Done. Moves, clicks and keystrokes on the mach host clock, anchored to the first delivered sample |
| Metal compositor | Done. Wallpaper, capture, shadow, camera, cursor, captions in one pass |
| Auto-zoom | Done. Click clustering, smootherstep envelope, fixed-timestep spring follow, in-bounds clamp |
| Cursor | Done. Real macOS arrow / hand sprites, smoothing, hide-when-idle |
| Backgrounds | Done. Six procedural mesh-gradient wallpapers, plus gradient and solid, with blur |
| Aspect ratios | Done. Original, 16:9, 9:16, 1:1 |
| Motion blur | Done. Radial zoom-blur driven by camera velocity |
| Voiceover | Done. During capture, or recorded over the timeline afterwards |
| Click / keystroke sounds | Done. Synthesised and mixed at logged event times |
| Webcam bubble | Render done and validated. Capture needs testing against more real cameras |
| Captions | Render done. On-device SpeechAnalyzer transcription needs accuracy testing on real speech |
| Multi-clip timeline editor | Done. Tracks, trim, split, speed, fades, titles, images with Ken Burns |
| Per-clip looks | Done, including copy-between-clips and apply-to-all |
| Export | Done. MP4 / MOV / GIF at 4K / 1080p / 720p, with audio |
| MCP server + CLI | Done. 24 tools, native stdio, no dependencies |
| Headless self-tests | Done. Algo, timeline, editor, full loop, plus a stability stress run |
| Website | Done. `site/`, deployed to GitHub Pages |

## Next

### Signed, notarised release
The largest gap between this and something a stranger can use. Needs a Developer ID
build, notarisation, a DMG, and an appcast for in-app updates — the same shape as
MyMacCleaner's release pipeline.

### Migrate off `AVMutableVideoComposition`
Deprecated in macOS 26 in favour of `AVVideoComposition.Configuration`. It still works,
so this is maintenance rather than urgency, but it should not be left indefinitely.

### Editable zoom regions
Auto-zoom is currently all or nothing per clip. Being able to click a zoom block on the
timeline to move, resize or delete it — and to add one by hand — would cover the cases
the planner reads wrong.

### Transitions
There are no transitions between clips yet: cuts only. Cross-dissolve at minimum.

### Background music ducking
A music track exists, but nothing automatically lowers it under the voiceover.

## Considered, not planned

| Idea | Why not |
| --- | --- |
| Cloud rendering or upload | The whole point is that nothing leaves the machine |
| A subscription, or paid tiers | The project exists because the alternative costs €29/month |
| Windows or Linux builds | It is built on ScreenCaptureKit, Metal and SpeechAnalyzer — the port would be a different application |
| Teleprompter / script overlay | Out of scope; a demo recorder, not a presentation tool |

## Contributing

Any of the "Next" items is a good place to start — see [CONTRIBUTING.md](CONTRIBUTING.md).
