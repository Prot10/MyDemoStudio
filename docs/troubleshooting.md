# Troubleshooting

## Screen Recording is granted but nothing records

macOS only applies a new Screen Recording grant after the app restarts. The permission
screen has a **Quit & Reopen** button for exactly this.

## Permissions keep resetting after every build

macOS ties a permission grant to the app's code signature *and* its location. An ad-hoc
signed build gets a new signature hash each time you compile, so every rebuild looks like
a different app and the Accessibility grant is dropped.

Two fixes, either works:

1. **Run from `/Applications`.** Build, copy the app there, and grant permissions to that
   copy. Rebuilds overwrite the same bundle at the same path.
2. **Build with a real signing identity.** The project is configured for automatic
   signing; build with `-allowProvisioningUpdates` and the signature stays stable.

## Auto-zoom does nothing, and the cursor is missing

Both come from the event log, and the event log needs **Accessibility**. Without it the
capture still works — it is just not smart. Check System Settings → Privacy & Security →
Accessibility, and grant it to the app at the path you actually launch.

## The recorded window has a "you are sharing" pill on it

That was an older capture path. Window recording now captures a crop of the display
rather than an isolated window, precisely to avoid the pill and to keep the window's
shadow and rounded corners. If you still see it, you are running an old build.

## Export says the media is damaged

A race between stopping the capture and reading the file back. The recorder waits for the
asset to become readable after `stopCapture`; if you hit this on a current build, it is a
bug worth reporting with the recording's `meta.json`.

## The build fails on the shaders

The Metal compiler ships as a separate Xcode component. Install it once:

```sh
xcodebuild -downloadComponent MetalToolchain
```

## Xcode shows "Cannot find type X in scope" but the build works

SourceKit's cross-file indexing produces false positives on this project. The headless
build is the source of truth:

```sh
xcodebuild -project MyDemoStudio.xcodeproj -scheme MyDemoStudio build
```

If that succeeds, the code is fine.

## Xcode gets stuck on "Preparing Editor Functionality"

Launch the built app directly instead of pressing Run:

```sh
open /Applications/MyDemoStudio.app
```

## An agent's edits do not show up

The app watches the project's `document.json` for changes. If edits are not appearing:

- Check the agent is editing the project you have open — `project_get` reports the path.
- Check the MCP server actually connected. In Claude Code, `/mcp`; in Codex, `/mcp`; in
  VS Code, the ▶ button above the server entry in `mcp.json`.
- Confirm the `command` path in your config points at a binary that exists.

## Captions are empty or wrong

Transcription runs on the voiceover track, so there has to be one. The first run also
downloads a speech model — give it a moment. Accuracy depends on the recording; a quiet
room and a close microphone make a large difference.

---

Still stuck? [Open an issue](https://github.com/Prot10/MyDemoStudio/issues) — include your
macOS version, whether you built Debug or Release, and the output of the relevant
`MDS_SELFTEST` run.
