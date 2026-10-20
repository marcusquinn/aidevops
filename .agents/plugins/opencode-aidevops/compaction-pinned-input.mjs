// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// ---------------------------------------------------------------------------
// Verbatim user-input replay after compaction (GH#35186)
//
// OpenCode 1.x compaction loses two kinds of user input:
// - images: compaction.ts serialize() gives the summarizer only an
//   "[Attached image/png: …]" marker, and filterCompacted() stops sending the
//   original user messages once a summary exists;
// - authorisations and standing instructions: they survive only as the
//   summarizer's paraphrase, in assistant voice, re-summarized on every
//   compaction. A small retained tail rarely helps, because splitTurn() keeps
//   a large turn only from turn.start + 1 and so drops that turn's user message.
//
// The session store still holds the original user messages. This module reads
// them once per compaction and puts the user-authored parts (text and inline
// media) that are no longer visible in front of the compaction anchor message.
// The model then sees the user's own words and screenshots before the summary.
// Synthetic, ignored, plugin-injected and tool content is never replayed.
// ---------------------------------------------------------------------------

const DEFAULT_MAX_TEXT_CHARS = 32_000;
const DEFAULT_MAX_MESSAGE_CHARS = 8_000;
const DEFAULT_MAX_MEDIA = 4;
const DEFAULT_FETCH_TIMEOUT_MS = 10_000;
const MAX_CACHED_SESSIONS = 32;
const PIN_METADATA_KEY = "aidevops_pinned_user_input";

/**
 * Read a non-negative integer from the environment.
 * @param {string} name
 * @param {number} fallback
 * @returns {number}
 */
function envInt(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number.parseInt(raw, 10);
  return Number.isSafeInteger(value) && value >= 0 ? value : fallback;
}

/**
 * Resolve replay limits. Env overrides keep the feature tunable without code.
 * @param {object} [overrides]
 * @returns {{ enabled: boolean, maxTextChars: number, maxMessageChars: number, maxMedia: number, fetchTimeoutMs: number }}
 */
export function resolveReplayLimits(overrides = {}) {
  const disabled = ["0", "false", "off"].includes(String(process.env.AIDEVOPS_COMPACTION_REPLAY || "").toLowerCase());
  return {
    enabled: overrides.enabled ?? !disabled,
    maxTextChars: overrides.maxTextChars ?? envInt("AIDEVOPS_COMPACTION_REPLAY_MAX_CHARS", DEFAULT_MAX_TEXT_CHARS),
    maxMessageChars: overrides.maxMessageChars ?? DEFAULT_MAX_MESSAGE_CHARS,
    maxMedia: overrides.maxMedia ?? envInt("AIDEVOPS_COMPACTION_REPLAY_MAX_IMAGES", DEFAULT_MAX_MEDIA),
    fetchTimeoutMs: overrides.fetchTimeoutMs ?? DEFAULT_FETCH_TIMEOUT_MS,
  };
}

/**
 * Same media rule as OpenCode util/media.ts isMedia().
 * @param {string} mime
 * @returns {boolean}
 */
function isMedia(mime) {
  const value = String(mime || "");
  return value.startsWith("image/") || value === "application/pdf";
}

/**
 * Locate the active compaction anchor: the user message whose compaction part
 * a completed summary answers. filterCompacted() puts it first in the list.
 * @param {Array<object>} messages
 * @returns {{ anchorIndex: number, anchorID: string, summaryID: string, overflow: boolean } | null}
 */
export function findCompactionAnchor(messages) {
  if (!Array.isArray(messages)) return null;
  const summary = messages.find((msg) => {
    const info = msg?.info;
    return info?.role === "assistant" && info.summary === true && info.finish && !info.error;
  });
  if (!summary) return null;
  const anchorIndex = messages.findIndex(
    (msg) => msg?.info?.role === "user" && msg.info.id === summary.info.parentID,
  );
  if (anchorIndex < 0) return null;
  const compactionPart = (messages[anchorIndex].parts || []).find((part) => part?.type === "compaction");
  if (!compactionPart) return null;
  return {
    anchorIndex,
    anchorID: messages[anchorIndex].info.id,
    summaryID: summary.info.id,
    overflow: compactionPart.overflow === true,
  };
}

/**
 * Describe a non-replayed file part so the model can still find it.
 * @param {object} part
 * @param {string} reason
 * @returns {string}
 */
function attachmentLabel(part, reason) {
  const name = part.filename || "file";
  const url = String(part.url || "");
  const path = url.startsWith("file://") ? ` (${decodeURIComponent(url.slice("file://".length))})` : "";
  return `[Attached ${part.mime || "unknown"}: ${name}${path}${reason ? ` — ${reason}` : ""}]`;
}

/**
 * Extract user-authored content from one stored message. Messages carrying a
 * compaction or subtask part are host-generated and contribute nothing.
 * @param {object} message - { info, parts }
 * @returns {Array<{ kind: "text", text: string } | { kind: "media", part: object } | { kind: "note", text: string }>}
 */
