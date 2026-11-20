import type { Register, EngineInterface } from 'claude-code'

// Agent Organizer (a macOS app) runs each agent in a tmux pane on its own
// socket, or over ssh in a remote's `tmux -L agent-organizer` pane. This module
// hands Claude Code's events to the app's `ao-hook` script, which drops an
// event file (Mac) or writes a private OSC to the pane (remote). Outside those
// panes `where` stays '' and nothing is ever spawned.
//
// Native events only. A mod's classic.* hooks (Stop, Notification, PreToolUse,
// ...) are skipped by Claude Code's built-in plugins, each with a notice in the
// conversation; on the Mac those come from settings.json hooks instead. Never a
// catch-all tool.call/tool.run hook either: any hook that may match a tool there
// turns off its move to the background and its live output, in every session.
const MAC_HOOK = '$HOME/Library/Application Support/Agent Organizer/bin/ao-hook'
const REMOTE_HOOK = '$HOME/.cache/agent-organizer/bin/ao-hook'
// AO_SESSION is set only in the app's remote panes.
const PROBE = `if [ -n "$AO_SESSION" ] && [ -x "${REMOTE_HOOK}" ]; then echo remote; else case "$TMUX" in *"Agent Organizer/tmux.sock"*) [ -x "${MAC_HOOK}" ] && echo mac ;; esac; fi`
const NOTIFY = 'mcp__agent-organizer__notify'

let where: '' | 'mac' | 'remote' = ''
let probed: Promise<void> | undefined

/** Once per load: also covers a load mid-session (install + /reload-plugins), where session.start doesn't fire. */
function probe($: EngineInterface): Promise<void> {
  probed ??= $.process
    .run(['sh', '-c', PROBE], { timeoutMs: 5000 })
    .then(({ stdout }) => {
      const found = stdout.trim()
      where = found === 'mac' || found === 'remote' ? found : ''
    })
    .catch(() => {
      where = ''
    })
  return probed
}

async function send($: EngineInterface, event: string, payload: Record<string, unknown>) {
  await probe($)
  if (!where) return
  try {
    await $.process.run(['sh', '-c', `exec "${where === 'mac' ? MAC_HOOK : REMOTE_HOOK}" "$0"`, event], {
      stdin: JSON.stringify({ ...payload, source: 'mod' }),
      timeoutMs: 5000,
    })
  } catch {
    // The app being gone must never break Claude.
  }
}

/** A short label for the running tool: the program, file name, pattern or URL. */
function detail(input: Record<string, unknown>): string {
  for (const key of ['command', 'file_path', 'notebook_path', 'pattern', 'url', 'description', 'query']) {
    const value = input[key]
    if (typeof value !== 'string' || !value) continue
    const text = key === 'command' ? program(value) : key === 'url' ? urlLabel(value) : key.endsWith('_path') ? (value.split('/').pop() ?? value) : value
    return text.replace(/\s+/g, ' ').slice(0, 80)
  }
  return ''
}

/** Tools whose second word is a subcommand, not data. */
const SUBCOMMAND_TOOLS = /^(git|npm|pnpm|yarn|bun|npx|docker|kubectl|cargo|make|swift|brew|go|composer|ddev|drush|gh|terraform)$/

/** "npm test", "git status", else the program name alone: arguments may hold secrets (`mysql -pX`, `echo hunter2`). */
function program(command: string): string {
  const words = command.trim().split(/\s+/)
  while (words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0] ?? '')) words.shift() // `API_KEY=… npm test`
  const name = (words[0] ?? '').split('/').pop() ?? ''
  if (!/^[A-Za-z0-9._+-]+$/.test(name)) return ''
  const next = words[1] ?? ''
  return SUBCOMMAND_TOOLS.test(name) && /^[a-z][a-z0-9:-]*$/.test(next) ? `${name} ${next}` : name
}

/** Host only: paths and query strings can carry tokens (webhooks, `/bot<token>/`). */
function urlLabel(url: string): string {
  try {
    return new URL(url).host
  } catch {
    return ''
  }
}

type Block = { type?: unknown; id?: unknown; name?: unknown; input?: unknown; tool_use_id?: unknown }

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await probe($)
    if (where) {
      await $.tool
        .register({
          name: 'notify',
          description:
            'Notify the user through the Agent Organizer app (sound, Dock badge, toast). Use when the user asked to be told when something is done, or a long task finished while they are likely away. Keep the message under one sentence.',
          inputSchema: {
            type: 'object',
            properties: { message: { type: 'string', description: 'What to tell the user.' } },
            required: ['message'],
          },
          isDeferred: true,
        })
        .catch(() => undefined)
    }
    return next(e)
  })

  // Remote panes have no settings hooks, so the turn start comes from here.
  on('turn.start', async ($, e, next) => {
    await probe($)
    if (where === 'remote' && e.agentId === undefined) await send($, 'UserPromptSubmit', {})
    return next(e)
  })

  // The Stop hook fires for answers only; this also sees Esc (`aborted`) and
  // API errors. On the Mac, answers stay with the settings Stop hook.
  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId === undefined) {
      const isAnswer = e.reason === 'answer' || e.reason === 'refusal'
      if (!isAnswer) await send($, 'TurnEnd', { reason: e.reason })
      else if (where === 'remote') await send($, 'Stop', { reason: e.reason })
    }
    return result
  })

  // The running tool, read off the main conversation's rows: a response's
  // tool_use block starts it, the tool_result row ends it (ids; tools run in parallel).
  on('session.append', async ($, e, next) => {
    const result = await next(e)
    const content = e.message.content
    if (e.agentId !== undefined || !Array.isArray(content)) return result
    for (const block of content as Block[]) {
      if (block.type === 'tool_use' && typeof block.id === 'string' && typeof block.name === 'string' && block.name !== NOTIFY) {
        const input = typeof block.input === 'object' && block.input ? (block.input as Record<string, unknown>) : {}
        await send($, 'ToolStart', { id: block.id, tool: block.name, detail: detail(input) })
      } else if (block.type === 'tool_result' && typeof block.tool_use_id === 'string') {
        await send($, 'ToolEnd', { id: block.tool_use_id })
      }
    }
    return result
  })

  // Served at tool.run: the engine refuses $.process.run ahead of the
  // permission check. Matches only this plugin's own tool.
  on('tool.run', { tool: NOTIFY }, async ($, e, next) => {
    await probe($)
    if (!where) return next(e)
    const message = (e as unknown as { message?: unknown }).message
    await send($, 'AONotify', { message: typeof message === 'string' ? message.slice(0, 300) : '' })
    return { result: 'The user was notified.' }
  }).catch(() => ({ deny: 'Agent Organizer could not be notified.' }))
}
