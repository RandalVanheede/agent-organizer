/**
 * Agent Organizer extension for Pi (installed by the Agent Organizer app into
 * ~/.pi/agent/extensions/; removed by its Uninstall).
 *
 * Reports run state to the app through its `ao-hook` script: an event file on
 * the Mac, a token-checked private OSC through the pane on a remote. Uses the
 * same event names as Claude Code's hooks, so the app needs nothing new.
 * Outside the app's tmux panes it does nothing.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// AO_SESSION is set only in the app's remote panes; local panes run on the app's tmux socket.
const PROBE = `if [ -n "$AO_SESSION" ] && [ -x "$HOME/.cache/agent-organizer/bin/ao-hook" ]; then echo remote; else case "$TMUX" in *"Agent Organizer/tmux.sock"*) [ -x "$HOME/Library/Application Support/Agent Organizer/bin/ao-hook" ] && echo mac ;; esac; fi`;
const HOOK = {
	mac: '"$HOME/Library/Application Support/Agent Organizer/bin/ao-hook"',
	remote: '"$HOME/.cache/agent-organizer/bin/ao-hook"',
};

export default function (pi: ExtensionAPI) {
	let where: "" | "mac" | "remote" = "";
	let outcome: "completed" | "aborted" | "error" = "completed";

	// pi.exec has no stdin: the payload goes as an argument and is piped in by sh.
	async function send(event: string, payload: Record<string, unknown> = {}) {
		if (!where) return;
		const script = `printf '%s' "$1" | exec ${HOOK[where]} "$0"`;
		await pi.exec("sh", ["-c", script, event, JSON.stringify({ ...payload, source: "pi" })], { timeout: 5000 }).catch(() => undefined);
	}

	pi.on("session_start", async () => {
		const result = await pi.exec("sh", ["-c", PROBE], { timeout: 5000 }).catch(() => undefined);
		const found = result?.stdout.trim();
		where = found === "mac" || found === "remote" ? found : "";
	});

	// Can fire more than once per prompt (auto-retry, queued work); the app treats it as idempotent.
	pi.on("agent_start", async () => {
		outcome = "completed";
		await send("UserPromptSubmit");
	});

	// Aborted runs skip this event; errors are only visible here.
	pi.on("agent_before_settle", async (event) => {
		outcome = event.outcome;
	});

	// Final idle signal: no retry, compaction or queued continuation follows.
	pi.on("agent_settled", async (event) => {
		if (event.aborted) await send("TurnEnd", { reason: "aborted" });
		else if (outcome === "error") await send("TurnEnd", { reason: "error" });
		else await send("Stop");
	});

	// A confirm/select/input dialog blocks on the user: "needs you" in the app.
	pi.on("ui_prompt_start", async (event) => {
		await send("Notification", { notification_type: "permission_prompt", message: String(event.title || "Pi is waiting for you.").slice(0, 300) });
	});
}
