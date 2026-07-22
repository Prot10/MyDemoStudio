# The editor

## Two libraries

**Clips** — every recording you have made, as a `.mydemo` package in
`~/Movies/MyDemoStudio`. These are the originals.

**Projects** — `.mdsproj` edit documents in `~/Movies/MyDemoStudio/Projects`, each
assembling clips and imported media into a finished video.

A project *references* recordings; it never moves or rewrites them. Files you import
from elsewhere — videos, images, sounds — are **copied into the project**, so an edit
does not break when you later move the original.

## Tracks

| Track | Holds |
| --- | --- |
| Video (main) | Screen recordings, imported video, still images |
| Overlays | Title cards, the webcam bubble |
| Audio | Voiceover, music, imported sound |

A looping black filler track runs underneath everything. It is what guarantees a frame
exists at every instant, which is what lets still images, title cards and gaps render at
all.

## Editing a clip

- **Move** — drag it.
- **Trim** — drag either edge. This changes the source window, not the file.
- **Split** — `⌘B` cuts at the playhead.
- **Speed** — 0.25× to 4×.
- **Volume and fades** — per clip, on both ends.
- **Ripple delete** and **close gaps on this track**.

> Speeding a clip up shortens *that clip* without moving the ones after it. Use **close
> gaps on this track** when you want the timeline to tighten up. This is deliberate:
> a speed change should not silently reshuffle an edit you already timed.

## Images and titles

Images get a slow **Ken Burns** move so a still does not look frozen. Title cards live on
an overlay track with their own fades, position, size, colour and optional pill
background.

## Recording over the timeline

Play the project and record a webcam or voiceover take against what you are watching. The
take lands at the playhead — as an overlay clip for the camera, an audio clip for the
voice.

## Reusing settings

`⇧⌘C` copies a clip's look, volume, fades, placement and Ken Burns move. `⇧⌘V` pastes
them onto another clip.

**Speed is never copied by default.** It changes how long the clip is, and therefore the
shape of the whole edit — that should be a decision, not a side effect.

To push one clip's look onto *every* clip at once, use **apply look to all**.

## Preview

The preview player runs the same Metal compositor as the export, through the same
composition builder. What you scrub through is what lands on disk.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| `Space` | Play or pause |
| `⌘B` | Split at the playhead |
| `⌘Z` / `⇧⌘Z` | Undo / redo |
| `⇧⌘C` / `⇧⌘V` | Copy a clip's look / paste it onto another |
| `⌥⌘I` | Show or hide the inspector |
| `⇧⌘M` | Connect an AI agent |

The inspector and the sidebar both collapse, which is worth doing on a laptop screen.

---

Next: [exporting](exporting.md).
