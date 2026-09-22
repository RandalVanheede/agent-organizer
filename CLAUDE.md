# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Agent Organizer: a native macOS app (Swift 6 / SwiftUI, no Xcode required) that keeps project **folders** as vertical tabs in a sidebar and, per folder, runs **agents** (Claude Code, OpenCode, a shell, custom presets) as horizontal tabs, each rendered by SwiftTerm. Every agent is a **tmux session on the app's own socket**, so agents survive the app quitting. `PLAN.md` is the design doc and milestone history; keep it in sync when behaviour changes.

## Build / run

No Xcode project — SwiftPM plus a Makefile that assembles the `.app`. No test target exists.

```sh
swift build -c release          # compile only (fastest way to check for errors)
make bundle                     # build + assemble build/Agent Organizer.app + sign
make run                        # bundle, then open the app
make install                    # copy to /Applications
make tmux                       # rebuild Resources/bin/tmux from source (scripts/build-tmux.sh)
make icon                       # re-render Resources/AppIcon.iconset (scripts/make-icon.swift)
make identity                   # create/trust the "Agent Organizer Dev" self-signed signing identity
```

Iteration loop used throughout development: `pkill -f "Agent Organizer.app/Contents/MacOS/AgentOrganizer"; make bundle; open "build/Agent Organizer.app"`. Killing the app never kills agents (they live in tmux).

Runtime state lives in `~/Library/Application Support/Agent Organizer/`: `state.json` (all persisted data), `tmux.sock`, `hooks.log`, `events/`, `bin/ao-hook`. Deleting `state.json` gives a clean slate without touching tmux sessions.

## Verifying changes without a GUI test harness

There are no automated tests; verification has been done by:
- Driving tmux directly against the app's socket: `tmux -S "$HOME/Library/Application Support/Agent Organizer/tmux.sock" list-sessions` / `list-panes -a -F '#{session_name} #{pane_id} #{pane_current_command}'`. Use the same binary version as the app (bundled `Resources/bin/tmux` is 3.7c, same as Homebrew's) — protocol mismatch otherwise.
- Firing hook events by hand: `printf '{"hook_event_name":"Notification","message":"x"}' | TMUX="<socket>,1,0" TMUX_PANE="%N" sh Resources/ao-hook.sh Notification`, then reading `hooks.log`.
- Read-only accessibility queries via `osascript` (`System Events` → `process "Agent Organizer"`) work for inspecting windows/menus; sending keystrokes/clicks does not (no Accessibility permission) — don't burn time on it.
- Screenshots are not possible (no Screen Recording permission).

## Architecture — the parts that span files

**Process model.** The app never owns a PTY for an agent directly. `TmuxController` (one-shot `tmux -S <socket> -f <bundled conf> …` invocations) creates sessions named `ao_<folder-slug>_<8hex>`, whose default command is the user's login shell (so PATH/nvm/etc. are right), then `send-keys` the tool's launch command. `TerminalCache` holds one SwiftTerm `LocalProcessTerminalView` per agent for the app's lifetime; its child process is `tmux attach-session -t <session>`. Switching tabs only re-parents the cached NSView (`TerminalHostView`); nothing is torn down until the user kills the agent. "Restart" uses `respawn-pane -k` so a resume command is never typed into a still-running tool.

**Which tmux.** `TmuxPaths.resolveTmuxBinary()` prefers the statically linked `Contents/Resources/bin/tmux`, then Homebrew, then the login shell's PATH. The app's socket and `Resources/tmux.conf` are its own; the user's tmux is never touched. Sessions prefixed `__ao_` are internal plumbing and are filtered out of every user-facing list.