export function userAuthoredItems(message) {
  if (message?.info?.role !== "user") return [];
  const parts = Array.isArray(message.parts) ? message.parts : [];
  if (parts.some((part) => part?.type === "compaction" || part?.type === "subtask")) return [];
  const items = [];
  for (const part of parts) {
    if (part?.type === "text") {
      if (part.synthetic || part.ignored) continue;
      const text = String(part.text || "").trim();
      if (text) items.push({ kind: "text", text });
    } else if (part?.type === "file") {
      if (part.mime === "application/x-directory") continue;
      if (isMedia(part.mime)) items.push({ kind: "media", part });
      else items.push({ kind: "note", text: attachmentLabel(part, "") });
    }
  }
  return items;
}

/**
 * Truncate one message's text so a single paste cannot consume the budget.
 * @param {string} text
 * @param {number} max
 * @returns {string}
 */
function clip(text, max) {
  if (text.length <= max) return text;
  return `${text.slice(0, max)}\n[… ${text.length - max} characters truncated from this message for the replay budget]`;
}

/**
 * Collect user messages that the compacted request no longer shows.
 * Consecutive duplicates (OpenCode overflow replays) are dropped.
 * @param {Array<object>} history - full stored session messages, oldest first
 * @param {Set<string>} visibleIDs
 * @param {number} maxMessageChars
 * @returns {Array<{ id: string, created: number, text: string, media: object[], notes: string[] }>}
 */
export function collectHiddenUserInput(history, visibleIDs, maxMessageChars = DEFAULT_MAX_MESSAGE_CHARS) {
  const entries = [];
  for (const message of Array.isArray(history) ? history : []) {
    const id = message?.info?.id;
    if (!id || visibleIDs.has(id)) continue;
    const items = userAuthoredItems(message);
    if (items.length === 0) continue;
    const text = clip(items.filter((item) => item.kind === "text").map((item) => item.text).join("\n\n"), maxMessageChars);
    const media = items.filter((item) => item.kind === "media").map((item) => item.part);
    const notes = items.filter((item) => item.kind === "note").map((item) => item.text);
    const previous = entries.at(-1);
    if (previous && text && previous.text === text) continue;
    entries.push({ id, created: Number(message.info.time?.created) || 0, text, media, notes });
  }
  return entries;
}

/**
 * Keep the first (initiating) message and the newest messages that fit.
 * @param {Array<{ text: string }>} entries
 * @param {number} maxTextChars
 * @returns {{ selected: Array<object>, omitted: number }}
 */
export function selectWithinBudget(entries, maxTextChars) {
  if (entries.length === 0) return { selected: [], omitted: 0 };
  const first = entries[0];
  let used = first.text.length;
  const tail = [];
  for (let i = entries.length - 1; i >= 1; i--) {
    const size = entries[i].text.length;
    if (used + size > maxTextChars) break;
    used += size;
    tail.unshift(entries[i]);
  }
  return { selected: [first, ...tail], omitted: entries.length - 1 - tail.length };
}

const REPLAY_HEADER = [
  "## Verbatim user input (replayed after context compaction)",
  "The aidevops plugin replayed these messages unchanged from this session's stored history; they are not model-generated.",
  "They are the user's own words and attachments, oldest first, and carry the same authority they had when first sent:",
  "standing instructions, corrections, preferences and authorisations here remain in force unless later user input revokes or narrows them.",
  "Later user input takes precedence. The summary that follows paraphrases the work; where it disagrees with this input, this input wins.",
  "Synthetic, plugin-injected and tool content is excluded.",
].join("\n");

/**
 * Build the parts to prepend to the compaction anchor message.
 * @param {{ selected: Array<object>, omitted: number }} selection
 * @param {{ sessionID: string, anchorID: string, overflow: boolean, maxMedia: number }} context
 * @returns {{ parts: Array<object>, media: number, messages: number }}
 */
