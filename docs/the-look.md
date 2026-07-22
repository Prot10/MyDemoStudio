# The look

The look is the set of numbers the compositor applies when it rebuilds the frame. None
of it is baked into your recording, so you can change any of it at any time — including
long after the recording was made.

Set on the **project**, a look applies to every clip. Set on a **clip**, it overrides the
project for that clip only, so one clip can be zoomed and padded while the next stays
plain.

## Background

| Kind | What it is |
| --- | --- |
| Wallpaper | One of six procedural mesh gradients, generated in the shader — no image files |
| Gradient | A two-colour linear gradient at an angle you choose |
| Solid | One colour |

Wallpapers take a **blur** amount, which softens the backdrop without touching the
capture sitting on top of it.

## Frame

| Setting | Meaning |
| --- | --- |
| `paddingFraction` | Inset around the capture, as a fraction of the canvas's shorter side |
| `cornerRadiusFraction` | Corner radius, same units |
| `shadowRadiusFraction` | How far the drop shadow spreads |
| `shadowOpacity` | How dark it is |

Fractions rather than pixels, so a look survives a change of output resolution.

## Aspect ratio

`original`, `16:9` (1920 × 1080), `9:16` (1080 × 1920) and `1:1` (1080 × 1080). The
aspect defines the editing canvas; export resolution then scales that canvas. Recording
a wide screen and exporting 9:16 gives you a centred capture with backdrop above and
below — useful for turning one take into a vertical clip without re-recording.

## Auto-zoom

The camera pushes in around clicks and *follows the cursor* while it is in, so the
pointer stays near the middle of the frame.

- Clicks within **3.5s** of each other are treated as one cluster, so the camera holds
  rather than bouncing in and out between them.
- Each cluster gets a **0.75s** ease in, a hold that runs to **1.6s** past the last
  click, then a **0.9s** ease out. The curve is a smootherstep, not a linear ramp.
- The follow is a fixed-timestep spring, resampled at 120 Hz. Resampling is what stops
  it juddering when the raw event samples arrive unevenly.
- The focus point is clamped so the zoomed frame never samples outside the capture.

`zoomScale` is the magnification at the hold. Set it to **1.0** to keep the planner's
framing without any magnification, or turn `zoomEnabled` off entirely.

**Motion blur** is optional: a radial zoom-blur whose strength comes from camera
velocity, so it appears during the ramps and vanishes on the holds.

## Cursor

The real macOS cursor sprite is drawn into the frame — the system cursor is hidden
during capture, so what you see is always the rendered one.

- **Style**: `arrow`, `hand`, or `hand on click` (arrow normally, pointing hand while the
  button is down).
- **Size**: 1× to 5×. Larger than life reads much better once a video is scaled down.
- **Smoothing**: how much the raw pointer path is damped. It also hides the cursor when
  it has been idle for a while.

## Webcam bubble

A circular overlay in any corner, sized as a fraction of the frame. Center-cropped so it
stays circular whatever your camera's aspect is, mirrored like a selfie, with a ring.

## Captions

Generated in the editor from the voiceover, using on-device SpeechAnalyzer transcription,
then rasterised into the frame through Core Text as white text on a dark rounded pill.
There is no separate subtitle file, which is the point: the video carries its own
captions wherever it is posted.

## Audio

Separate levels for the voiceover and for the synthesised click / keystroke sounds, so
you can have quiet clicks under a loud voice.

---

Next: [the editor](editor.md).
