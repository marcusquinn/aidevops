// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

// ---------------------------------------------------------------------------
// Compaction replay — OpenCode 2 media part shapes (GH#35189)
//
// OpenCode 2.0.x media parts are plain `{ type: "media", mediaType, data }`.
// From 2.1.0 a part is `{ type: "media", media: Asset }`, where Asset is a host
// class instance that providers call methods on (inline(), base64()), and
// session hooks receive it in-process. A plain object would break provider
// lowering, so replayed media is built with the constructor of an Asset seen
// in this host's own requests. Until one has been seen (e.g. right after a
// restart) a replayed attachment becomes a text label instead.
// ---------------------------------------------------------------------------

import { attachmentLabel } from "./compaction-replay-collect.mjs";
import { PIN_METADATA_KEY } from "./compaction-replay-budget.mjs";

const UNAVAILABLE_REASON = "not re-attachable in this request; ask the user to attach it again if it matters";

/**
 * Starting media shape for a host version: 2.0.x is legacy; anything else
 * waits for an observed Asset before replaying media inline.
 * @param {string} [hostVersion]
 * @returns {{ shape: "legacy" | "asset", Asset?: Function }}
 */
export function initialMediaShape(hostVersion) {
  return /^2\.0\./.test(String(hostVersion || "")) ? { shape: "legacy" } : { shape: "asset" };
}

/**
 * Update the media shape from the first media part in this request.
 * @param {{ shape: string, Asset?: Function }} current
 * @param {Array<object>} messages
 * @returns {{ shape: string, Asset?: Function }}
 */
export function observeMediaShape(current, messages) {
  const part = messages
    .flatMap((message) => (Array.isArray(message?.content) ? message.content : []))
    .find((candidate) => candidate?.type === "media");
  if (!part) return current;
  if (!part.media) return { shape: "legacy" };
  const Asset = part.media.constructor;
  return typeof Asset === "function" && Asset !== Object ? { shape: "asset", Asset } : current;
}

/**
 * Convert a V1 replay part to the OpenCode 2 ContentPart shape of this host.
 * @param {object} part - `{ type: "text", text }` or `{ type: "file", mime, url, filename }`
 * @param {{ shape: string, Asset?: Function }} [media]
 * @returns {object}
 */
export function toV2Part(part, media = { shape: "legacy" }) {
  const metadata = { [PIN_METADATA_KEY]: true };
  if (part.type !== "file") return { type: "text", text: part.text, metadata };
  const url = String(part.url || "");
  const data = url.slice(url.indexOf(",") + 1);
  const filename = part.filename || undefined;
  if (media.shape === "legacy") return { type: "media", mediaType: part.mime, data, filename, metadata };
  if (!media.Asset) return { type: "text", text: attachmentLabel(part, UNAVAILABLE_REASON), metadata };
  const asset = new media.Asset({ source: { type: "base64", data, mediaType: part.mime } });
  return { type: "media", media: asset, filename, metadata };
}
