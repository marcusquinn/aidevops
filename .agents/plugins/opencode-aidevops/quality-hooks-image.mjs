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
  // Remove padding characters before applying the formula.
  const withoutPadding = b64.replace(/=+$/, "");
  return Math.floor((withoutPadding.length * 3) / 4);
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

    let downscaled = false;

    // Attempt 1: sips (macOS native — preferred, no extra install required)
    try {
      execSync(
        `sips --resampleHeightWidthMax ${MAX_DIM_PX} "${tmpIn}" --out "${tmpOut}"`,
        { timeout: 15000, stdio: "pipe" },
      );
      downscaled = true;
    } catch {
      // sips unavailable or failed — fall through to magick
    }

    // Attempt 2: ImageMagick (cross-platform fallback)
    if (!downscaled) {
      try {
        execSync(
          `magick "${tmpIn}" -resize "${MAX_DIM_PX}x${MAX_DIM_PX}>" "${tmpOut}"`,
          { timeout: 15000, stdio: "pipe" },
        );
        downscaled = true;
      } catch {
        // magick unavailable or failed
      }
    }

    if (!downscaled) {
      return null;
    }

    return readFileSync(tmpOut).toString("base64");
  } catch {
    return null;
  } finally {
    try { unlinkSync(tmpIn); } catch { /* best-effort cleanup */ }
    try { unlinkSync(tmpOut); } catch { /* best-effort cleanup */ }
  }
}

/**
 * Build the replacement text annotation used when an image cannot be
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

// ---------------------------------------------------------------------------
// Exported guard
// ---------------------------------------------------------------------------

/**
 * Walk output.messages and apply the image size guard to every user-role
 * message containing base64 image content parts. Mutates output.messages
 * in place — oversized images are either downscaled or replaced with a
 * text rejection notice.
 *
 * Called from the composed messagesTransformHook in index.mjs.
 *
 * @param {object} output — hook output object (contains .messages array)
 * @param {(level: string, message: string) => void} qualityLog
 */
export function applyImageSizeGuard(output, qualityLog) {
  if (!output?.messages) return;

  for (const message of output.messages) {
    if (message.role !== "user") continue;

    const content = message.content;
    if (!Array.isArray(content)) continue;

    for (let i = 0; i < content.length; i++) {
      const part = content[i];

      // Only handle base64-encoded image parts
      if (part?.type !== "image") continue;
      if (part?.source?.type !== "base64") continue;

      const b64 = part.source?.data;
      if (!b64) continue;

      const sizeBytes = base64ByteSize(b64);
      if (sizeBytes <= IMAGE_BYTE_LIMIT) continue;

      const sizeMB = (sizeBytes / (1024 * 1024)).toFixed(1);
      qualityLog(
        "WARN",
        `[image-size-guard] User image ${sizeMB} MB exceeds 4.5 MB — attempting downscale`,
      );

      const mediaType = part.source.media_type || "image/png";
      const downscaled = tryDownscale(b64, mediaType);

      if (downscaled !== null) {
        const newBytes = base64ByteSize(downscaled);
        const newMB = (newBytes / (1024 * 1024)).toFixed(1);

        if (newBytes <= IMAGE_BYTE_LIMIT) {
          // Success: replace image data in place
          content[i] = {
            ...part,
            source: { ...part.source, data: downscaled },
          };
          qualityLog(
            "INFO",
            `[image-size-guard] Image downscaled ${sizeMB} MB → ${newMB} MB — sending resized version`,
          );
          continue;
        }

        qualityLog(
          "WARN",
          `[image-size-guard] Post-downscale image still ${newMB} MB — replacing with rejection notice`,
        );
      } else {
        qualityLog(
          "WARN",
          `[image-size-guard] Downscale unavailable for ${sizeMB} MB image — replacing with rejection notice`,
        );
      }

      // Fallback: replace image with text annotation so the session survives
      content[i] = {
        type: "text",
        text: rejectionText(sizeBytes),
      };
    }
  }
}
