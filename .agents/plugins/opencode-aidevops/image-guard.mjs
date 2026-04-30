// ---------------------------------------------------------------------------
// image-guard.mjs — User-image size preflight for OpenCode plugin (GH#21793)
//
// Intercepts images in user messages before they reach the Anthropic API.
// The 5 MB per-image base64 limit is enforced server-side; oversized images
// crash the session permanently — the payload is already in message history
// and replays on every subsequent API call.
//
// Runs inside the experimental.chat.messages.transform hook (ttsrMessagesTransform
// in ttsr.mjs). For each image part in user messages:
//   1. Measure the decoded byte size via Buffer.byteLength (O(1), no decode).
//   2. If >4.5 MB (10% headroom under Anthropic's 5 MB ceiling):
//      a. Attempt downscale via sips (macOS built-in) or magick (cross-platform).
//      b. If downscaled fits in 4.5 MB → substitute silently + log warning.
//      c. If downscale fails or result still too large → replace with a text
//         notice so the session continues rather than crashing.
//   3. Images ≤4.5 MB pass through unchanged (O(1) cost per image part).
//
// Handles OpenCode internal image part formats:
//   - Data URI:  { type: "image", url: "data:<mediaType>;base64,<data>" }
//   - SDK form:  { type: "image", source: { type: "base64", media_type, data } }
//   - Tool form: nested under part.image.source (tool_result images)
// ---------------------------------------------------------------------------

