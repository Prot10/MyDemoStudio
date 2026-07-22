# Exporting

## Formats

| Format | Codec | Notes |
| --- | --- | --- |
| **MP4** | H.264 | The default. Browsers, Slack, social platforms and editors all take it |
| **MOV** | H.264 in a QuickTime container | For handing work to other Apple tools |
| **GIF** | — | 16 fps, no audio |

## Resolutions

`4K` (3840), `1080p` (1920) and `720p` (1280) are **caps on the longest edge**, applied
to the editing canvas — which is what defines the aspect ratio.

They never upscale. Exporting a 1280-wide recording at 4K gives you the 1280-wide
original, not a blurry enlargement.

So a 9:16 project exported at 1080p is 1080 × 1920, and a 16:9 project at the same preset
is 1920 × 1080. The preset sets quality; the canvas sets shape.

## Where it goes

You choose the destination in the export panel — the file is written wherever you point
it, not into a fixed folder.

## How audio gets in

Video is rendered first, then the audio is muxed into the result through an
`AVMutableComposition` passthrough export. Rendering both through one writer deadlocks,
so the two-pass approach is intentional rather than incidental.

The mixed audio is written as LPCM, not AAC — AAC's encoder priming would shift the
timeline by a few milliseconds against the picture.

## Rendering a single frame

`project_render_frame` (over MCP) and `project.renderFrame` (over the CLI) render one
frame of the timeline to a PNG. It is much faster than a full export and it is the
quickest way to check an edit — especially for an agent, which can then look at the
result.

```sh
MyDemoStudio --cli project.renderFrame \
  --json '{"project":"Demo","at":4.0,"path":"/tmp/frame.png"}'
```

---

Next: [agents and the CLI](agents.md).
