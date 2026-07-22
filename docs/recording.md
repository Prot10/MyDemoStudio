# Recording

Every recording becomes a `.mydemo` package in `~/Movies/MyDemoStudio`. It is the
original and it is never modified — projects only ever point at it.

## What you can capture

**A display.** The whole screen, at its native resolution. MyDemoStudio's own windows
are excluded from the shot, so the app never films itself.

**A single window.** Pick it from the capture menu in the sidebar. The window is
captured as a *crop of the display* rather than as an isolated window, which is
deliberate: an isolated window loses its shadow and rounded corners, and macOS puts a
"you are sharing" pill on top of it. Cropping the display keeps the window looking
exactly like it does on screen.

The window list refreshes each time you open it, and includes full-screen apps. System
UI and windows belonging to background agents are filtered out.

## Permissions

| Permission | Needed for | When it is asked |
| --- | --- | --- |
| Screen Recording | Any capture at all | First launch — **requires a relaunch to take effect** |
| Accessibility | The event log: cursor moves, clicks, keystrokes | First launch |
| Camera | The webcam bubble | First time you enable the webcam |
| Microphone | Voiceover and captions | First time you enable voiceover |

Screen Recording only starts working after the app restarts. The permission screen has a
**Quit & Reopen** button that does it for you.

Without Accessibility there is no event log, which means no auto-zoom, no rendered
cursor and no click sounds — the capture still works, it is just not smart.

> **Grant permissions once, from a stable location.** macOS ties a grant to the app's
> code signature *and* its path. Run the app from `/Applications` and the grants persist
> across rebuilds.

## Along with the picture

**Voiceover.** Toggle the microphone in the sidebar before you record and your voice is
captured alongside the screen. You can also do it afterwards: open a project, press
play, and record a take over the timeline — it lands at the playhead as an audio clip.

**Webcam bubble.** Toggle the camera in the sidebar. It records to a separate track, so
its position, size and corner stay adjustable afterwards.

**Click and keystroke sounds.** Off by default. When on, the exporter synthesises soft
click and key sounds and mixes them in at the exact moments the event log recorded them.
Nothing is captured from your system audio — the sounds are generated.

**Captions.** Generated after the fact, in the editor, from the voiceover. Transcription
runs on device through SpeechAnalyzer; nothing is uploaded.

## What is in a `.mydemo` package

```
Recording 2026-07-21 at 19.04.35.mydemo/
├── master.mov      the untouched capture, cursor hidden
├── events.json     every move, click and keystroke, on the mach host clock
├── captions.json   written only once you generate captions
├── camera.mov      written only if the webcam was on
└── project.json    the look for the single-clip editor
```

`events.json` records positions in display points along with the display's origin and
size, so the log stays meaningful even if you later change the output resolution.

## Managing recordings

The **Clips** library in the sidebar lists everything you have recorded. Rename from the
context menu; delete moves the package to the Trash. Deleting a recording that a project
references will break that project — the project holds a reference, not a copy.

---

Next: [the look](the-look.md), or go straight to [the editor](editor.md).
