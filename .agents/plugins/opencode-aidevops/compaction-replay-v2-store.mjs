// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// ---------------------------------------------------------------------------
// Compaction replay — OpenCode 2 durable prompt store (GH#35189)
//
// One private JSON file per session (0600, directory 0700) holds each user
// prompt verbatim and inline copies of only the newest attachments. Files
// untouched for 30 days are pruned.
// ---------------------------------------------------------------------------

import { createHash } from "node:crypto";
import { mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { attachmentLabel, isMedia } from "./compaction-replay-collect.mjs";

const STORE_VERSION = 1;
const STORE_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;
const PRUNED_REASON = "not replayed (only the most recent attachments are replayed)";
const STORE_ELISION = "[Earlier user input omitted for the session store budget; retained input is not the complete session history.]";
// Bound serialized prompt metadata/text as well as turn count. Inline media is
// governed separately by pruneMedia(). Keep the initiating turn and newest tail.
export const MAX_STORED_PROMPT_CHARS = 1_000_000;
export const MAX_STORED_PROMPTS = 1000;

function promptSize(entry) {
  return JSON.stringify({ ...entry, media: [] }).length;
}

function boundedText(text, budget) {
  if (JSON.stringify(text).length <= budget) return text;
  const marker = "\n[… input omitted for the session store budget …]\n";
  const clipped = (cap) => text.slice(0, Math.ceil(cap * 2 / 3)) + marker + (cap >= 3 ? text.slice(-Math.floor(cap / 3)) : "");
  let low = 0;
  let high = Math.min(text.length, budget);
  while (low < high) {
    const mid = Math.ceil((low + high) / 2);
    if (JSON.stringify(clipped(mid)).length <= budget) low = mid;
    else high = mid - 1;
  }
  return clipped(low);
}

function boundedNotes(notes = []) {
  const kept = [];
  let remaining = 32000;
  for (const note of notes) {
    const clipped = boundedText(note, Math.min(8000, remaining));
    remaining -= JSON.stringify(clipped).length + 1;
    kept.push(clipped);
    if (remaining < 128) break;
  }
  if (kept.length < notes.length) kept.push(STORE_ELISION);
  return kept;
}

function prunePromptText(store) {
  const first = store.prompts[0];
  if (!first) return;
  // Measure JSON-encoded characters: control characters can expand sixfold.
  // Bound attachment metadata too, so an oversized first turn cannot crowd out
  // the newest turn. Normal host-generated IDs/timestamps are small.
  for (const entry of store.prompts) {
    entry.text = boundedText(entry.text, 180000);
    entry.notes = boundedNotes(entry.notes);
    entry.inlineNotes = boundedNotes(entry.inlineNotes);
  }
  // Include the array envelope, commas and room for the store elision notice.
  let used = 2 + promptSize(first) + 256;
  const tail = [];
  for (let i = store.prompts.length - 1; i >= 1 && tail.length < MAX_STORED_PROMPTS - 1; i--) {
    const size = promptSize(store.prompts[i]) + 1;
    if (used + size > MAX_STORED_PROMPT_CHARS) break;
    used += size;
    tail.unshift(store.prompts[i]);
  }
  if (tail.length < store.prompts.length - 1 && !first.notes.includes(STORE_ELISION)) first.notes.push(STORE_ELISION);
  store.prompts = [first, ...tail];
}

const isInlineUri = (file) => String(file?.uri || "").startsWith("data:");

/**
 * Label a prompt attachment URI; inline data is captured later from context.
 * @param {{ uri?: string, name?: string }} file
 * @returns {string}
 */
function fileNote(file) {
  const uri = String(file?.uri || "");
  if (isInlineUri(file)) {
    const mime = uri.slice(5, uri.indexOf(";")) || "unknown";
    return attachmentLabel({ mime, filename: file?.name || "inline attachment", url: "" }, "");
  }
  return attachmentLabel({ mime: "file", filename: file?.name || "", url: uri }, "");
}

/**
 * One store entry from a `session.prompt` hook event.
 * @param {object} event
 * @param {number} [now]
 * @returns {{ id: string, created: number, text: string, notes: string[], inlineNotes: string[], media: object[] } | null}
 */
export function promptEntry(event, now = Date.now()) {
  const id = String(event?.messageID || "");
  const text = String(event?.prompt?.text || "").trim();
  const files = Array.isArray(event?.prompt?.files) ? event.prompt.files : [];
  if (!id || id.length > 4096 || (!text && files.length === 0)) return null;
  return {
    id,
    created: now,
    text,
    notes: files.filter((file) => !isInlineUri(file)).map(fileNote),
    // Labels for pasted data until the normalized copy is captured from context.
    inlineNotes: files.filter(isInlineUri).map(fileNote),
    media: [],
  };
}

function assetPayload(asset) {
  if (typeof asset?.inline === "function") return asset.inline();
  const source = asset?.source;
  return source?.type === "base64" ? { mime: asset.mediaType || source.mediaType, base64: source.data } : undefined;
}

/**
 * Inline payload of one V2 media part. OpenCode 2.0.x parts carry
 * `mediaType`/`data`; 2.1+ parts carry a `media` Asset whose `inline()`
 * returns base64 for byte/base64 sources (url/ref sources have none).
 * @param {object} part
 * @returns {{ mime: string, base64: string } | undefined}
 */
export function mediaPayload(part) {
  if (part?.type !== "media") return undefined;
  const payload = part.media ? assetPayload(part.media) : { mime: part.mediaType, base64: part.data };
  const mime = String(payload?.mime || "").toLowerCase();
  return typeof payload?.base64 === "string" && payload.base64 && isMedia(mime) ? { mime, base64: payload.base64 } : undefined;
}

/**
 * Inline media of one V2 context message, in the V1 replay part shape.
 * @param {object} message
 * @returns {Array<{ mime: string, url: string, filename: string }>}
 */
export function messageMedia(message) {
  const parts = Array.isArray(message?.content) ? message.content : [];
  return parts.flatMap((part) => {
    const payload = mediaPayload(part);
    return payload ? [{ mime: payload.mime, url: `data:${payload.mime};base64,${payload.base64}`, filename: part.filename || "" }] : [];
  });
}

/**
 * Keep inline copies for only the newest `maxMedia` attachments; older ones
 * become labels so the store stays small.
 * @param {Array<object>} prompts
 * @param {number} maxMedia
 */
export function pruneMedia(prompts, maxMedia) {
  let budget = maxMedia;
  for (const entry of [...prompts].reverse()) {
    const keepCount = Math.min(entry.media.length, Math.max(0, budget));
    const dropped = entry.media.slice(0, entry.media.length - keepCount);
    entry.media = entry.media.slice(entry.media.length - keepCount);
    entry.notes.push(...dropped.map((part) => attachmentLabel(part, PRUNED_REASON)));
    budget -= keepCount;
  }
}

function storeFile(storeDir, sessionID) {
  return join(storeDir, `${createHash("sha256").update(sessionID).digest("hex").slice(0, 24)}.json`);
}

/**
 * Read a session store, or an empty one when missing or unreadable.
 * @param {string} storeDir
 * @param {string} sessionID
 * @returns {{ version: number, sessionID: string, prompts: Array<object> }}
 */
export function readStore(storeDir, sessionID) {
  try {
    const data = JSON.parse(readFileSync(storeFile(storeDir, sessionID), "utf8"));
    if (data?.version === STORE_VERSION && data.sessionID === sessionID && Array.isArray(data.prompts)) return data;
  } catch { /* missing or unreadable: start empty */ }
  return { version: STORE_VERSION, sessionID, prompts: [] };
}

/**
 * Atomically write a session store with private permissions.
 * @param {string} storeDir
 * @param {{ sessionID: string }} store
 */
export function writeStore(storeDir, store) {
  prunePromptText(store);
  mkdirSync(storeDir, { recursive: true, mode: 0o700 });
  const path = storeFile(storeDir, store.sessionID);
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(store), { mode: 0o600 });
  renameSync(tmp, path);
}

function removeIfStale(path, now) {
  try {
    if (now - statSync(path).mtimeMs > STORE_RETENTION_MS) rmSync(path, { force: true });
  } catch { /* ignore */ }
}

/**
 * Remove stores untouched for 30 days. Best effort.
 * @param {string} storeDir
 * @param {number} [now]
 */
export function pruneStores(storeDir, now = Date.now()) {
  let names = [];
  try {
    names = readdirSync(storeDir);
  } catch {
    return;
  }
  for (const name of names) removeIfStale(join(storeDir, name), now);
}
