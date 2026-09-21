# Agent Organizer — Plan

macOS desktop app. Sidebar of **folders** (A‑Z). Per folder, N **agents** (interactive CLI sessions: `claude`, `opencode`, plain shell, custom). Sessions survive app quit.

## 1. Principles

- Native, minimal footprint. No Electron / Tauri / WebView. Target: idle CPU 0%, baseline RSS < 50 MB, ~3–6 MB per attached agent.
- Sessions live **outside** the app process. Quitting the app never kills an agent unless explicitly asked.
- Folder‑first. A folder may be a git repo, a container of repos, or neither. The app never assumes "1 folder = 1 repo".
- Prefer reading files over spawning processes (e.g. `.git/HEAD` for branch, not `git`).
- Xcode not required. Builds with Command Line Tools only (current machine: CLT + Swift 6.3, no Xcode.app).

## 2. Tech stack (exact)

| Concern | Choice | Why |
|---|---|---|
| Language | Swift 6, strict concurrency | native, single binary |
| UI shell | SwiftUI (`NavigationSplitView`, `List`, `@Observable`) | small code, native look |
| Terminal hosting | AppKit `NSView` via `NSViewRepresentable` | keep terminal views alive across selection changes |
| Terminal emulator | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (`LocalProcessTerminalView`), MIT, pure Swift | mature VT emulator, pty spawn built in, no C deps |
| Session persistence | **tmux** (Homebrew), dedicated server: `tmux -S "~/Library/Application Support/Agent Organizer/tmux.sock" -f <bundled tmux.conf>` | detach/attach for free, battle‑tested; own socket + config = zero interference with user's tmux |
| Status/events | tmux **control mode** (`tmux -C attach`) — one long‑lived client, push events, no polling | how iTerm2 does it |
| Persistence | Codable JSON at `~/Library/Application Support/Agent Organizer/state.json` | trivial, no SwiftData/CoreData overhead |
| Filesystem watch | `DispatchSource.makeFileSystemObjectSource` on folder + `.git/HEAD` | cheap, no FSEvents stream needed |
| Build | SwiftPM `Package.swift` + `Makefile` that assembles `.app` (Info.plist, `.icns` via `iconutil`, ad‑hoc `codesign`) | works without Xcode |
| Min macOS | 14 (Sonoma) | `@Observable`, modern SwiftUI |
| Sandbox | **off** | must exec arbitrary PATH tools + unix socket; distribute outside App Store |

Rejected: Electron/Tauri (weight), own PTY daemon via LaunchAgent + XPC (weeks of work to re‑invent tmux), libghostty (embedding API still maturing — revisit later as SwiftTerm replacement), `abduco`/`dtach` (lighter than tmux but no control mode, unmaintained).

## 3. Architecture

```
┌──────────────────────── Agent Organizer.app ────────────────────────┐
│ SwiftUI shell                                                       │
│  ├─ Sidebar (folders A‑Z → agents)                                  │
│  └─ Detail: TerminalHost (cached SwiftTerm NSView per agent)        │
│        └─ child process: tmux -S <sock> attach -t <session>  ──┐    │
│ TmuxController                                                 │    │
│  ├─ control‑mode client: tmux -S <sock> -C attach  ────────────┼─┐  │
│  └─ one‑shot cmds: new‑session / send‑keys / kill‑session      │ │  │
│ Store (state.json)   FolderScanner   GitWatcher                │ │  │
└────────────────────────────────────────────────────────────────┼─┼──┘
                                                                 ▼ ▼
                        tmux server (own socket, survives app quit)
                          session ao_<folder>_<id>  → zsh -l → claude
                          session ao_<folder>_<id2> → zsh -l → opencode
```

- **Quit app** → SwiftTerm children (tmux clients) get SIGHUP → server keeps sessions. Relaunch → reconcile `list-sessions` with `state.json`, reattach lazily on selection.
- **Kill agent** (explicit, ⌘⇧W) → `kill-session`.
- **Agent process exits** (user types `exit`, claude quits) → pane shell remains (we start the tool *inside* a login shell), agent shows "idle shell". Optional "Restart" → re‑sends command (`claude --continue` for claude).

### Launch sequence for a new agent
```
tmux -S $SOCK -f $CONF new-session -d -s $NAME -c $CWD -x 200 -y 50
tmux -S $SOCK send-keys -t $NAME -- '<command>' Enter
```
`default-command` in bundled conf = `$SHELL -l` so `.zprofile`/`.zshrc` load and PATH (nvm, ~/.local/bin, homebrew) is correct inside the pane. The **app** only needs to locate `tmux` itself: resolve once at startup via `$SHELL -lc 'command -v tmux'`, fall back to `/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux`.

### Bundled `tmux.conf`
```
set -g default-terminal "xterm-256color"
set -sa terminal-overrides ",xterm-256color:RGB"
set -g default-command "$SHELL -l"
set -g status off
set -g mouse on
set -g history-limit 50000
set -sg escape-time 0
set -g focus-events on
set -g set-clipboard on
set -g allow-passthrough on
set -g extended-keys on
set -sa terminal-features "xterm-256color:extkeys"
set -g detach-on-destroy on
set -g remain-on-exit off
set -g set-titles on
```

