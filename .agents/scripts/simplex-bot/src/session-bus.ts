/** SimpleX session-bus bridge. Chat content is never passed to a shell. */
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { executeCommand, type RunnerResult } from "./runner";
import type { CommandContext } from "./types";

export type BusRunner = (args: string[], timeout?: number, preserveOutput?: boolean) => Promise<RunnerResult>;

export function chatRef(ctx: CommandContext): string {
  if (ctx.group) return `g${ctx.group.groupId}`;
  if (ctx.contact) return `c${ctx.contact.contactId}`;
  throw new Error("Missing SimpleX chat identity");
}

async function actorFor(ref: string, run: BusRunner): Promise<string> {
  // A group is not an individual sender. Never elevate it to owner identity.
  if (!ref.startsWith("c")) return "";
  const result = await run([join(homedir(), ".aidevops/agents/scripts/entity-helper.sh"), "resolve", "--channel", "simplex", "--channel-id", ref, "--json"], 30000, true);
  if (!result.success) return "";
  try {
    const entities = JSON.parse(result.output) as Array<{ id?: string }>;
    return entities[0]?.id ?? "";
  } catch { return ""; }
}

async function withText<T>(text: string, dataDir: string | undefined, fn: (file: string) => Promise<T>): Promise<T> {
  const root = dataDir ?? join(homedir(), ".aidevops/.agent-workspace/simplex-bot");
  await mkdir(root, { recursive: true, mode: 0o700 });
  const dir = await mkdtemp(join(root, "bus-"));
  try {
    const file = join(dir, "text");
    await writeFile(file, text, { mode: 0o600, flag: "wx" });
    return await fn(file);
  } finally { await rm(dir, { recursive: true, force: true }); }
}

function display(result: RunnerResult): string {
  return (result.success ? result.output : result.error || result.output).trim() || (result.success ? "Done." : "Session bus command failed.");
}

export async function busCommand(ctx: CommandContext, command: string, dataDir?: string, run: BusRunner = executeCommand): Promise<string> {
  const ref = chatRef(ctx);
  const actor = await actorFor(ref, run);
  const actorArgs = actor ? ["--actor", actor] : [];
  const base = ["aidevops", "sessions"];
  if (command === "sessions") {
    // Redact unless this exact direct channel is confirmed for the configured owner.
    let owner = false;
    if (actor && actor === process.env.AIDEVOPS_SESSION_BUS_OWNER_ENTITY_ID) {
      const links = await run([join(homedir(), ".aidevops/agents/scripts/entity-helper.sh"), "channels", actor, "--json"], 30000, true);
      try {
        const rows = JSON.parse(links.output) as Array<Record<string, unknown>>;
        owner = links.success && rows.some(row => row.channel === "simplex" && row.channel_id === ref && row.confidence === "confirmed" && typeof row.verified_at === "string" && row.verified_at.length > 0);
      } catch { owner = false; }
    }
    return display(await run([...base, "list", ...(owner ? [] : ["--redact"])], 30000, true));
  }
  if (command === "unbind") return display(await run([...base, "unbind", "simplex", ref]));
  if (command === "bind") {
    if (ctx.args.length !== 1 || ctx.args[0].startsWith("-")) return "Usage: /bind <target>";
    return display(await run([...base, "bind", "simplex", ref, ctx.args[0], ...actorArgs]));
  }
  if (command === "launch") {
    const body = ctx.rawText.replace(/^\/launch\s*/, "");
    const separator = body.indexOf("::");
    const title = body.slice(0, separator).trim();
    const text = body.slice(separator + 2).trim();
    if (separator < 0 || !title || !text) return "Usage: /launch <title> :: <task>";
    return withText(text, dataDir, async file => display(await run([...base, "launch", "--bind", `simplex:${ref}`, "--title", title, ...actorArgs, "--text-file", file])));
  }
  const [target, ...words] = ctx.args;
  if (!target || target.startsWith("-") || !words.length) return `Usage: /${command} <target> <text>`;
  return withText(words.join(" "), dataDir, async file => display(await run([...base, command, target, "--origin", `chat:simplex:${ref}`, ...actorArgs, "--text-file", file])));
}

/** Relay sequentially; failures leave messages in the outbox for retry. */
export async function relayOutbox(send: (channel: string, text: string) => Promise<void>, run: BusRunner = executeCommand): Promise<void> {
  const result = await run(["aidevops", "sessions", "outbox", "simplex", "--json"], 30000, true);
  if (!result.success) throw new Error("Session bus outbox read failed");
  const messages: unknown = JSON.parse(result.output);
  if (!Array.isArray(messages)) throw new Error("Invalid session bus outbox");
  for (const message of messages) {
    if (!message || typeof message.id !== "string" || !/^[A-Za-z0-9_-]+$/.test(message.id) || typeof message.channel !== "string" || !/^[cg][0-9]+$/.test(message.channel) || typeof message.text !== "string") continue;
    try {
      await send(message.channel, message.text);
      const ack = await run(["aidevops", "sessions", "outbox", "simplex", "--ack", message.id]);
      if (!ack.success) throw new Error("Outbox acknowledgement failed");
    } catch { /* Preserve failed messages for the next tick. */ }
  }
}
