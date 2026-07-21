#!/usr/bin/env node
// MyDemoStudio MCP server.
//
// Deliberately thin: every tool spawns the app's headless CLI
// (`MyDemoStudio --cli <verb> --json {…}`) and returns its JSON verbatim. All document
// logic — validation, timeline maths, rendering — lives in Swift, so this adapter can
// never drift out of sync with the app's own editor.

import { spawn } from 'node:child_process'
import { existsSync, readdirSync, statSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js'
import { z } from 'zod'

// ---------------------------------------------------------------- binary lookup

// Picks the *newest* MyDemoStudio build. Newest rather than first-found on purpose: an
// old copy sitting in /Applications predates the `--cli` interface and would just launch
// the GUI and never exit, so preferring the freshest binary keeps a stale install from
// shadowing the build you're actually working on.
function findBinary() {
  if (process.env.MDS_APP_BINARY) return process.env.MDS_APP_BINARY

  const candidates = [
    '/Applications/MyDemoStudio.app/Contents/MacOS/MyDemoStudio',
    join(homedir(), 'Applications/MyDemoStudio.app/Contents/MacOS/MyDemoStudio'),
  ]
  const derived = join(homedir(), 'Library/Developer/Xcode/DerivedData')
  if (existsSync(derived)) {
    for (const dir of readdirSync(derived)) {
      if (!dir.startsWith('MyDemoStudio-')) continue
      for (const config of ['Debug', 'Release']) {
        candidates.push(join(derived, dir, 'Build/Products', config, 'MyDemoStudio.app/Contents/MacOS/MyDemoStudio'))
      }
    }
  }
  return (
    candidates
      .filter(existsSync)
      .map((path) => ({ path, mtime: statSync(path).mtimeMs }))
      .sort((a, b) => b.mtime - a.mtime)[0]?.path ?? null
  )
}

const BINARY = findBinary()

// Exports can legitimately take minutes; everything else is a JSON edit and should be
// near-instant. A bounded wait means a broken binary reports an error instead of hanging.
const SLOW_VERBS = new Set(['project.export', 'project.renderFrame'])

// ---------------------------------------------------------------- CLI bridge

// Every verb is a read-modify-write of document.json, so overlapping calls could clobber
// each other. Funnelling them through one queue makes concurrent tool calls safe without
// needing a lock file on the Swift side.
let queue = Promise.resolve()
function serialize(work) {
  const result = queue.then(work, work)
  queue = result.catch(() => {})
  return result
}

function callCLI(verb, payload) {
  return serialize(() => spawnCLI(verb, payload))
}

function spawnCLI(verb, payload) {
  return new Promise((resolve) => {
    if (!BINARY) {
      resolve({
        ok: false,
        error:
          'MyDemoStudio binary not found. Build the app, or set MDS_APP_BINARY to ' +
          'the path of MyDemoStudio.app/Contents/MacOS/MyDemoStudio.',
      })
      return
    }
    // The payload goes over stdin, so quoting and shell escaping never come into play.
    const child = spawn(BINARY, ['--cli', verb, '--json', '-'], { stdio: ['pipe', 'pipe', 'pipe'] })
    let stdout = ''
    let stderr = ''
    let settled = false
    const finish = (value) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolve(value)
    }
    const timer = setTimeout(
      () => {
        child.kill('SIGKILL')
        finish({
          ok: false,
          error:
            `'${verb}' timed out. ${BINARY} may be an old build without --cli support ` +
            `(it would launch the GUI instead). Rebuild the app, or point MDS_APP_BINARY at a current build.`,
        })
      },
      SLOW_VERBS.has(verb) ? 15 * 60_000 : 60_000,
    )
    child.stdout.on('data', (d) => (stdout += d))
    child.stderr.on('data', (d) => (stderr += d))
    child.on('error', (err) => finish({ ok: false, error: `spawn failed: ${err.message}` }))
    child.on('close', () => {
      // The app can log to stdout before our JSON line; take the last JSON object.
      const line = stdout.trim().split('\n').filter((l) => l.trim().startsWith('{')).pop()
      if (!line) {
        finish({ ok: false, error: `no JSON from CLI (stderr: ${stderr.slice(-400)})` })
        return
      }
      try {
        finish(JSON.parse(line))
      } catch (err) {
        finish({ ok: false, error: `bad JSON from CLI: ${err.message}`, raw: line.slice(0, 400) })
      }
    })
    child.stdin.write(JSON.stringify(payload ?? {}))
    child.stdin.end()
  })
}

/** Drops undefined keys so the Swift side sees only what the caller actually set. */
function compact(object) {
  return Object.fromEntries(Object.entries(object ?? {}).filter(([, v]) => v !== undefined))
}

// ---------------------------------------------------------------- schemas

