// ---------------------------------------------------------------------------
// image-guard.mjs — User-image size preflight for OpenCode plugin (GH#21793)
//
// Intercepts images in user messages before they reach the Anthropic API.
// The 5 MB per-image base64 limit is enforced server-side; oversized images
// crash the session permanently because the payload is already in message
// history and replays on every subsequent API call.
//
// Runs inside the experimental.chat.messages.transform hook (ttsrMessagesTransform
// in ttsr.mjs). For each image part in user messages:
//   1. Measure the decoded byte size (Buffer.byteLength — O(1), no decode).
//   2. If >4.5 MB (10% headroom under Anthropic's 5 MB ceiling):
//      a. Attempt downscale via sips (macOS built-in) or magick (cross-platform).
//      b. If downscaled image fits in 4.5 MB → substitute silently + log warn.
//      c. If downscale fails or result still too large → replace with text notice
//         so the session continues rather than crashing.
//   3. Images ≤4.5 MB pass through unchanged (O(1) cost per image part).
//
// Handles both OpenCode internal image part formats:
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

/** Vision-API efficiency ceiling: already documented in reference/screenshot-limits.md. */
const MAX_DIM = 1568;

/** Downscale shell command timeout (ms). */
const DOWNSCALE_TIMEOUT_MS = 15_000;

// ---------------------------------------------------------------------------
// Image data extraction — handles multiple OpenCode formats
// ---------------------------------------------------------------------------

/**
 * Extract base64 image data and media type from an OpenCode message part.
 * Returns null if the part does not contain a recognisable image payload.
 *
 * @param {object} part
 * @returns {{ data: string, mediaType: string, format: "url"|"sdk"|"image-source" } | null}
 */
function extractImageData(part) {
  // Data URI format: url = "data:image/png;base64,<data>"
  if (typeof part.url === "string" && part.url.startsWith("data:")) {
    const comma = part.url.indexOf(",");
    if (comma < 0) return null;
    const header = part.url.slice(0, comma);  // "data:image/png;base64"
    const data = part.url.slice(comma + 1);
    if (!data) return null;
    const mediaType = header.split(":")[1]?.split(";")[0] || "image/png";
    return { data, mediaType, format: "url" };
  }

  // Anthropic SDK format: { source: { type: "base64", media_type, data } }
  if (part.source?.type === "base64" && typeof part.source.data === "string") {
    return {
      data: part.source.data,
      mediaType: part.source.media_type || part.source.mediaType || "image/png",
      format: "sdk",
    };
  }

  // Tool-result image format: { image: { source: { type: "base64", ... } } }
  if (part.image?.source?.type === "base64" && typeof part.image.source.data === "string") {
    return {
      data: part.image.source.data,
      mediaType: part.image.source.media_type || part.image.source.mediaType || "image/png",
      format: "image-source",
    };
  }

  return null;
}

// ---------------------------------------------------------------------------
// Byte-size measurement (O(1), no full decode)
// ---------------------------------------------------------------------------

/**
 * Compute the decoded byte count of a base64 string.
 * Uses Node.js Buffer.byteLength which is O(1) — it does not decode the string.
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

/**
 * Determine the file extension from a MIME media type string.
 * @param {string} mediaType  e.g. "image/png", "image/jpeg"
 * @returns {string}
 */
function extFromMediaType(mediaType) {
  if (/jpe?g/i.test(mediaType)) return "jpg";
  if (/gif/i.test(mediaType)) return "gif";
  if (/webp/i.test(mediaType)) return "webp";
  return "png";
}

/**
 * Try to downscale the image using sips (macOS) or magick (cross-platform).
 * Writes src to a temp file, runs the tool, reads the result back.
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

    let resized = false;

    // sips — macOS built-in, no external dependency required.
    if (!resized) {
      try {
        execSync(
          `sips --resampleHeightWidthMax ${MAX_DIM} "${srcPath}" --out "${dstPath}" 2>/dev/null`,
          { timeout: DOWNSCALE_TIMEOUT_MS, stdio: ["pipe", "pipe", "pipe"] },
        );
        resized = true;
      } catch {
        // sips unavailable or failed — fall through to magick.
      }
    }

    // ImageMagick — cross-platform fallback.
    if (!resized) {
      try {
        execSync(
          `magick "${srcPath}" -resize "${MAX_DIM}x${MAX_DIM}>" "${dstPath}" 2>/dev/null`,
          { timeout: DOWNSCALE_TIMEOUT_MS, stdio: ["pipe", "pipe", "pipe"] },
        );
        resized = true;
      } catch {
        // magick also unavailable or failed — cannot downscale.
      }
    }

    if (!resized) return null;

    return readFileSync(dstPath).toString("base64");
  } catch {
    return null;
  } finally {
    // Best-effort cleanup of temp files — failures here are non-fatal.
    if (tmpDir !== null) {
      const srcPath = join(tmpDir, `src.${ext}`);
      const dstPath = join(tmpDir, `dst.${ext}`);
      try { unlinkSync(srcPath); } catch { /* ignore */ }
      try { unlinkSync(dstPath); } catch { /* ignore */ }
      try { rmdirSync(tmpDir); } catch { /* ignore */ }
    }
  }
}

