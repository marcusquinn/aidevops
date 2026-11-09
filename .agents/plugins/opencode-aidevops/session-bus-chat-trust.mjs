// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// Local gateway ingest only. Entity labels and chat text never grant authority.
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { isSafeId, parseChatOrigin, readJson, writeJsonAtomic } from "./session-bus-files.mjs";
import { readPresence } from "./session-bus-presence-store.mjs";
import { resolveTarget } from "./session-bus-targets.mjs";

const scripts = fileURLToPath(new URL("../../scripts/", import.meta.url));
const run = (name, args, env, input) => spawnSync(join(scripts, name), args, {
  env, input, encoding: "utf8", timeout: 15_000, maxBuffer: 256 * 1024,
});

function entityJson(args, env) {
  const result = run("entity-helper.sh", args, env);
  if (result.error || result.status !== 0) throw new Error("entity lookup failed");
  return JSON.parse(result.stdout);
}

function confirmedLink(link) {
  return link.confidence === "confirmed" && typeof link.verified_at === "string" && link.verified_at.length > 0;
}

function actorLink(link, actor, chat) {
  if (!confirmedLink(link)) return false;
  return link.entity_id === actor && link.channel === chat.app && link.channel_id === chat.channel;
}

function resolveActor(actor, chat, env) {
  if (!isSafeId(actor)) return { actor: "", verified: false, owner: false };
  const unverified = { actor, verified: false, owner: false };
  try {
    const links = entityJson(["channels", actor, "--json"], env);
    const verified = Array.isArray(links) && links.some((link) => actorLink(link, actor, chat));
    if (!verified) return unverified;
    const entities = entityJson(["get", actor, "--json"], env);
    const entity = Array.isArray(entities) && entities.find((row) => row.id === actor);
    if (!entity) return unverified;
    return { actor, verified: true, owner: actor === env.AIDEVOPS_SESSION_BUS_OWNER_ENTITY_ID,
      name: String(entity.display_name || entity.name || actor).replace(/[\r\n\u0000-\u001F\u007F]/g, " ").slice(0, 80) };
  } catch {
    return unverified;
  }
}

export function chatTrust(origin, actor, text, env = process.env) {
  const chat = parseChatOrigin(origin);
  if (!chat) throw new Error("invalid chat origin");
  // Resolve provenance before screening. The result cannot bypass the scan.
  const identity = resolveActor(actor, chat, env);
  const result = run("prompt-guard-helper.sh", ["scan-stdin"], env, text);
  if (result.error || result.signal) throw new Error("chat scan refused: scanner error or timeout");
  if (result.status !== 0 || result.stdout.trim() !== "CLEAN") {
    // Never echo scanner stderr: findings can contain message text or secrets.
    const reason = result.status === 2 ? "incomplete scan" : "blocking finding or scanner error";
    throw new Error(`chat scan refused: ${reason}`);
  }
  return { ...identity, scan: { status: "clean", engine: "prompt-guard" } };
}

export function setChatWake(root, sessionID, enabled) {
  if (!isSafeId(sessionID) || typeof enabled !== "boolean") throw new Error("invalid chat-wake setting");
  writeJsonAtomic(join(root, "chat-wake", `${sessionID}.json`), { enabled, updated_ms: Date.now() });
}

export function chatWakeEnabled(root, sessionID) {
  if (!isSafeId(sessionID)) return false;
  const setting = readJson(join(root, "chat-wake", `${sessionID}.json`));
  return setting?.enabled === true && Number.isFinite(setting.updated_ms) && setting.updated_ms > 0;
}

export function chatWakeCommand({ root, options, out }) {
  const [, target, setting] = options.positional;
  if (!["on", "off"].includes(setting)) throw new Error("chat-wake needs <target> on|off");
  const resolved = resolveTarget(readPresence(root), target, "", { root });
  if (resolved.error) throw new Error(resolved.error);
  const sessionID = resolved.record?.session_id || resolved.sessionID;
  setChatWake(root, sessionID, setting === "on");
  out.write(`Chat owner wakes ${setting} for ${sessionID}.\n`);
}
