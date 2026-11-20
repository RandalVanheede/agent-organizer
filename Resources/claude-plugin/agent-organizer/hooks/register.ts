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
// And no session.append: the built-in plugin skips it now and then, and each
// skip posts a notice into the user's conversation.
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