// ---------------------------------------------------------------------------
// Part mutator — applies guard to a single image part
// ---------------------------------------------------------------------------

/**
 * Apply the size guard to a single image part.
 * Returns the original part unchanged if within limits, or a new part
 * (downscaled image or text notice) if the limit was exceeded.
 *
 * @param {object} part       Original message part (type === "image")
 * @param {Function} qualityLog  Bound quality logger (level, message) => void
 * @returns {{ modified: boolean, part: object }}
 */
function guardImagePart(part, qualityLog) {
  const extracted = extractImageData(part);
  if (!extracted) return { modified: false, part };

  const { data, mediaType, format } = extracted;
  const sizeBytes = base64DecodedSize(data);

  if (sizeBytes <= MAX_IMAGE_BYTES) return { modified: false, part };

  const sizeMB = (sizeBytes / 1_048_576).toFixed(1);
  qualityLog(
    "WARN",
    `[image-guard] Oversized image detected: ${sizeMB} MB (limit 4.5 MB) — attempting downscale`,
  );

  const resizedB64 = downscaleImage(data, mediaType);

  if (resizedB64 !== null) {
    const newSize = base64DecodedSize(resizedB64);
    if (newSize <= MAX_IMAGE_BYTES) {
      const newSizeMB = (newSize / 1_048_576).toFixed(1);
      qualityLog(
        "INFO",
        `[image-guard] Downscaled ${sizeMB} MB → ${newSizeMB} MB (session preserved)`,
      );

      // Build a new part with the resized image data substituted in.
      const newPart = { ...part };
      if (format === "url") {
        newPart.url = `data:${mediaType};base64,${resizedB64}`;
      } else if (format === "sdk") {
        newPart.source = { ...part.source, data: resizedB64 };
      } else {
        // "image-source" format
        newPart.image = {
          ...part.image,
          source: { ...part.image.source, data: resizedB64 },
        };
      }
      return { modified: true, part: newPart };
    }

    const stillSizeMB = (newSize / 1_048_576).toFixed(1);
    qualityLog(
      "WARN",
      `[image-guard] Downscaled image still ${stillSizeMB} MB (> 4.5 MB). Replacing with text notice.`,
    );
  } else {
    qualityLog(
      "WARN",
      `[image-guard] Downscale failed (sips/magick unavailable). Replacing image with text notice.`,
    );
  }

  // Fallback: replace the image with a text notice so the session continues
  // rather than crashing on the next API call with "image exceeds 5 MB maximum".
  const noticePart = {
    id: part.id,
    sessionID: part.sessionID,
    messageID: part.messageID,
    type: "text",
    text: [
      `[aidevops image-guard] Image removed (${sizeMB} MB > 4.5 MB preflight limit).`,
      "",
      "Automatic downscaling was not successful. Please resize the image before pasting:",
      `  macOS: sips --resampleHeightWidthMax ${MAX_DIM} <path> --out <path>-resized.png`,
      `  cross-platform: magick <path> -resize "${MAX_DIM}x${MAX_DIM}>" <path>-resized.png`,
      "  helper: screenshot-import-helper.sh prepare <path>",
      "",
      "Session continues — the oversized image was not sent to the API.",
    ].join("\n"),
    synthetic: true,
  };
  return { modified: true, part: noticePart };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Walk all user messages in the output.messages array and apply image size
 * guards. Mutates message.parts in place for any affected messages.
 *
 * Called from ttsrMessagesTransform (ttsr.mjs) on every messages.transform
 * invocation. Cost is O(image_count) — one O(1) byte-size check per image
 * part; downscale only triggered when size exceeds 4.5 MB.
 *
 * @param {Array<object>} messages  output.messages array from the hook
 * @param {Function} qualityLog     Bound quality logger (level, message) => void
 * @returns {boolean}               true if any image was modified
 */
export function applyImageGuard(messages, qualityLog) {
  if (!Array.isArray(messages) || messages.length === 0) return false;

  let anyModified = false;

  for (const message of messages) {
    // Only inspect user messages — assistant messages are already in history
    // and cannot be altered without corrupting the conversation thread.
    if (message.info?.role !== "user") continue;
    if (!Array.isArray(message.parts)) continue;

    let messageModified = false;
    const newParts = message.parts.map((part) => {
      if (part.type !== "image") return part;
      const result = guardImagePart(part, qualityLog);
      if (result.modified) {
        messageModified = true;
        anyModified = true;
      }
      return result.part;
    });

    if (messageModified) {
      message.parts = newParts;
    }
  }

  return anyModified;
}