## 4. Domain model

```swift
struct Folder: Identifiable, Codable {
  let id: UUID
  var path: URL                 // absolute
  var displayName: String       // default: last path component
  var kind: FolderKind          // .repo | .container(repos: [SubRepo]) | .plain (derived, cached)
  var scanDepth: Int = 1        // for containers
}
struct SubRepo: Codable { var relativePath: String; var branch: String? }

struct Agent: Identifiable, Codable {
  let id: UUID
  var folderID: UUID
  var relativeCwd: String       // "" = folder root, else e.g. "web" or "services/api"
  var preset: AgentPreset.ID    // claude | opencode | shell | custom…
  var title: String?            // user rename; else live pane title
  var tmuxSession: String       // "ao_<slug>_<8hex>"
  var createdAt: Date
  // runtime only (not persisted): status (.running/.idle/.exited/.detached), lastActivity
}

struct AgentPreset: Identifiable, Codable {
  let id: String
  var name: String              // "Claude Code"
  var command: String           // "claude"
  var resumeCommand: String?    // "claude --continue"
  var icon: String              // SF Symbol
}
```
Default presets: Claude Code (`claude` / `claude --continue`), OpenCode (`opencode`), Shell (none). User‑editable in Preferences (Codex, Gemini, aider, …).

## 5. Folder semantics (the nuance)

On add (`NSOpenPanel`, `allowsMultipleSelection = true`, directories only):

1. `.git` exists at root (dir **or** file → worktree) → `kind = .repo`.
2. Else scan children to `scanDepth` (default 1, max 3), skipping `node_modules`, `vendor`, `.build`, hidden dirs; any child with `.git` → `kind = .container(repos)`.
3. Else `.plain`.

Sidebar shows one **section per folder**, A‑Z (case‑insensitive, `localizedStandardCompare`). Under it: agents. Each agent row: preset icon, title, status dot, and a `cwd` badge when `relativeCwd != ""` (e.g. `services/api`). Container folders show discovered repos + branch in a collapsible "Repos" disclosure (informational + "New agent here" on click).

"New agent" (⌘N) in a folder opens a small popover: preset picker + cwd picker (root, each discovered repo, "Other…"). Same‑cwd duplicates allowed.

Folder re‑scan: on `DispatchSource` write event on the folder dir (debounced 500 ms) and on manual refresh. Removing a folder from the sidebar asks: *Keep agents running in tmux* (default) / *Kill agents*.

## 6. UI

- `NavigationSplitView` sidebar + detail. Sidebar toolbar: `+` add folder(s), `⌘N` new agent.
- Detail = `TerminalHostView` (`NSViewRepresentable`) that swaps in a **cached** `LocalProcessTerminalView` per agent from `[Agent.ID: NSView]`. Attach happens on first selection (`tmux attach`); views stay alive when deselected so output and scrollback persist. Optional preference: detach hidden agents after N min to reclaim memory.
- Empty states: no folders → drop zone + "Add folder"; tmux missing → onboarding card with `brew install tmux` and a "Recheck" button.
- Shortcuts: ⌘⇧O add folder · ⌘N new agent · ⌘W hide/detach agent (keeps running) · ⌘⇧W kill agent · ⌘R rename · ⌘1‑9 jump to agent n in current folder · ⌃Tab / ⌘⌥←→ next/prev agent · ⌘F find in scrollback (SwiftTerm search).
- Drag‑and‑drop folders onto sidebar. Drag agents to reorder within a folder (folders themselves stay A‑Z).
- Status dot per agent, driven by control mode: green = output in last 3 s, yellow = waiting (no output, pane alive, tool running), grey = idle shell, red/strikethrough = tmux session gone (offer Restart / Remove).
- Window close ≠ quit; ⌘Q quits and leaves sessions. Preference "Kill all agents on quit" (off).
- Appearance: system dark/light, one accent, SF Mono default, font size pref.

## 7. Status & metadata (phase 2)

- **Control mode**: single `tmux -C attach` process; parse `%output`, `%session-changed`, `%window-renamed`, `%pane-mode-changed`, `%sessions-changed`, `%exit`. Gives live titles (Claude sets pane title), activity, and death detection without polling.
- **Git branch**: read `.git/HEAD` (follow `gitdir:` for worktrees), watch file for changes. Show in folder header / repo rows.
- **Notifications** (phase 3): Claude Code hooks (`Notification`, `Stop`) → tiny `ao-notify` CLI shipped in the bundle → app Unix socket → dock badge / `UNUserNotification` "Agent X waiting for input". Same pattern for OpenCode if it exposes hooks.

## 8. Files & layout

