// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// ---------------------------------------------------------------------------
// Compaction replay — token estimates and budgets (GH#39958)
//
// Replayed media used to be capped by count only, so four large PDFs were
// re-attached after every compaction and the first request after it nearly
// filled the window again: a compaction loop. Media is now charged by
// estimated tokens, PDFs are labels unless explicitly enabled, the whole
// replay is held to a share of the model's input window, and media is dropped
// when the request after the previous compaction was already near the limit.
// ---------------------------------------------------------------------------

import { isPdf } from "./compaction-replay-collect.mjs";
import { generatedImageDimensions } from "./gpt-image-dimensions.mjs";
import { physicalInputLimit } from "./model-limits.mjs";

export const CHARS_PER_TOKEN = 4;
export const DEFAULT_MAX_MEDIA_TOKENS = 12_000;
// Providers downscale large images; ~1600 tokens is the per-image ceiling.
export const IMAGE_MAX_TOKENS = 1_600;
export const PDF_TOKENS_PER_PAGE = 2_300;
// Conservative page count when no page objects are visible (object streams).
const PDF_BYTES_PER_PAGE = 1_500;
// Enough decoded bytes to reach a JPEG frame header after typical EXIF data.
const IMAGE_HEADER_BASE64_CHARS = 262_144;
const PDF_PAGE_MARKER = /\/Type\s*\/Page\b/g;
const IMAGE_FORMATS = { "image/png": "png", "image/jpeg": "jpeg", "image/jpg": "jpeg", "image/webp": "webp" };

/**
 * Base64 payload of a data URL, or "" for any other URL.
 * @param {string} url
 * @returns {string}
 */
export function dataUrlBase64(url) {
  const value = String(url || "");
  const comma = value.indexOf(",");
  return value.startsWith("data:") && comma > 0 && value.slice(0, comma).endsWith(";base64") ? value.slice(comma + 1) : "";
}

function imageDimensions(mime, base64) {
  const head = Buffer.from(base64.slice(0, IMAGE_HEADER_BASE64_CHARS), "base64");
  if (mime === "image/gif") return head.length >= 10 ? { width: head.readUInt16LE(6), height: head.readUInt16LE(8) } : null;
  try {
    return IMAGE_FORMATS[mime] ? generatedImageDimensions(head, IMAGE_FORMATS[mime]) : null;
  } catch {
    return null;
  }
}

/**
 * Estimated tokens for one inline image: min(1600, w*h/750), or 1600 when
 * the dimensions cannot be read.
 * @param {string} mime
 * @param {string} base64
 * @returns {number}
 */
export function imageTokens(mime, base64) {
  const size = imageDimensions(mime, base64);
  const pixels = size && size.width > 0 && size.height > 0 ? size.width * size.height : Infinity;
  return Math.min(IMAGE_MAX_TOKENS, Math.max(1, Math.ceil(pixels / 750)));
}

/**
 * Estimated tokens for one inline PDF: pages × 2300, counting `/Type /Page`
 * objects, or one page per 1500 bytes when none are visible.
 * @param {string} base64
 * @returns {number}
 */
export function pdfTokens(base64) {
  const bytes = Buffer.from(base64, "base64");
  const pages = bytes.toString("latin1").match(PDF_PAGE_MARKER)?.length || Math.ceil(bytes.length / PDF_BYTES_PER_PAGE);
  return Math.max(1, pages) * PDF_TOKENS_PER_PAGE;
}

/**
 * Estimated tokens for one replay media part; Infinity without an inline copy.
 * @param {{ mime?: string, url?: string }} part
 * @returns {number}
 */
export function estimateMediaTokens(part) {
  const base64 = dataUrlBase64(part?.url);
  const mime = String(part?.mime || "").toLowerCase();
  if (!base64) return Infinity;
  if (isPdf(part)) return pdfTokens(base64);
  return mime.startsWith("image/") ? imageTokens(mime, base64) : Infinity;
}