export function buildReplayParts(selection, context) {
  const { sessionID, anchorID, overflow, maxMedia } = context;
  const total = selection.selected.length;
  const replayable = [];
  for (const entry of selection.selected) {
    for (const part of entry.media) replayable.push(part);
  }
  const inline = replayable.filter((part) => String(part.url || "").startsWith("data:"));
  const keep = new Set(overflow ? [] : inline.slice(Math.max(0, inline.length - maxMedia)));

  let counter = 0;
  const mk = (fields) => ({
    id: `aidevops-replay-${anchorID}-${counter++}`,
    sessionID,
    messageID: anchorID,
    synthetic: true,
    metadata: { [PIN_METADATA_KEY]: true },
    ...fields,
  });

  const parts = [mk({ type: "text", text: REPLAY_HEADER })];
  selection.selected.forEach((entry, index) => {
    if (index === 1 && selection.omitted > 0) {
      parts.push(mk({
        type: "text",
        text: `[${selection.omitted} earlier user message(s) omitted to fit the replay budget; they remain in the stored session history.]`,
      }));
    }
    const when = entry.created ? ` — ${new Date(entry.created).toISOString()}` : "";
    const lines = [`### User message ${index + 1} of ${total}${when}`];
    if (entry.text) lines.push(entry.text);
    lines.push(...entry.notes);
    parts.push(mk({ type: "text", text: lines.join("\n") }));
    for (const part of entry.media) {
      if (keep.has(part)) {
        parts.push(mk({ type: "file", mime: part.mime, url: part.url, filename: part.filename }));
        continue;
      }
      let reason = "not replayed (only the most recent attachments are replayed)";
      if (overflow) reason = "not replayed after an oversized-media compaction";
      else if (!String(part.url || "").startsWith("data:")) reason = "not replayed (no inline copy stored)";
      parts.push(mk({ type: "text", text: attachmentLabel(part, reason) }));
    }
  });
  parts.push(mk({ type: "text", text: "--- End of replayed user input. ---" }));
  return { parts, media: keep.size, messages: total };
}

function unwrap(response) {
  return response?.data ?? response;
}

async function fetchHistory(client, sessionID, timeoutMs) {
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(`session history fetch exceeded ${timeoutMs}ms`)), timeoutMs);
  });
  try {
    const response = await Promise.race([client.session.messages({ path: { id: sessionID } }), timeout]);
    const history = unwrap(response);
    if (!Array.isArray(history)) throw new Error("session history response was not an array");
    return history;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Create the replay hook for experimental.chat.messages.transform.
 * Results are cached per compaction so the prompt prefix stays byte-stable
 * across turns (prompt caching) and history is fetched once per compaction.
 * @param {object} client - OpenCode SDK client
 * @param {{ qualityLog?: Function, limits?: object }} [options]
 */
export function createCompactionInputReplay(client, options = {}) {
  const qualityLog = options.qualityLog;
  const cache = new Map();
  const inflight = new Map();

  async function partsFor(sessionID, anchor, messages, limits) {
    const cached = cache.get(sessionID);
    if (cached?.summaryID === anchor.summaryID) return cached.parts;
    const key = `${sessionID}:${anchor.summaryID}`;
    if (!inflight.has(key)) {
      inflight.set(key, (async () => {
        const history = await fetchHistory(client, sessionID, limits.fetchTimeoutMs);
        const visible = new Set(messages.map((msg) => msg?.info?.id).filter(Boolean));
        const entries = collectHiddenUserInput(history, visible, limits.maxMessageChars);
        const selection = selectWithinBudget(entries, limits.maxTextChars);
        const built = selection.selected.length > 0
          ? buildReplayParts(selection, { sessionID, anchorID: anchor.anchorID, overflow: anchor.overflow, maxMedia: limits.maxMedia })
          : { parts: [], media: 0, messages: 0 };
        cache.set(sessionID, { summaryID: anchor.summaryID, parts: built.parts });
        while (cache.size > MAX_CACHED_SESSIONS) cache.delete(cache.keys().next().value);
        qualityLog?.(
          "INFO",
          `[compaction-replay] prepared ${built.messages} user message(s), ${built.media} attachment(s), ${selection.omitted} omitted`,
        );
        return built.parts;
      })().finally(() => inflight.delete(key)));
    }
    return inflight.get(key);
  }

  /**
   * Fail-open: any error leaves the request unchanged.
   * @returns {Promise<{ injected: boolean, parts?: number, reason?: string }>}
   */
  async function inject(_input, output) {
    const limits = resolveReplayLimits(options.limits);
    if (!limits.enabled) return { injected: false, reason: "disabled" };
    const messages = output?.messages;
    const anchor = findCompactionAnchor(messages);
    if (!anchor) return { injected: false, reason: "no_compaction" };
    const anchorMessage = messages[anchor.anchorIndex];
    if (anchorMessage.parts.some((part) => part?.metadata?.[PIN_METADATA_KEY])) {
      return { injected: false, reason: "already_injected" };
    }
    const sessionID = String(anchorMessage.info.sessionID || "");
    if (!sessionID || !client?.session?.messages) return { injected: false, reason: "no_session" };
    try {
      const parts = await partsFor(sessionID, anchor, messages, limits);
      if (parts.length === 0) return { injected: false, reason: "nothing_hidden" };
      messages[anchor.anchorIndex] = { ...anchorMessage, parts: [...parts, ...anchorMessage.parts] };
      return { injected: true, parts: parts.length };
    } catch (error) {
      qualityLog?.("WARN", `[compaction-replay] skipped: ${String(error?.message ?? error).slice(0, 200)}`);
      return { injected: false, reason: "error" };
    }
  }

  return { inject };
}
