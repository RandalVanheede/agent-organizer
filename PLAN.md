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
| Session persistence | **tmux 3.7c, bundled** (static build, Homebrew fallback), dedicated server: `tmux -S "~/Library/Application Support/Agent Organizer/tmux.sock" -f <bundled tmux.conf>` | detach/attach for free, battle‑tested; own socket + config = zero interference with user's tmux |
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

## 6. UI (revised after first real use)

- `NavigationSplitView`. **Sidebar = folders only, A‑Z, acting as vertical tabs** (`List(selection:)`, one row per folder, no nested agents). Row shows kind icon, name, branch badge (repo folders), agent‑count badge, red dot if any agent's session has exited. Right‑click: New Agent, Rescan, Reveal in Finder, Remove Folder. "Unmanaged Sessions" section at the bottom when orphaned tmux sessions exist.
- **Canvas (detail) = horizontal agent tabs across the top + the active agent's terminal below.** Tabs show status dot, tool icon, title (custom → live tmux title → tool name), and `cwd · branch` subtitle when not at folder root. Trailing `+` creates an agent. Right‑click a tab: Restart, Rename, Open Side‑by‑Side, Move Left/Right, Kill. Each folder remembers its active tab; folder + tab selection persist across launches.
- `TerminalHostView` (`NSViewRepresentable`) swaps in a **cached** `LocalProcessTerminalView` per agent from `TerminalCache`. Attach happens on first display; views stay alive for the app's lifetime. Never auto‑detached.
- New Agent is a **single `.sheet` at the window root** (`MainSplitView`), driven by `newAgentPopoverFolderID`. Per‑row popovers in List headers were unreliable (wrong anchor / failed to present once a row was selected) — that was the first real bug report.
- Side‑by‑side: `HSplitView` of two `TerminalHostView`s from the same folder.
- Empty states: no folders → drop zone / "Add folder"; tmux missing → onboarding card with `brew install tmux` and Recheck.
- Shortcuts: ⌘⇧O add folder · ⌘N new agent (in selected folder) · ⌘⇧W kill agent · Agent menu: Restart.
- Window close ≠ quit; ⌘Q leaves sessions running. Preference "Kill all agents on quit" (off). Preferences also: terminal font size (live), Tools tab to add/edit/remove presets.

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
| M0 | SwiftPM skeleton, Makefile, `.app` launches | ✅ |
| M1 | Folders: add (multi), remove, A‑Z sidebar, JSON persistence, kind detection | ✅ |
| M2 | Agents: SwiftTerm + tmux attach, presets, new/kill, reconcile on launch, onboarding | ✅ sessions survive app quit |
| M3 | Sub‑repo scan, cwd picker, badges, folder watch/rescan | ✅ |
| M4 | Control mode: death detection, live titles, **three‑way status** (running / waiting / idle) via a `refresh-client -B` format subscription over `#{S:…}` (all sessions, pushed on change) | ✅ |
| M5 | Polish: shortcuts, rename, reorder, branch display, preferences (font, tools, quit behaviour) | ✅ |
| M6 | Split view · orphan sessions · **Claude Code hook notifications + Dock badge** · **bundled static tmux** · **app icon** · ⌘W kills agent | ✅ (detach‑to‑window not built — no one asked) |

### Status model (M4)
Folder rows show one orb summarising their agents with the same palette as the tabs (exited > waiting > running > idle; none when the folder has no agents).

`exited` = session gone · `idle` = pane runs only a shell · `running` = tool output in last 2.5 s · `waiting` = tool up but quiet, or a Claude hook (`Notification`/`Stop`) flagged it until the tab is viewed. Snapshot comes from the control client's subscription (`session|pane_id|pane_current_command|window_activity`); a 1 s in‑memory recompute decays running→waiting. Claude Code reports its *version* as `pane_current_command` (e.g. `2.1.278`) — anything not in the shell list counts as a tool.

### Hooks (M6)
**System notifications need an Apple‑issued signature.** `UNUserNotificationCenter` answers "Notifications are not allowed for this application" for ad‑hoc *and* self‑signed builds (confirmed via `hooks.log`; only Developer ID / Apple Development identities are accepted). Without Xcode on this machine there is no such identity, so the app falls back automatically to **in‑app toasts**: floating non‑activating `NSPanel`s in the top‑right (click → jump to the agent, auto‑dismiss 8 s) plus Dock badge + Dock bounce. If a proper identity is ever available, the system path is used unchanged. Diagnostics: `~/Library/Application Support/Agent Organizer/hooks.log`.

Builds are signed with a stable self‑signed identity "Agent Organizer Dev" (`scripts/make-signing-identity.sh`, `make identity`) so macOS permissions tied to the code signature survive rebuilds; ad‑hoc fallback otherwise.

**Claude Code snapshots hooks at startup** — sessions that were already running when hooks were installed must be restarted (tab › Restart) before they fire.

### Attention sound
Preferences › General has a system-sound picker (`Store.attentionSound`, default "Glass"; empty = silent) with a Play button. Two triggers, both routed through `AppState.playAttentionSound()`: (1) a Claude hook firing `Notification`/`Stop`; (2) tool-agnostic — `recomputeStatuses` arms a per-agent timer the moment a `running → waiting` transition happens, and dings once if it's still `waiting` after `quietBeforeDing` (4s) and the tab isn't the one on screen in the frontmost app. This covers tools with no hook support (OpenCode, custom presets). A recent hook event (`lastHookAt`, 10s) suppresses the heuristic so Claude agents don't double-ding. Each quiet episode dings at most once; a fresh `running` observation resets it.

Preferences › Install writes `~/Library/Application Support/Agent Organizer/bin/ao-hook` and merges `Notification`/`Stop`/`UserPromptSubmit` entries into `~/.claude/settings.json` (backup kept). The script no‑ops unless `$TMUX` is our socket, then drops a JSON file in `…/events/`; `HookEventWatcher` (DispatchSource) maps `TMUX_PANE` → session → agent, flags attention (orange dot, Dock badge count), posts a `UNUserNotification` (click → jumps to the tab). Viewing the tab or a new prompt clears it.

### Bundled tmux (M6)
`scripts/build-tmux.sh` builds tmux 3.7c with static libevent + ncursesw → `Resources/bin/tmux` (deps: libSystem, libresolv only). `TmuxPaths` prefers it over Homebrew. Same version as brew's, so an already‑running server is compatible.

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