/**
 * Newest media that fits both the count and the token budget. PDFs take part
 * only when `replayPdfs` is set.
 * @param {Array<object>} parts - oldest first
 * @param {{ maxMedia: number, maxMediaTokens: number, replayPdfs?: boolean }} budget
 * @returns {{ keep: Set<object>, tokens: number }}
 */
export function fitMedia(parts, budget) {
  const keep = new Set();
  let tokens = 0;
  for (const part of [...parts].reverse()) {
    if (keep.size >= budget.maxMedia) break;
    const cost = isPdf(part) && !budget.replayPdfs ? Infinity : estimateMediaTokens(part);
    if (tokens + cost > budget.maxMediaTokens) continue;
    keep.add(part);
    tokens += cost;
  }
  return { keep, tokens };
}

const safeInt = (value) => Number.isSafeInteger(value) && value > 0;

/**
 * Input window of a model limit record, or 0 when unknown.
 * @param {{ context?: number, input?: number, output?: number } | undefined} limit
 * @returns {number}
 */
export function replayWindowTokens(limit) {
  if (safeInt(limit?.input)) return limit.input;
  if (!safeInt(limit?.context)) return 0;
  return safeInt(limit.output) ? Math.max(0, physicalInputLimit(limit)) : limit.context;
}

/**
 * Text cap for one replay, held to `maxContextPercent` of a known window.
 * @param {{ maxTextChars: number, maxContextPercent: number }} limits
 * @param {number} windowTokens - 0 when unknown
 * @returns {{ maxTextChars: number, totalTokens: number | null }}
 */
export function replayTextBudget(limits, windowTokens) {
  if (!windowTokens) return { maxTextChars: limits.maxTextChars, totalTokens: null };
  const totalTokens = Math.floor((windowTokens * Math.min(100, limits.maxContextPercent)) / 100);
  return { maxTextChars: Math.min(limits.maxTextChars, totalTokens * CHARS_PER_TOKEN), totalTokens };
}

/**
 * Media token budget left once the replayed text is charged to the total.
 * @param {{ maxMediaTokens: number }} limits
 * @param {number | null} totalTokens
 * @param {number} textChars
 * @returns {number}
 */
export function mediaTokenBudget(limits, totalTokens, textChars) {
  if (totalTokens === null) return limits.maxMediaTokens;
  return Math.max(0, Math.min(limits.maxMediaTokens, totalTokens - Math.ceil(textChars / CHARS_PER_TOKEN)));
}

const requestTokens = (info) => (info?.tokens?.input || 0) + (info?.tokens?.cache?.read || 0) + (info?.tokens?.cache?.write || 0);
const isAssistant = (msg) => msg?.info?.role === "assistant";
const isCompletedSummary = (msg) => isAssistant(msg) && msg.info.summary === true && Boolean(msg.info.finish) && !msg.info.error;

/**
 * Percentage of the window used by the first request after the previous
 * compaction, or null when there is no earlier compaction to judge. Without a
 * known window the session's peak request stands in for the limit.
 * @param {Array<object>} history - stored session messages, oldest first
 * @param {string} summaryID - the active compaction summary
 * @param {number} windowTokens - 0 when unknown
 * @returns {number | null}
 */
export function postCompactionPressure(history, summaryID, windowTokens) {
  const current = history.findIndex((msg) => msg?.info?.id === summaryID);
  const previous = current > 0 ? history.slice(0, current).findLastIndex(isCompletedSummary) : -1;
  const first = previous < 0 ? undefined
    : history.slice(previous + 1, current).find((msg) => isAssistant(msg) && !msg.info.summary && requestTokens(msg.info) > 0);
  const limit = windowTokens || history.reduce((peak, msg) => Math.max(peak, isAssistant(msg) ? requestTokens(msg.info) : 0), 0);
  return first && limit > 0 ? Math.round((requestTokens(first.info) * 100) / limit) : null;
}
