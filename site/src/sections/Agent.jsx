import { useState } from 'react'
import { Code, Section } from '../ui/kit.jsx'

const BIN = '/Applications/MyDemoStudio.app/Contents/MacOS/MyDemoStudio'

const json = (root) => `{
  "${root}": {
    "mydemostudio": {${root === 'servers' ? '\n      "type": "stdio",' : ''}
      "command": "${BIN}",
      "args": ["--mcp"]
    }
  }
}`

const CLIENTS = [
  {
    id: 'claude-code',
    name: 'Claude Code',
    path: '<your project>/.mcp.json',
    snippet: json('mcpServers'),
    note: 'Or register it everywhere at once: claude mcp add mydemostudio -- "…/MyDemoStudio" --mcp',
  },
  {
    id: 'claude-desktop',
    name: 'Claude Desktop',
    path: '~/Library/Application Support/Claude/claude_desktop_config.json',
    snippet: json('mcpServers'),
    note: 'Quit and reopen Claude Desktop. The tools appear under the connectors icon in the composer.',
  },
  {
    id: 'codex',
    name: 'Codex',
    path: '~/.codex/config.toml',
    lang: 'toml',
    snippet: `[mcp_servers.mydemostudio]\ncommand = "${BIN}"\nargs = ["--mcp"]`,
    note: 'Codex configures MCP in TOML, not JSON. Run /mcp inside Codex to check it connected.',
  },
  {
    id: 'cursor',
    name: 'Cursor',
    path: '~/.cursor/mcp.json',
    snippet: json('mcpServers'),
    note: 'Use .cursor/mcp.json inside a project to scope it to one workspace.',
  },
  {
    id: 'vscode',
    name: 'VS Code',
    path: '<your project>/.vscode/mcp.json',
    snippet: json('servers'),
    note: 'VS Code nests servers under "servers" and wants an explicit type. Start it from the ▶ button above the entry, then use Agent mode.',
  },
  {
    id: 'windsurf',
    name: 'Windsurf',
    path: '~/.codeium/windsurf/mcp_config.json',
    snippet: json('mcpServers'),
    note: 'Reload Windsurf, then refresh the MCP list in Cascade’s settings.',
  },
]

const GROUPS = [
  ['Clips', ['clips_list', 'clips_info', 'clips_rename']],
  [
    'Projects',
    ['projects_list', 'project_create', 'project_get', 'project_delete', 'project_import', 'project_add_track'],
  ],
  [
    'Timeline',
    [
      'timeline_add_clip',
      'timeline_add_text',
      'timeline_split',
      'timeline_trim',
      'timeline_set_speed',
      'timeline_move',
      'timeline_delete',
      'timeline_compact',
      'timeline_set_clip',
    ],
  ],
  ['Look', ['project_set_look', 'clip_set_look', 'project_apply_look_to_all', 'clip_copy_settings']],
  ['Output', ['project_export', 'project_render_frame']],
]

const CLI = `MyDemoStudio --cli clips.list --json '{}'

MyDemoStudio --cli project.export \\
  --json '{"project":"Demo","format":"mp4","preset":"1080p"}'`

export default function Agent() {
  const [active, setActive] = useState(CLIENTS[0])

  return (
    <Section
      id="agents"
      tc="01:30"
      eyebrow="Agents"
      title="The app is the MCP server"
      lede="No wrapper, no runtime, no checkout. The same binary that shows you the editor speaks the Model Context Protocol over stdio when you launch it with --mcp, so any MCP-capable agent can cut a video for you."
    >
      <div className="grid items-start gap-5 lg:grid-cols-[1.15fr_1fr]">
        {/* config */}
        <div className="rv card overflow-hidden p-0">
          <div className="flex flex-wrap gap-1 border-b border-white/8 p-3">
            {CLIENTS.map((c) => (
              <button
                key={c.id}
                type="button"
                onClick={() => setActive(c)}
                className={`rounded-full px-3.5 py-1.5 text-[0.8rem] font-medium transition-colors ${
                  active.id === c.id ? 'bg-white/12 text-paper' : 'text-faint hover:bg-white/6 hover:text-paper/80'
                }`}
              >
                {c.name}
              </button>
            ))}
          </div>

          <div className="p-5">
            <p className="tech mb-2 text-faint">Add this to</p>
            <p className="mb-4 break-all font-mono text-[0.78rem] text-azure-glow/85">{active.path}</p>
            <Code code={active.snippet} lang={active.lang ?? 'json'} label={active.lang ?? 'json'} id={active.id} />
            <p className="mt-4 text-[0.85rem] leading-relaxed text-faint">{active.note}</p>
          </div>
        </div>

        {/* tools */}
        <div className="rv card p-6" style={{ '--rv-d': '80ms' }}>
          <div className="mb-5 flex items-baseline justify-between">
            <h3 className="display-tight text-lg font-bold">24 tools</h3>
            <span className="tech text-faint">stdio · no deps</span>
          </div>
          <div className="space-y-4">
            {GROUPS.map(([group, tools]) => (
              <div key={group}>
                <p className="tech mb-2 text-faint">{group}</p>
                <div className="flex flex-wrap gap-1.5">
                  {tools.map((t) => (
                    <span
                      key={t}
                      className="rounded-md border border-white/8 bg-white/4 px-2 py-1 font-mono text-[0.68rem] text-paper/75"
                    >
                      {t}
                    </span>
                  ))}
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>

      <div className="mt-5 grid items-start gap-5 lg:grid-cols-[1fr_1.15fr]">
        <div className="rv card p-6">
          <h3 className="display-tight text-lg font-bold">It edits while you watch</h3>
          <p className="mt-3 text-[0.95rem] leading-relaxed text-muted">
            The app watches the project’s <code className="font-mono text-[0.85em] text-paper/80">document.json</code>,
            so an agent’s edits appear in an open project without a reload. Ask for a title card and it
            slides onto the overlay track in front of you.
          </p>
          <p className="mt-4 text-[0.95rem] leading-relaxed text-muted">
            <code className="font-mono text-[0.85em] text-paper/80">project_render_frame</code> is the
            fastest feedback loop there is — one frame to a PNG, which the agent can then look at.
          </p>
          <div className="mt-5 rounded-xl border border-white/8 bg-pit p-4">
            <p className="tech mb-2 text-faint">Try asking</p>
            <p className="text-[0.9rem] italic text-paper/80">
              “Add a title saying ‘Kosmico’ for the first 3 seconds, then show me frame 4.”
            </p>
          </div>
        </div>

        <div className="rv" style={{ '--rv-d': '80ms' }}>
          <div className="card h-full p-6">
            <h3 className="display-tight mb-1 text-lg font-bold">Same verbs, one shot</h3>
            <p className="mb-4 text-[0.95rem] leading-relaxed text-muted">
              Every tool is also a CLI subcommand, which is what shell scripts and CI should use.
            </p>
            <Code code={CLI} label="sh" id="cli" />
            <p className="mt-4 text-[0.85rem] leading-relaxed text-faint">
              In the app, <strong className="font-semibold text-paper/80">Connect an AI agent</strong> (⇧⌘M)
              shows all of this with the real binary path already filled in, and a button to copy it.
            </p>
          </div>
        </div>
      </div>
    </Section>
  )
}
