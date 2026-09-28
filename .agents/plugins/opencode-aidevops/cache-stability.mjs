// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2026 Marcus Quinn

import { createHash } from "node:crypto";

// Prompt-cache stability diagnostics (GH#32744).
//
// Anthropic caches the request prefix in order: tools → system → messages.
// Any byte change in an earlier segment forces every later token to be
// re-written at the cache-write price. llm_requests shows *that* a turn
// re-wrote its cache, but not *which* segment changed. This monitor keeps a
// small per-session fingerprint of the final wire body and logs the first
// changed stable segment, so a break can be attributed from the plugin log.
//
// It never mutates the request. Moving cache_control markers and the per-request
// billing header are excluded from fingerprints because they change by design.

const DEFAULT_MAX_SESSIONS = 64;
const SNIPPET_CHARS = 80;
const BILLING_HEADER_PREFIX = "x-anthropic-billing-header:";
const PRUNED_TOOL_RESULT = /^(?:\[[^\]]{1,80}\]|<[^>]{1,80}>|…|\.\.\.|(?:tool )?(?:output|result) (?:was )?(?:pruned|omitted|removed|truncated)|pruned\b)/i;

const withoutCacheControl = (key, value) => (key === "cache_control" ? undefined : value);

function hash(value) {
  const text = typeof value === "string" ? value : JSON.stringify(value, withoutCacheControl) ?? "";
  return createHash("sha256").update(text).digest("hex").slice(0, 12);
}

function snippet(text) {
  const oneLine = String(text ?? "").replace(/\s+/g, " ").trim();
  return JSON.stringify(oneLine.length > SNIPPET_CHARS ? `${oneLine.slice(0, SNIPPET_CHARS)}…` : oneLine);
}

function toolFingerprints(tools) {
  const entries = Array.isArray(tools) ? tools : [];
  return entries.map((tool, index) => [String(tool?.name ?? `#${index}`), hash(tool)]);
}

function systemFingerprint(system) {
  const blocks = Array.isArray(system) ? system : [];
  return hash(blocks.filter((block) => !(block?.type === "text" && block.text?.startsWith(BILLING_HEADER_PREFIX))));
}

function prefixText(messages) {
  const first = Array.isArray(messages) ? messages[0] : null;
  const block = Array.isArray(first?.content) ? first.content[0] : null;
  return block?.type === "text" && typeof block.text === "string" ? block.text : "";
}

function blockText(block) {
  const text = typeof block === "string" ? block : block?.text ?? block?.content;
  if (typeof text === "string") return text;
  return JSON.stringify(block, withoutCacheControl) ?? "";
}

function fingerprintBlock(block) {
  const text = blockText(block);
  const type = typeof block === "string" ? "text" : String(block?.type ?? "unknown");
  return {
    hash: hash(block),
    type,
    chars: text.length,
    preview: snippet(text),
    pruningCandidate: type === "tool_result" && PRUNED_TOOL_RESULT.test(text),
  };
}

function messageBlocks(message) {
  const content = message?.content;
  const blocks = Array.isArray(content) ? content : [typeof content === "string" ? { type: "text", text: content } : content];
  return blocks.filter((block) => block != null).map(fingerprintBlock);
}

function requestFamily(parsed) {
  const family = parsed?.tools?.length ? "agent" : "aux";
  return { family, key: `${parsed?.model ?? ""}\u0000${family}` };
}

/** Fingerprint the cache-relevant segments of a parsed Anthropic request body. */
export function fingerprintRequest(parsed, account) {
  const messages = Array.isArray(parsed?.messages) ? parsed.messages : [];
  const family = requestFamily(parsed);
  return {
    family: family.family,
    familyKey: family.key,
    account: account ? hash(String(account)).slice(0, 8) : "",
    tools: toolFingerprints(parsed?.tools),
    system: systemFingerprint(parsed?.system),
    thinking: hash({ thinking: parsed?.thinking ?? null, tool_choice: parsed?.tool_choice ?? null }),
    prefix: prefixText(messages),
    messages: messages.map(messageBlocks),
    roles: messages.map((message) => message?.role ?? "?"),
  };
}