**Live status without polling.** `TmuxControlModeClient` keeps one `tmux -C attach` client on the hidden `__ao_control` session and consumes three kinds of notifications, all of which tmux broadcasts server-wide (verified empirically, not documented): `%sessions-changed` (death/creation), `%window-renamed`/`%unlinked-window-renamed` (live tab titles), and a `refresh-client -B` **format subscription** over `#{S:…}` giving every session's `pane_id|pane_current_command|window_activity`. `AppState.recomputeStatuses` derives `AgentStatus`: session gone → `exited`; command is a shell → `idle`; output within 2.5 s → `running`; else `waiting`. A 1 s in-memory tick decays running→waiting; a 10 s `list-sessions` poll is only a safety net. Claude Code reports its **version string** as `pane_current_command`, so "not a shell" is the tool test — don't match on `claude`.

**Selection model.** `AppState.selectedFolderID` (sidebar) + `activeAgentByFolder` (which tab per folder), both persisted via `Store`. `selectedAgent` falls back to the folder's first agent when the recorded one is gone. `splitAgentID` (side-by-side) only resolves when it points at a live agent in the same folder — stale values render nothing rather than needing cleanup everywhere.

**Folders.** A folder is one sidebar entry regardless of kind: `.repo` (`.git` at root), `.container(repos:)` (sub-repos found to `scanDepth`, default 1), or `.plain`. Sub-repos only feed the "start in…" cwd choice and the branch badges. `FolderScanner` reads `.git/HEAD` directly (follows `gitdir:` for worktrees) — never spawns `git`. `FolderWatcher` puts a `DispatchSource` on each folder root and every known `.git/HEAD` and rescans on change (500 ms debounce).

**New Agent UI.** Presented from a single `.sheet(item:)` in `MainSplitView`, driven by `AppState.newAgentPopoverFolderID`. Do not attach per-row `.popover`s inside `List` section headers — that was the first real bug (mis-anchored, failed to present once a row was selected).

**⌘W.** Means Kill Agent. `AOApplication` (Info.plist `NSPrincipalClass`) strips the stock File › Close shortcut in `sendEvent` because SwiftUI claims ⌘W for Close inconsistently across launches and AppKit dispatches to the first menu item holding a key. ⇧⌘W is an explicit "Close Window" command.

**Claude Code hooks → attention.** `HookInstaller` copies `Resources/ao-hook.sh` to App Support/`bin/ao-hook` and merges `Notification`/`Stop`/`UserPromptSubmit` entries into `~/.claude/settings.json` (other tools' hooks untouched; one-time `.ao-backup`). The script no-ops unless `$TMUX` is our socket and writes one JSON file per event to `events/`; `HookEventWatcher` maps `TMUX_PANE` → session (subscription map, `display-message` fallback) → agent. Notification/Stop flag `attention` (orange orb, Dock badge, bounce) and post a notification. **System notifications are refused for non-Apple-signed builds** ("Notifications are not allowed for this application" — ad-hoc *and* self-signed alike), so `ToastCenter` shows floating in-app panels instead; the system path is used automatically if ever authorized. Claude Code snapshots hooks at startup: agents running before Install must be restarted. `hooks.log` records every step.

**Orphans.** tmux sessions on our socket with no `Agent` record (e.g. after "Remove Folder, Keep Agents Running") are listed as "Unmanaged Sessions" in the sidebar with adopt/kill actions, never silently dropped. `AppState.reconcileSessions` only prunes agents whose session is gone; it never kills a live session.

## Conventions worth knowing

- Persistence is `Store` → `state.json` on every mutation; new fields must be optional in `PersistedState` (or defaulted on load) so existing state files keep decoding.
- `@Observable` + `@MainActor` throughout; delegate callbacks from SwiftTerm/DispatchSource hop to the main actor. SwiftTerm is pinned to `1.20.0` (its `LocalProcessTerminalViewDelegate` is *not* `@MainActor` and has no `processFailedToStart`).
- Sandbox is off and must stay off (arbitrary PATH tools, Unix socket, forkpty).
- Signing: `make bundle` uses the "Agent Organizer Dev" identity when present so the code-signature-tied permissions survive rebuilds; falls back to ad-hoc.
- Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; commit only when asked.
