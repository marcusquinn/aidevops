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

const SESSION_COMMAND = ["aidevops", "sessions"];

interface BusCommandOptions {
  ctx: CommandContext;
  ref: string;
  actor: string;
  actorArgs: string[];
  dataDir?: string;
  run: BusRunner;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isConfirmedChannel(value: unknown, ref: string): boolean {
  if (!isRecord(value)) return false;
  if (value.channel !== "simplex" || value.channel_id !== ref) return false;
  if (value.confidence !== "confirmed") return false;
  return typeof value.verified_at === "string" && value.verified_at.length > 0;
}

/** Redact unless this exact direct channel is confirmed for the owner. */
async function isOwnerChannel({ actor, ref, run }: BusCommandOptions): Promise<boolean> {
  if (!actor || actor !== process.env.AIDEVOPS_SESSION_BUS_OWNER_ENTITY_ID) return false;
  const links = await run([join(homedir(), ".aidevops/agents/scripts/entity-helper.sh"), "channels", actor, "--json"], 30000, true);
  if (!links.success) return false;
  try {
    const rows: unknown = JSON.parse(links.output);
    return Array.isArray(rows) && rows.some(row => isConfirmedChannel(row, ref));
  } catch { return false; }
}

async function listSessions(options: BusCommandOptions): Promise<string> {
  const owner = await isOwnerChannel(options);
  return display(await options.run([...SESSION_COMMAND, "list", ...(owner ? [] : ["--redact"])], 30000, true));
}

async function bindSession({ ctx, ref, actorArgs, run }: BusCommandOptions): Promise<string> {
  if (ctx.args.length !== 1 || ctx.args[0].startsWith("-")) return "Usage: /bind <target>";
  return display(await run([...SESSION_COMMAND, "bind", "simplex", ref, ctx.args[0], ...actorArgs]));
}

async function launchSession({ ctx, ref, actorArgs, dataDir, run }: BusCommandOptions): Promise<string> {
  const body = ctx.rawText.replace(/^\/launch\s*/, "");
  const separator = body.indexOf("::");
  const title = body.slice(0, separator).trim();
  const text = body.slice(separator + 2).trim();
  if (separator < 0 || !title || !text) return "Usage: /launch <title> :: <task>";
  return withText(text, dataDir, async file => display(await run([...SESSION_COMMAND, "launch", "--bind", `simplex:${ref}`, "--title", title, ...actorArgs, "--text-file", file])));
}

async function sendSessionText(command: string, { ctx, ref, actorArgs, dataDir, run }: BusCommandOptions): Promise<string> {
  const [target, ...words] = ctx.args;
  if (!target || target.startsWith("-") || !words.length) return `Usage: /${command} <target> <text>`;
  return withText(words.join(" "), dataDir, async file => display(await run([...SESSION_COMMAND, command, target, "--origin", `chat:simplex:${ref}`, ...actorArgs, "--text-file", file])));
}

const BUS_COMMANDS: Record<string, (options: BusCommandOptions) => Promise<string>> = {
  sessions: listSessions,
  bind: bindSession,
  launch: launchSession,
  unbind: async ({ ref, run }) => display(await run([...SESSION_COMMAND, "unbind", "simplex", ref])),
};

export async function busCommand(ctx: CommandContext, command: string, dataDir?: string, run: BusRunner = executeCommand): Promise<string> {
  const ref = chatRef(ctx);
  const actor = await actorFor(ref, run);
  const options = { ctx, ref, actor, actorArgs: actor ? ["--actor", actor] : [], dataDir, run };
  const handler = Object.hasOwn(BUS_COMMANDS, command) ? BUS_COMMANDS[command] : undefined;
  return handler ? handler(options) : sendSessionText(command, options);
}

interface OutboxMessage {
  id: string;
  channel: string;
  text: string;
}

function isOutboxMessage(value: unknown): value is OutboxMessage {
  if (!isRecord(value)) return false;
  const validId = typeof value.id === "string" && /^[A-Za-z0-9_-]+$/.test(value.id);
  const validChannel = typeof value.channel === "string" && /^[cg][0-9]+$/.test(value.channel);
  return validId && validChannel && typeof value.text === "string";
}

/** Relay sequentially; failures leave messages in the outbox for retry. */
export async function relayOutbox(send: (channel: string, text: string) => Promise<void>, run: BusRunner = executeCommand): Promise<void> {
  const result = await run(["aidevops", "sessions", "outbox", "simplex", "--json"], 30000, true);
  if (!result.success) throw new Error("Session bus outbox read failed");
  const messages: unknown = JSON.parse(result.output);
  if (!Array.isArray(messages)) throw new Error("Invalid session bus outbox");
  for (const message of messages) {
    if (!isOutboxMessage(message)) continue;
    let stage: "send" | "ack" = "send";
    try {
      await send(message.channel, message.text);
      stage = "ack";
      const ack = await run(["aidevops", "sessions", "outbox", "simplex", "--ack", message.id]);
      if (!ack.success) throw new Error("Outbox acknowledgement failed");
    } catch { warnRelayFailure(message.id, stage); /* Preserve failed messages for the next tick. */ }
  }
}

const RELAY_WARN_INTERVAL_MS = 60_000;
const RELAY_WARN_MAX_TRACKED = 100;
const relayWarned = new Map<string, number>();

/** Rate-limited, bounded warning; logs id and stage only, never message text. */
function warnRelayFailure(id: string, stage: "send" | "ack"): void {
  const key = `${id}:${stage}`;
  const now = Date.now();
  const last = relayWarned.get(key);
  if (last !== undefined && now - last < RELAY_WARN_INTERVAL_MS) return;
  if (relayWarned.size >= RELAY_WARN_MAX_TRACKED) {
    const oldest = relayWarned.keys().next().value;
    if (oldest !== undefined) relayWarned.delete(oldest);
  }
  relayWarned.delete(key);
  relayWarned.set(key, now);
  console.warn(`Session bus outbox ${stage} failed for message ${id}; will retry`);
}