function diffTools(previous, current) {
  const before = new Map(previous);
  const after = new Map(current);
  const added = [...after.keys()].filter((name) => !before.has(name));
  const removed = [...before.keys()].filter((name) => !after.has(name));
  const changed = [...after.keys()].filter((name) => before.has(name) && before.get(name) !== after.get(name));
  const sameSet = added.length === 0 && removed.length === 0 && changed.length === 0;
  const reordered = sameSet && previous.map(([name]) => name).join("\n") !== current.map(([name]) => name).join("\n");
  if (sameSet && !reordered) return null;
  const list = (names) => `[${names.slice(0, 8).join(",")}${names.length > 8 ? ",…" : ""}]`;
  return `segment=tools added=${list(added)} removed=${list(removed)} changed=${list(changed)}${reordered ? " reordered=true" : ""}`;
}

function diffPrefix(previous, current) {
  if (previous === current) return null;
  const before = previous.split("\n");
  const after = current.split("\n");
  let line = 0;
  while (line < before.length && line < after.length && before[line] === after[line]) line += 1;
  return `segment=prefix chars=${previous.length}->${current.length} line=${line + 1} was=${snippet(before[line])} now=${snippet(after[line])}`;
}

function changedHistoryIndexes(previous, current) {
  const shared = previous.messages.slice(0, current.messages.length);
  return shared.flatMap((message, index) => (hash(message) === hash(current.messages[index]) ? [] : [index]));
}

function describeHistoryChange(previous, current, index, count) {
  const before = previous.messages[index];
  const after = current.messages[index];
  const shared = Math.min(before.length, after.length);
  const block = before.slice(0, shared).findIndex((entry, position) => entry.hash !== after[position].hash);
  const position = block < 0 ? shared : block;
  const beforeBlock = before[position];
  const afterBlock = after[position];
  const change = !beforeBlock ? "added" : !afterBlock ? "removed" : "modified";
  const target = afterBlock ?? beforeBlock;
  const tail = index >= previous.messages.length - 1 ? " tail=true" : "";
  const messagesChanged = count > 1 ? ` messages_changed=${count}` : "";
  const now = target.type === "tool_result" && change === "modified" && afterBlock?.pruningCandidate ? ` now=${afterBlock.preview}` : "";
  return `segment=history index=${index}/${previous.messages.length} role=${current.roles[index]} block=${position}/${Math.max(before.length, after.length)} type=${target.type} change=${change} chars=${beforeBlock?.chars ?? 0}->${afterBlock?.chars ?? 0}${tail}${messagesChanged}${now}`;
}

function diffHistory(previous, current) {
  const changed = changedHistoryIndexes(previous, current);
  if (changed.length > 0) return describeHistoryChange(previous, current, changed[0], changed.length);
  return current.messages.length < previous.messages.length ? `segment=history shrink=${previous.messages.length}->${current.messages.length}` : null;
}

/** Describe every stable segment that changed between two consecutive fingerprints. */
export function describeCacheChanges(previous, current) {
  if (!previous) return [];
  const changes = [];
  if (previous.account !== current.account) changes.push(`segment=account from=${previous.account || "-"} to=${current.account || "-"}`);
  const tools = diffTools(previous.tools, current.tools);
  if (tools) changes.push(tools);
  if (previous.system !== current.system) changes.push("segment=system");
  if (previous.thinking !== current.thinking) changes.push("segment=thinking");
  const prefix = diffPrefix(previous.prefix, current.prefix);
  if (prefix) changes.push(prefix);
  // Earlier-segment changes already invalidate history; report history only when it is the first break.
  if (changes.length === 0) {
    const history = diffHistory(previous, current);
    if (history) changes.push(history);
  }
  return changes;
}

/**
 * @param {{ log?: (line: string) => void, maxSessions?: number, enabled?: () => boolean }} [options]
 */
export function createCacheStabilityMonitor(options = {}) {
  const log = options.log ?? ((line) => console.error(line));
  const maxSessions = options.maxSessions ?? DEFAULT_MAX_SESSIONS;
  const enabled = options.enabled ?? (() => process.env.AIDEVOPS_CACHE_STABILITY_LOG !== "0");
  const sessions = new Map();
  return {
    /** Record one outgoing request; returns the logged change descriptors. */
    observe(parsed, { sessionID, account } = {}) {
      try {
        if (!sessionID || !enabled()) return [];
        const current = fingerprintRequest(parsed, account);
        const sessionKey = `${sessionID}\u0000${current.familyKey}`;
        const previous = sessions.get(sessionKey);
        sessions.delete(sessionKey);
        sessions.set(sessionKey, current);
        while (sessions.size > maxSessions) sessions.delete(sessions.keys().next().value);
        const changes = describeCacheChanges(previous, current);
        for (const change of changes) log(`[aidevops] cache-stability: session=${sessionID} family=${current.family} ${change}`);
        return changes;
      } catch {
        return [];
      }
    },
  };
}
