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
- **Export** to 4K / 1080p / 720p video or animated GIF.
- A non‑destructive editor with live preview (the preview uses the same Metal
  compositor as the export).

## Architecture

The core idea is **record raw, then re‑render**: capture a pristine master movie plus a
timestamped log of every cursor move, click, and keystroke (synced on the mach host
clock), then rebuild the polished video by applying every effect in a single Metal pass
at export/preview time. The master is never modified.

- `Capture/` — ScreenCaptureKit recording, `CGEventTap` input logging, webcam capture,
  permissions, and caption transcription.
- `Render/` — the Metal compositor and shaders, the auto‑zoom planner, cursor smoother,
  composition builder, and the video/GIF/audio exporters.
- `Model/` — the `.mydemo` project package and all Codable settings.
- `UI/` — the SwiftUI editor, inspector, timeline, and library.

## Requirements

- macOS 26 or later, Xcode 26.
- The Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`).
- On first run, grant Screen Recording, Accessibility, and (optionally) Camera and
  Microphone. Screen Recording takes effect after a relaunch.

## Build

```sh
xcodebuild -project MyDemoStudio.xcodeproj -scheme MyDemoStudio -configuration Debug build
```