```
agent-organizer/
├─ Package.swift                    # executable target + SwiftTerm dep
├─ Makefile                         # build, bundle, sign, run
├─ Sources/AgentOrganizer/
│  ├─ App/            AgentOrganizerApp.swift, AppDelegate.swift, Commands.swift
│  ├─ Model/          Folder.swift, Agent.swift, AgentPreset.swift, Store.swift
│  ├─ Tmux/           TmuxPaths.swift, TmuxController.swift, ControlModeClient.swift
│  ├─ Scan/           FolderScanner.swift, GitWatcher.swift
│  ├─ Terminal/       TerminalHostView.swift, TerminalCache.swift
│  └─ UI/             Sidebar/, Detail/, Onboarding/, Preferences/
├─ Resources/         tmux.conf, Info.plist, AppIcon.iconset/
└─ PLAN.md
```

Runtime dir: `~/Library/Application Support/Agent Organizer/{state.json, tmux.sock}`.

## 9. Build & distribution

```
swift build -c release
make bundle   # → build/Agent Organizer.app  (copy binary, Info.plist, Resources, iconutil, codesign -s -)
make run
```
Info.plist essentials: `CFBundleIdentifier`, `CFBundleExecutable`, `LSMinimumSystemVersion 14.0`, `NSPrincipalClass NSApplication`, `NSHighResolutionCapable`, `CFBundleURLTypes` (`agent-organizer://` for phase 3). No entitlements (no sandbox). Hardened runtime + notarization only if shared with others. Install: `make install` → `/Applications`.

Dependency: `brew install tmux` (app detects and guides). Later option: bundle a static tmux to remove the requirement.

## 10. Milestones

| # | Scope | Status |
|---|---|---|
| M0 | SwiftPM skeleton, Makefile, `.app` launches with menu bar & window | ✅ Done |
| M1 | Folders: add (multi), remove, A‑Z sidebar, JSON persistence, folder kind detection | ✅ Done |
| M2 | Agents: SwiftTerm + tmux attach, presets (claude/opencode/shell), new/kill, reconcile on launch, tmux‑missing onboarding | ✅ Done — verified sessions survive app quit |
| M3 | Sub‑repo scan, cwd picker, cwd badges, folder watch/rescan | ✅ Done — `FolderWatcher` debounced rescan on dir + `.git/HEAD` changes |
| M4 | Control mode: status, live titles, death detection | ✅ Done (status is binary running/exited, not yet running/waiting/idle — see below). Restart (`--continue`) shipped in M2's Commands. `TmuxControlModeClient` replaces polling as the primary path; a 10s poll remains a fallback only |
| M5 | Polish: shortcuts, rename, git branch display, quit‑behaviour preference, reorder, presets/font preferences | ✅ Done — drag-to-reorder within a folder; Preferences has a font-size stepper (applied live) and a Tools tab to add/edit/remove presets |
| M6 | Optional: split view, detach agent to own window, notifications via Claude hooks, dock badge, orphan-session surfacing | Split view and orphan-session surfacing shipped (both found to matter during real use). Detach-to-own-window / Claude-hook notifications / dock badge not built — still optional |

Known gaps, not yet addressed:
- Status is binary (green=session alive, red=session gone), not the three-way running/waiting/idle distinction sketched in §6 — that needs per-pane output-activity tracking, which tmux control mode only reports for the session a client is *attached* to, not server-wide. Would need one control-mode client per agent (or per visible agent) rather than one shared client; deferred as a real cost/benefit call, not an oversight.
- No detach-to-own-window, no Claude-hook-driven notifications/dock badge.
- tmux is a Homebrew dependency; not yet bundled statically.
- Interactive UI click-through (drag reorder, split-view toggle, presets editor) is verified by accessibility-tree reads and direct tmux-level checks, not by simulated clicks — this environment's accessibility permissions allow read-only introspection but not reliable click automation. Worth a manual pass.

## 11. Risks / open points

- **Shift+Enter / modifier keys in Claude Code** through tmux need `extended-keys on` + SwiftTerm's kitty/CSI‑u support. Verify early in M2; fallback: Option+Enter or `claude /terminal-setup`‑style keybinding.
- **Clipboard/OSC 52** via tmux `set-clipboard on` — confirm SwiftTerm passes it.
- SwiftTerm is CPU‑rendered (CoreText). Fine for TUIs; if heavy output ever hurts, swap in libghostty behind the same `TerminalHostView` interface.
- GUI apps inherit a minimal PATH — only the tmux binary lookup is affected (handled in §3). Everything else runs in the login shell.
- tmux mouse mode intercepts wheel for copy‑mode; acceptable, matches other tmux UIs. Preference to disable.
- Homebrew tmux requirement until static bundling.

## 12. Decisions to confirm

1. App name/bundle id: `Agent Organizer`, `be.dynamate.agent-organizer` vs personal domain.
2. Default scan depth for container folders: 1.
3. Sidebar: flat "folder → agents" with cwd badges (proposed) vs nested "folder → repo → agents".
4. Hidden agents stay attached (default) vs auto‑detach after N min.
