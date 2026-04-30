// ---------------------------------------------------------------------------
// quality-hooks-image.mjs — User-pasted image size guard (GH#21793)
//
// Intercepts the experimental.chat.messages.transform hook to detect and
// downscale oversized images before they reach the Anthropic API. Prevents
// the permanent session-crash caused by images exceeding Anthropic's 5 MB
// per-image base64 ceiling.
//
// Integration: imported by index.mjs, composed with the TTSR messages hook.
// Pattern: mirrors browser-qa-helper.sh --max-dim on the agent-capture path.
// ---------------------------------------------------------------------------

import { execSync } from "child_process";
import { writeFileSync, readFileSync, unlinkSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { randomBytes } from "crypto";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

// Anthropic hard limit: 5 MB per image (base64-decoded bytes).
// 4.5 MB = 10% headroom to avoid hitting the exact limit.
const IMAGE_BYTE_LIMIT = 4718592; // 4.5 MB

// Vision-API efficiency target: 1568px on the longest side.
// Mirrors the --max-dim recommendation in screenshot-limits.md.
const MAX_DIM_PX = 1568;

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/**
 * Compute the decoded byte size of a base64 string without allocating a
 * full Buffer. Uses the standard base64 length formula.
 * @param {string} b64 — base64-encoded data (may have padding)
 * @returns {number} byte size of the decoded image
 */
function base64ByteSize(b64) {
  const withoutPadding = b64.replace(/=+$/, "");
  return Math.floor((withoutPadding.length * 3) / 4);
}

/**
 * Try one downscale command and return true if successful.
 * @param {string} cmd - shell command to run
 * @returns {boolean}
 */
function trySipsOrMagick(cmd) {
  try {
    execSync(cmd, { timeout: 15000, stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

/**
 * Try to downscale an image to MAX_DIM_PX on the longest side.
 * Attempts sips first (macOS native, no extra deps), then ImageMagick.
 * Returns the resized image as a base64 string, or null if both fail.
 * @param {string} b64 — original base64 image data
 * @param {string} mediaType — e.g. "image/png", "image/jpeg"
 * @returns {string|null}
 */
function tryDownscale(b64, mediaType) {
  const ext = mediaType === "image/jpeg" || mediaType === "image/jpg" ? ".jpg" : ".png";
  const id = randomBytes(6).toString("hex");
  const tmpIn = join(tmpdir(), `aidevops-img-${id}-in${ext}`);
  const tmpOut = join(tmpdir(), `aidevops-img-${id}-out${ext}`);

  try {
    writeFileSync(tmpIn, Buffer.from(b64, "base64"));

    const sipsCmd = `sips --resampleHeightWidthMax ${MAX_DIM_PX} "${tmpIn}" --out "${tmpOut}"`;
    const magickCmd = `magick "${tmpIn}" -resize "${MAX_DIM_PX}x${MAX_DIM_PX}>" "${tmpOut}"`;

    const downscaled = trySipsOrMagick(sipsCmd) || trySipsOrMagick(magickCmd);
    if (!downscaled) return null;

    return readFileSync(tmpOut).toString("base64");
  } catch {
    return null;
  } finally {
    try { unlinkSync(tmpIn); } catch { /* best-effort */ }
    try { unlinkSync(tmpOut); } catch { /* best-effort */ }
  }
}

/**
 * Build the replacement text annotation for an image that cannot be
 * downscaled to fit under the API limit.
 * @param {number} originalBytes
 * @returns {string}
 */
function rejectionText(originalBytes) {
  const sizeMB = (originalBytes / (1024 * 1024)).toFixed(1);
  return (
    `[Image blocked by aidevops image-size-guard: ` +
    `${sizeMB} MB exceeds the Anthropic 5 MB per-image API limit. ` +
    `Downscaling failed or the result still exceeded the limit. ` +
    `To include this image, resize it to under 4.5 MB before pasting ` +
    `(max ${MAX_DIM_PX}px on the longest side). ` +
    `Claude Code: run \`screenshot-import-helper.sh prepare <path>\` ` +
    `to auto-resize, then paste the returned path.]`
  );
}

/**
 * Apply the size guard to a single oversized image part.
 * Returns a replacement content part (downscaled image or text rejection).
 * @param {object} part — original image content part
 * @param {string} b64 — original base64 data
 * @param {number} sizeBytes — decoded size
 * @param {(level: string, message: string) => void} qualityLog
 * @returns {object} replacement content part
 */
function guardOversizedPart(part, b64, sizeBytes, qualityLog) {
  const sizeMB = (sizeBytes / (1024 * 1024)).toFixed(1);
  qualityLog("WARN", `[image-size-guard] User image ${sizeMB} MB exceeds 4.5 MB — attempting downscale`);

  const mediaType = part.source.media_type || "image/png";
  const downscaled = tryDownscale(b64, mediaType);

  if (downscaled !== null) {
    const newBytes = base64ByteSize(downscaled);
    const newMB = (newBytes / (1024 * 1024)).toFixed(1);

    if (newBytes <= IMAGE_BYTE_LIMIT) {
      qualityLog("INFO", `[image-size-guard] Image downscaled ${sizeMB} MB → ${newMB} MB`);
      return { ...part, source: { ...part.source, data: downscaled } };
    }
    qualityLog("WARN", `[image-size-guard] Post-downscale image still ${newMB} MB — replacing with notice`);
  } else {
    qualityLog("WARN", `[image-size-guard] Downscale unavailable for ${sizeMB} MB image — replacing with notice`);
  }

  return { type: "text", text: rejectionText(sizeBytes) };
}

/**
 * Check whether a content part needs the size guard.
 * Returns null if the part can pass through, or the replacement part.
 * @param {object} part
 * @param {(level: string, message: string) => void} qualityLog
 * @returns {object|null} replacement part, or null if no action needed
 */
function checkImagePart(part, qualityLog) {
  if (part?.type !== "image" || part?.source?.type !== "base64") return null;

  const b64 = part.source?.data;
  if (!b64) return null;

  const sizeBytes = base64ByteSize(b64);
  if (sizeBytes <= IMAGE_BYTE_LIMIT) return null;

  return guardOversizedPart(part, b64, sizeBytes, qualityLog);
}

/**
 * Apply the image size guard to a single user message in place.
 * @param {object} message
 * @param {(level: string, message: string) => void} qualityLog
 */
function guardUserMessage(message, qualityLog) {
  if (message.role !== "user" || !Array.isArray(message.content)) return;

  for (let i = 0; i < message.content.length; i++) {
    const replacement = checkImagePart(message.content[i], qualityLog);
    if (replacement !== null) {
      message.content[i] = replacement;
    }
  }
}

// ---------------------------------------------------------------------------
// Exported guard
// ---------------------------------------------------------------------------

/**
 * Walk output.messages and apply the image size guard to every user-role
 * message containing base64 image content parts. Mutates output.messages
 * in place — oversized images are either downscaled or replaced with a
 * text rejection notice so the session survives the API call.
 *
 * Called from the composed messagesTransformHook in index.mjs.
 *
 * @param {object} output — hook output object (contains .messages array)
 * @param {(level: string, message: string) => void} qualityLog
 */
export function applyImageSizeGuard(output, qualityLog) {
  if (!output?.messages) return;

  for (const message of output.messages) {
    guardUserMessage(message, qualityLog);
  }
}
