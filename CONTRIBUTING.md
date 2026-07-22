# Contributing

Thanks for taking a look. Bug reports, ideas and pull requests are all welcome.

## Reporting a bug

[Open an issue](https://github.com/Prot10/MyDemoStudio/issues) and include:

- Your macOS version, and whether you built Debug or Release.
- What you expected and what happened instead.
- The output of the relevant self-test, if the problem is in the render pipeline:
  `MDS_SELFTEST=algo` (zoom maths), `MDS_SELFTEST=timeline` (multi-clip render).

[Troubleshooting](docs/troubleshooting.md) covers the common ones — permissions that will
not stick, missing cursors, shader build failures — so it is worth a glance first.

## Making a change

1. Fork and branch off `main`.
2. Make the change.
3. Confirm the headless build passes — it is the source of truth, not Xcode's indexer:
   ```sh
   xcodebuild -project MyDemoStudio.xcodeproj -scheme MyDemoStudio build
   ```
4. Run the self-tests that touch what you changed:
   ```sh
   MDS_SELFTEST=algo     /Applications/MyDemoStudio.app/Contents/MacOS/MyDemoStudio
   MDS_SELFTEST=timeline /Applications/MyDemoStudio.app/Contents/MacOS/MyDemoStudio
   MDS_SELFTEST=editor   /Applications/MyDemoStudio.app/Contents/MacOS/MyDemoStudio
   ```
5. Open a pull request describing what changed and why.

Xcode may show `Cannot find type X in scope` across files. Those are SourceKit false
positives on this project — if `xcodebuild` succeeds, the code is fine.

## Notes on the codebase

- Adding a `.swift` or `.metal` file needs **no** project-file edit. The Xcode project
  uses a synchronised file-system group.
- Anything that changes how a frame looks should be validated by rendering a real file
  and reading the pixels back, not by eye. That is what the self-tests do, and new
  render features should extend them.
- Settings are `Codable` and land in `document.json` / `project.json`. If you add one,
  give it a default so existing projects keep loading.
- If you add an editing operation, add it to the MCP server and the CLI too. They share
  one verb table — a tool and its `x.y` CLI subcommand are the same code path.

## The website

The promo site is in `site/`. It is a plain Vite + React + Tailwind project:

```sh
cd site && npm install && npm run dev
```

It deploys to GitHub Pages automatically on push to `main`.

## Legal notice

By contributing, you agree that your contributions are licensed under the
[GNU Affero General Public License v3.0](LICENSE), the same license as the project.