import { execSync } from "child_process";
import { writeFileSync, readFileSync, unlinkSync, mkdtempSync, rmdirSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/** 4.5 MB decoded bytes — 10% headroom under Anthropic's 5 MB (5,242,880) ceiling. */
const MAX_IMAGE_BYTES = 4_718_592;

/** Vision-API efficiency ceiling: documented in reference/screenshot-limits.md. */
const MAX_DIM = 1568;

/** Downscale shell command timeout (ms). */
const DOWNSCALE_TIMEOUT_MS = 15_000;

// ---------------------------------------------------------------------------
// Image data extraction — handles multiple OpenCode internal formats
// ---------------------------------------------------------------------------

/** Extract image data from a data-URI part. Returns null if not a data URI. */
function _extractDataUri(part) {
  if (typeof part.url !== "string" || !part.url.startsWith("data:")) return null;
  const comma = part.url.indexOf(",");
  const data = comma >= 0 ? part.url.slice(comma + 1) : "";
  if (!data) return null;
  const mediaType = part.url.slice(0, comma).split(":")[1]?.split(";")[0] || "image/png";
  return { data, mediaType, format: "url" };
}

/** Extract image data from Anthropic SDK source format. Returns null if not matching. */
function _extractSdkSource(part) {
  if (part.source?.type !== "base64" || typeof part.source.data !== "string") return null;
  return {
    data: part.source.data,
    mediaType: part.source.media_type || part.source.mediaType || "image/png",
    format: "sdk",
  };
}

/** Extract image data from tool-result image source format. Returns null if not matching. */
function _extractImageSource(part) {
  if (part.image?.source?.type !== "base64" || typeof part.image.source.data !== "string") return null;
  return {
    data: part.image.source.data,
    mediaType: part.image.source.media_type || part.image.source.mediaType || "image/png",
    format: "image-source",
  };
}

/**
 * Extract base64 image data and media type from an OpenCode message part.
 * Tries each known format in order; returns null if none matches.
 *
 * @param {object} part
 * @returns {{ data: string, mediaType: string, format: "url"|"sdk"|"image-source" } | null}
 */
function extractImageData(part) {
  return _extractDataUri(part) || _extractSdkSource(part) || _extractImageSource(part) || null;
}

// ---------------------------------------------------------------------------
// Byte-size measurement (O(1), no decode)
// ---------------------------------------------------------------------------

/**
 * Compute the decoded byte count of a base64 string.
 * Buffer.byteLength is O(1) — no decode occurs.
 *
 * @param {string} b64
 * @returns {number}
 */
function base64DecodedSize(b64) {
  return Buffer.byteLength(b64, "base64");
}

// ---------------------------------------------------------------------------
// Downscale helpers
// ---------------------------------------------------------------------------

/** Map media type keyword to file extension. */
const MEDIA_TYPE_EXT = { jpeg: "jpg", jpg: "jpg", gif: "gif", webp: "webp" };

/**
 * Return the file extension for a MIME media type string.
 * @param {string} mediaType  e.g. "image/png", "image/jpeg"
 * @returns {string}
 */
function extFromMediaType(mediaType) {
  const keyword = mediaType.toLowerCase().split("/")[1] || "";
  return MEDIA_TYPE_EXT[keyword] || "png";
}

/**
 * Run one downscale command. Returns true on success, false on failure.
 * @param {string} cmd
 * @returns {boolean}
 */
function runDownscaleCmd(cmd) {
  try {
    execSync(cmd, { timeout: DOWNSCALE_TIMEOUT_MS, stdio: ["pipe", "pipe", "pipe"] });
    return true;
  } catch {
    return false;
  }
}

/**
 * Try to downscale the image using sips (macOS) or magick (cross-platform).
 * Returns new base64 string on success, null on any failure.
 *
 * @param {string} b64       Base64-encoded source image
 * @param {string} mediaType MIME type of the source image
 * @returns {string | null}
 */
function downscaleImage(b64, mediaType) {
  const ext = extFromMediaType(mediaType);
  let tmpDir = null;
  try {
    tmpDir = mkdtempSync(join(tmpdir(), "aidevops-imgguard-"));
    const srcPath = join(tmpDir, `src.${ext}`);
    const dstPath = join(tmpDir, `dst.${ext}`);
    writeFileSync(srcPath, Buffer.from(b64, "base64"));
    const sipsCmd = `sips --resampleHeightWidthMax ${MAX_DIM} "${srcPath}" --out "${dstPath}" 2>/dev/null`;
    const magickCmd = `magick "${srcPath}" -resize "${MAX_DIM}x${MAX_DIM}>" "${dstPath}" 2>/dev/null`;
    const ok = runDownscaleCmd(sipsCmd) || runDownscaleCmd(magickCmd);
    return ok ? readFileSync(dstPath).toString("base64") : null;
  } catch {
    return null;
  } finally {
    if (tmpDir !== null) {
      const srcPath = join(tmpDir, `src.${ext}`);
      const dstPath = join(tmpDir, `dst.${ext}`);
      try { unlinkSync(srcPath); } catch { /* best-effort */ }
      try { unlinkSync(dstPath); } catch { /* best-effort */ }
      try { rmdirSync(tmpDir); } catch { /* best-effort */ }
    }
  }
}

// ---------------------------------------------------------------------------
// Part mutators — build a modified part from the downscale result
// ---------------------------------------------------------------------------

/** Build a new part with the resized base64 substituted in. */
function buildDownscaledPart(part, format, mediaType, resizedB64) {
  if (format === "url") {
    return { ...part, url: `data:${mediaType};base64,${resizedB64}` };
  }
  if (format === "sdk") {
    return { ...part, source: { ...part.source, data: resizedB64 } };
  }
  // "image-source" format
  return { ...part, image: { ...part.image, source: { ...part.image.source, data: resizedB64 } } };
}

/** Build a text-notice part that replaces an image that could not be made safe. */
function buildNoticePart(part, sizeMB) {
  return {
    id: part.id,
    sessionID: part.sessionID,
    messageID: part.messageID,
    type: "text",
    text: [
      `[aidevops image-guard] Image removed (${sizeMB} MB > 4.5 MB preflight limit).`,
      "",
      "Automatic downscaling was not successful. Please resize before pasting:",
      `  macOS: sips --resampleHeightWidthMax ${MAX_DIM} <path> --out <path>-resized.png`,
      `  cross-platform: magick <path> -resize "${MAX_DIM}x${MAX_DIM}>" <path>-resized.png`,
      "  helper: screenshot-import-helper.sh prepare <path>",
      "",
      "Session continues — the oversized image was not sent to the API.",
    ].join("\n"),
    synthetic: true,
  };
}

// ---------------------------------------------------------------------------
// Per-part guard
// ---------------------------------------------------------------------------

/**
 * Apply the size guard to a single image part.
 * Returns the original part unchanged if within limits, otherwise a new part
 * (downscaled image or text notice).
 *
 * @param {object} part
 * @param {Function} qualityLog
 * @returns {{ modified: boolean, part: object }}
 */
function guardImagePart(part, qualityLog) {
  const extracted = extractImageData(part);
  if (!extracted) return { modified: false, part };

  const { data, mediaType, format } = extracted;
  const sizeBytes = base64DecodedSize(data);
  if (sizeBytes <= MAX_IMAGE_BYTES) return { modified: false, part };

  const sizeMB = (sizeBytes / 1_048_576).toFixed(1);
  qualityLog("WARN", `[image-guard] Oversized image: ${sizeMB} MB (limit 4.5 MB) — attempting downscale`);

  const resizedB64 = downscaleImage(data, mediaType);
  if (resizedB64 !== null && base64DecodedSize(resizedB64) <= MAX_IMAGE_BYTES) {
    const newMB = (base64DecodedSize(resizedB64) / 1_048_576).toFixed(1);
    qualityLog("INFO", `[image-guard] Downscaled ${sizeMB} MB → ${newMB} MB (session preserved)`);
    return { modified: true, part: buildDownscaledPart(part, format, mediaType, resizedB64) };
  }

  qualityLog("WARN", `[image-guard] Downscale failed — replacing image with text notice`);
  return { modified: true, part: buildNoticePart(part, sizeMB) };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Walk all user messages in output.messages and apply image size guards.
 * Mutates message.parts in place for affected messages.
 *
 * Called from ttsrMessagesTransform (ttsr.mjs). Cost is O(image_count) —
 * one O(1) byte-size check per image part; downscale only triggered when
 * the 4.5 MB limit is exceeded.
 *
 * @param {Array<object>} messages  output.messages array from the hook
 * @param {Function} qualityLog     Bound quality logger (level, message) => void
 * @returns {boolean}               true if any image was modified
 */
export function applyImageGuard(messages, qualityLog) {
  if (!Array.isArray(messages) || messages.length === 0) return false;

  let anyModified = false;

  for (const message of messages) {
    if (message.info?.role !== "user" || !Array.isArray(message.parts)) continue;

    let messageModified = false;
    const newParts = message.parts.map((part) => {
      if (part.type !== "image") return part;
      const result = guardImagePart(part, qualityLog);
      if (result.modified) messageModified = true;
      return result.part;
    });

    if (messageModified) {
      message.parts = newParts;
      anyModified = true;
    }
  }

  return anyModified;
}