const project = z.string().describe("Project name, id ('X.mdsproj') or absolute path")
const clipID = z.string().describe('Clip UUID from the timeline (see project_get)')
const track = z.string().optional().describe('Track UUID or name; defaults to a sensible track for the media kind')

const lookShape = z
  .object({
    background: z.any().optional(),
    paddingFraction: z.number().optional(),
    cornerRadiusFraction: z.number().optional(),
    shadowRadiusFraction: z.number().optional(),
    shadowOpacity: z.number().optional(),
    zoomEnabled: z.boolean().optional(),
    zoomScale: z.number().optional(),
    cursorStyle: z.enum(['arrow', 'hand', 'handOnClick']).optional(),
    cursorScale: z.number().optional(),
    cursorSmoothing: z.number().optional(),
    sfxEnabled: z.boolean().optional(),
    sfxVolume: z.number().optional(),
    captionsEnabled: z.boolean().optional(),
  })
  .describe('Look settings; omitted fields inherit the project defaults')

// Each entry: [tool name, description, zod shape, CLI verb, payload builder].
const TOOLS = [
  ['clips_list', 'List every screen recording in the clip library (reusable across projects).', {}, 'clips.list', () => ({})],
  ['clips_info', 'Details for one library recording.', { id: z.string() }, 'clips.info', (a) => ({ id: a.id })],

  [
    'clips_rename',
    'Rename a recording. Only the displayed name changes — the package on disk keeps its id, so projects using the clip keep working. An empty name restores the original.',
    { id: z.string(), name: z.string() },
    'clips.rename',
    (a) => ({ id: a.id, name: a.name }),
  ],

  ['projects_list', 'List all edit projects.', {}, 'projects.list', () => ({})],
  [
    'project_create',
    'Create an empty edit project with Video / Overlays / Voiceover / Music tracks.',
    { name: z.string(), aspect: z.enum(['wide', 'vertical', 'square', 'original']).optional(), fps: z.number().optional() },
    'project.create',
    (a) => compact({ name: a.name, aspect: a.aspect, fps: a.fps }),
  ],
  ['project_get', 'Full edit document: tracks, clips, timings, look. Start here to find clip UUIDs.', { project }, 'project.get', (a) => ({ project: a.project })],
  ['project_delete', 'Move a project to the Trash. Source recordings are never touched.', { project }, 'project.delete', (a) => ({ project: a.project })],
  [
    'project_import',
    'Copy an external video/image/audio file into the project’s Media folder.',
    { project, path: z.string().describe('Absolute path to the file') },
    'project.import',
    (a) => ({ project: a.project, path: a.path }),
  ],
  ['project_set_look', 'Change the project-wide default look (background, padding, zoom, cursor…).', { project, look: lookShape }, 'project.setLook', (a) => ({ project: a.project, look: compact(a.look) })],
  [
    'project_add_track',
    'Add a track (lane) to the timeline.',
    { project, kind: z.enum(['main', 'overlay', 'audio']), name: z.string().optional() },
    'project.addTrack',
    (a) => compact({ project: a.project, kind: a.kind, name: a.name }),
  ],

  [
    'timeline_add_clip',
    'Place media on the timeline. Give exactly one of: clip (library recording id), path (file to import), media (file already in the project).',
    {
      project,
      clip: z.string().optional().describe('Library recording id from clips_list'),
      path: z.string().optional().describe('Absolute path of a file to import and place'),
      media: z.string().optional().describe('Filename already inside the project Media/ folder'),
      track,
      start: z.number().optional().describe('Timeline position in seconds; defaults to the end of the track'),
      sourceIn: z.number().optional().describe('Trim: start offset inside the source, seconds'),
      sourceOut: z.number().optional().describe('Trim: end offset inside the source, seconds'),
      speed: z.number().optional().describe('1 = normal, 2 = twice as fast (halves the timeline length)'),
      volume: z.number().optional(),
      fadeIn: z.number().optional(),
      fadeOut: z.number().optional(),
      name: z.string().optional(),
      overlay: z.boolean().optional().describe('Place as a picture-in-picture overlay (webcam bubble style)'),
    },
    'timeline.addClip',
    (a) => compact(a),
  ],
  [
    'timeline_add_text',
    'Add a text card / title on an overlay track.',
    {
      project,
      text: z.string(),
      start: z.number().optional(),
      duration: z.number().optional(),
      x: z.number().optional().describe('0…1 across the canvas, 0.5 = centre'),
      y: z.number().optional().describe('0…1 down the canvas, 0.5 = centre'),
      fontSize: z.number().optional().describe('Fraction of canvas height, e.g. 0.07'),
      pill: z.boolean().optional().describe('Dark rounded background behind the text'),
      fadeIn: z.number().optional(),
      fadeOut: z.number().optional(),
      track,
    },
    'timeline.addText',
    (a) => compact(a),
  ],
  ['timeline_split', 'Cut a clip in two at a timeline instant.', { project, clip: clipID, at: z.number().describe('Timeline seconds') }, 'timeline.split', (a) => ({ project: a.project, clip: a.clip, at: a.at })],
  [
    'timeline_trim',
    'Retrim a clip’s source window (seconds inside the source media).',
    { project, clip: clipID, sourceIn: z.number().optional(), sourceOut: z.number().optional() },
    'timeline.trim',
    (a) => compact(a),
  ],
  ['timeline_set_speed', 'Speed a clip up or slow it down. 2 = twice as fast.', { project, clip: clipID, speed: z.number() }, 'timeline.setSpeed', (a) => ({ project: a.project, clip: a.clip, speed: a.speed })],
  ['timeline_move', 'Move a clip to a new start time, optionally to another track.', { project, clip: clipID, start: z.number(), track }, 'timeline.move', (a) => compact(a)],
  [
    'timeline_delete',
    'Remove a clip. With ripple, later clips on that track slide left to close the gap.',
    { project, clip: clipID, ripple: z.boolean().optional() },
    'timeline.delete',
    (a) => compact(a),
  ],
  ['timeline_compact', 'Remove all gaps on a track so its clips play back to back.', { project, track }, 'timeline.compact', (a) => compact(a)],
  [
    'timeline_set_clip',
    'Set a clip’s volume, fades, name, on-screen transform, Ken Burns move, or text.',
    {
      project,
      clip: clipID,
      volume: z.number().optional(),
      fadeIn: z.number().optional(),
      fadeOut: z.number().optional(),
      name: z.string().optional(),
      transform: z
        .object({
          centerX: z.number().optional(),
          centerY: z.number().optional(),
          scale: z.number().optional(),
          opacity: z.number().optional(),
          circular: z.boolean().optional(),
        })
        .optional()
        .describe('Overlay placement, normalized to the canvas'),
      kenBurns: z
        .object({
          startScale: z.number().optional(),
          endScale: z.number().optional(),
          startX: z.number().optional(),
          startY: z.number().optional(),
          endX: z.number().optional(),
          endY: z.number().optional(),
        })
        .optional()
        .describe('Slow pan/zoom for still images'),
      text: z
        .object({
          string: z.string().optional(),
          fontSize: z.number().optional(),
          x: z.number().optional(),
          y: z.number().optional(),
          pill: z.boolean().optional(),
        })
        .optional(),
    },
    'timeline.setClip',
    (a) => compact(a),
  ],
  ['clip_set_look', 'Override the look for one clip (background, padding, zoom, cursor…).', { project, clip: clipID, look: lookShape }, 'clip.setLook', (a) => ({ project: a.project, clip: a.clip, look: compact(a.look) })],
  [
    'project_apply_look_to_all',
    'Apply one look to the whole video: make it the project default and clear every per-clip override. Pass `clip` to adopt that clip’s look, and/or `look` to set fields directly.',
    { project, clip: z.string().optional().describe('Clip whose look becomes the project default'), look: lookShape.optional() },
    'project.applyLookToAll',
    (a) => compact({ project: a.project, clip: a.clip, look: a.look ? compact(a.look) : undefined }),
  ],
  [
    'clip_copy_settings',
    'Copy look, volume, fades, placement and Ken Burns from one clip onto others. Give `to` (clip ids) or `all: true`. Source, position, trim are never copied; speed only with includeSpeed.',
    { project, from: clipID, to: z.array(z.string()).optional(), all: z.boolean().optional(), includeSpeed: z.boolean().optional() },
    'clip.copySettings',
    (a) => compact(a),
  ],

  [
    'project_export',
    'Render the project to a video. Returns the output path.',
    {
      project,
      format: z.enum(['mp4', 'mov', 'gif']).optional().describe('Container; defaults to mp4'),
      preset: z.enum(['4K', '1080p', '720p']).optional().describe('Resolution; defaults to 1080p'),
      path: z.string().optional().describe('Destination file; defaults to the project’s Renders folder'),
    },
    'project.export',
    (a) => compact(a),
  ],
  [
    'project_render_frame',
    'Render a single frame to a PNG — the fastest way to see what the timeline looks like.',
    { project, at: z.number().describe('Timeline seconds'), path: z.string().optional() },
    'project.renderFrame',
    (a) => compact(a),
  ],
]

// ---------------------------------------------------------------- server

const server = new McpServer({ name: 'mydemostudio', version: '1.0.0' })

for (const [name, description, shape, verb, build] of TOOLS) {
  server.registerTool(name, { description, inputSchema: shape }, async (args) => {
    const result = await callCLI(verb, build(args ?? {}))
    return {
      content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
      isError: result?.ok === false,
    }
  })
}

await server.connect(new StdioServerTransport())
