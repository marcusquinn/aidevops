/**
 * CCH billing header computation for provider-auth.mjs.
 * Extracted to keep provider-auth.mjs file complexity below the threshold.
 *
 * Replicates the exact billing header that Claude CLI injects into system[0],
 * including the xxHash64 body hash that the Bun runtime computes natively.
 */

import { createHash } from "crypto";
import { readFileSync } from "fs";
import { join } from "path";
import { homedir } from "os";
import { execFileSync } from "child_process";
import { getAnthropicUserAgent } from "./oauth-pool.mjs";

// ---------------------------------------------------------------------------
// xxHash64 — pure JavaScript implementation using BigInt
// ---------------------------------------------------------------------------

const XXH64_PRIME1 = 0x9E3779B185EBCA87n;
const XXH64_PRIME2 = 0xC2B2AE3D27D4EB4Fn;
const XXH64_PRIME3 = 0x165667B19E3779F9n;
const XXH64_PRIME4 = 0x85EBCA77C2B2AE63n;
const XXH64_PRIME5 = 0x27D4EB2F165667C5n;
const XXH64_MASK   = 0xFFFFFFFFFFFFFFFFn;
const XXHASH_SEED  = 0x6E52736AC806831En;

function xxh64Rotl(val, bits) {
  const b = BigInt(bits);
  return ((val << b) | (val >> (64n - b))) & XXH64_MASK;
}

function xxh64Round(acc, input) {
  acc = (acc + input * XXH64_PRIME2) & XXH64_MASK;
  acc = xxh64Rotl(acc, 31);
  return (acc * XXH64_PRIME1) & XXH64_MASK;
}

function xxh64MergeRound(acc, val) {
  val = xxh64Round(0n, val);
  acc = (acc ^ val) & XXH64_MASK;
  return (acc * XXH64_PRIME1 + XXH64_PRIME4) & XXH64_MASK;
}

function xxh64ReadU64LE(buf, off) {
  let v = 0n;
  for (let i = 7; i >= 0; i--) v = (v << 8n) | BigInt(buf[off + i]);
  return v;
}

function xxh64ReadU32LE(buf, off) {
  return BigInt(buf[off]) | (BigInt(buf[off + 1]) << 8n) |
         (BigInt(buf[off + 2]) << 16n) | (BigInt(buf[off + 3]) << 24n);
}

function xxHash64(input, seed) {
  const len = input.length;
  let h64;
  let p = 0;

  if (len >= 32) {
    let v1 = (seed + XXH64_PRIME1 + XXH64_PRIME2) & XXH64_MASK;
    let v2 = (seed + XXH64_PRIME2) & XXH64_MASK;
    let v3 = seed & XXH64_MASK;
    let v4 = (seed - XXH64_PRIME1) & XXH64_MASK;
    const limit = len - 31;
    while (p < limit) {
      v1 = xxh64Round(v1, xxh64ReadU64LE(input, p)); p += 8;
      v2 = xxh64Round(v2, xxh64ReadU64LE(input, p)); p += 8;
      v3 = xxh64Round(v3, xxh64ReadU64LE(input, p)); p += 8;
      v4 = xxh64Round(v4, xxh64ReadU64LE(input, p)); p += 8;
    }
    h64 = (xxh64Rotl(v1, 1) + xxh64Rotl(v2, 7) + xxh64Rotl(v3, 12) + xxh64Rotl(v4, 18)) & XXH64_MASK;
    h64 = xxh64MergeRound(h64, v1);
    h64 = xxh64MergeRound(h64, v2);
    h64 = xxh64MergeRound(h64, v3);
    h64 = xxh64MergeRound(h64, v4);
  } else {
    h64 = (seed + XXH64_PRIME5) & XXH64_MASK;
  }

  h64 = (h64 + BigInt(len)) & XXH64_MASK;

  while (p + 8 <= len) {
    const k1 = xxh64Round(0n, xxh64ReadU64LE(input, p));
    h64 = ((h64 ^ k1) & XXH64_MASK);
    h64 = (xxh64Rotl(h64, 27) * XXH64_PRIME1 + XXH64_PRIME4) & XXH64_MASK;
    p += 8;
  }
  if (p + 4 <= len) {
    h64 = (h64 ^ (xxh64ReadU32LE(input, p) * XXH64_PRIME1)) & XXH64_MASK;
    h64 = (xxh64Rotl(h64, 23) * XXH64_PRIME2 + XXH64_PRIME3) & XXH64_MASK;
    p += 4;
  }
  while (p < len) {
    h64 = (h64 ^ (BigInt(input[p]) * XXH64_PRIME5)) & XXH64_MASK;
    h64 = (xxh64Rotl(h64, 11) * XXH64_PRIME1) & XXH64_MASK;
    p++;
  }

  h64 = ((h64 ^ (h64 >> 33n)) * XXH64_PRIME2) & XXH64_MASK;
  h64 = ((h64 ^ (h64 >> 29n)) * XXH64_PRIME3) & XXH64_MASK;
  return (h64 ^ (h64 >> 32n)) & XXH64_MASK;
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

/**
 * Serialize a parsed request body with deterministic key ordering.
 * @param {object} parsed
 * @returns {string}
 */
export function serializeWithKeyOrder(parsed) {
  const ordered = {};
  const priorityKeys = ["model", "messages", "system", "tools", "metadata",
    "max_tokens", "thinking", "context_management", "temperature", "top_p",
    "top_k", "stop_sequences", "stream"];
  for (const key of priorityKeys) {
    if (key in parsed) ordered[key] = parsed[key];
  }
  for (const key of Object.keys(parsed)) {
    if (!(key in ordered)) ordered[key] = parsed[key];
  }
  return JSON.stringify(ordered);
}

/**
 * Compute the 5-char hex body hash matching Claude CLI's Bun runtime.
 * @param {string} bodyStr
 * @returns {string}
 */
export function computeBodyHash(bodyStr) {
  const bytes = new TextEncoder().encode(bodyStr);
  const hash = xxHash64(bytes, XXHASH_SEED);
  return (hash & 0xFFFFFn).toString(16).padStart(5, "0");
}

// ---------------------------------------------------------------------------
// CCH constants loading
// ---------------------------------------------------------------------------

/** @type {{ version: string, salt: string, charIndices: number[], entrypoint: string } | null} */
let _cchConstants = null;

function detectLiveCliVersion() {
  try {
    const raw = execFileSync("claude", ["--version"], {
      timeout: 3000, encoding: "utf-8", stdio: ["ignore", "pipe", "ignore"],
    }).trim();
    const m = raw.match(/^(\d+\.\d+\.\d+)/);
    return m ? m[1] : null;
  } catch {
    return null;
  }
}

function refreshCCHCache() {
  const script = join(homedir(), ".aidevops", "agents", "scripts", "cch-extract.sh");
  try {
    execFileSync(script, ["--cache"], { timeout: 10000, encoding: "utf-8", stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function tryReadCacheFile(cacheFile) {
  try { return JSON.parse(readFileSync(cacheFile, "utf-8")); } catch { return null; }
}

function refreshCacheIfVersionChanged(raw, cacheFile) {
  if (!raw?.version) return raw;
  const liveVersion = detectLiveCliVersion();
  if (!liveVersion || liveVersion === raw.version) return raw;
  console.error(`[aidevops] CCH: CLI updated ${raw.version} → ${liveVersion}. Re-extracting constants...`);
  if (!refreshCCHCache()) return raw;
  const updated = tryReadCacheFile(cacheFile);
  if (updated?.version) {
    console.error(`[aidevops] CCH: constants refreshed for v${updated.version}`);
    return updated;
  }
  return raw;
}

function ensureCacheExists(raw, cacheFile) {
  if (raw) return raw;
  console.error("[aidevops] CCH: no cache found. Extracting constants...");
  if (!refreshCCHCache()) return null;
  return tryReadCacheFile(cacheFile);
}

function buildCCHFromRaw(raw) {
  return { version: raw.version, salt: raw.salt, charIndices: raw.char_indices || [4, 7, 20], entrypoint: raw.entrypoint || "cli" };
}

function buildCCHDefaults() {
  return {
    version: getAnthropicUserAgent().match(/\/([\d.]+)/)?.[1] || "2.1.92",
    salt: "59cf53e54c78",
    charIndices: [4, 7, 20],
    entrypoint: "cli",
  };
}

/**
 * Load CCH signing constants from cache file or fall back to defaults.
 * @returns {{ version: string, salt: string, charIndices: number[], entrypoint: string }}
 */
export function loadCCHConstants() {
  if (_cchConstants) return _cchConstants;
  const cacheFile = join(homedir(), ".aidevops", "cch-constants.json");
  let raw = tryReadCacheFile(cacheFile);
  raw = refreshCacheIfVersionChanged(raw, cacheFile);
  raw = ensureCacheExists(raw, cacheFile);
  _cchConstants = (raw?.version && raw?.salt) ? buildCCHFromRaw(raw) : buildCCHDefaults();
  return _cchConstants;
}

// ---------------------------------------------------------------------------
// Billing header construction
// ---------------------------------------------------------------------------

function computeVersionSuffix(userMessage) {
  const { salt, charIndices, version } = loadCCHConstants();
  const chars = charIndices.map((i) => userMessage[i] || "0").join("");
  const payload = `${salt}${chars}${version}`;
  return createHash("sha256").update(payload).digest("hex").slice(0, 3);
}

/**
 * Build the complete billing header string for a request body.
 * @param {object} parsed - parsed JSON request body with system/messages
 * @returns {string}
 */
export function buildBillingHeader(parsed) {
  const { version, entrypoint } = loadCCHConstants();
  let firstUserText = "";
  const messages = parsed.messages || [];
  for (const msg of messages) {
    if (msg.role !== "user") continue;
    if (typeof msg.content === "string") { firstUserText = msg.content; break; }
    if (Array.isArray(msg.content)) {
      const textBlock = msg.content.find((b) => b.type === "text");
      if (textBlock?.text) { firstUserText = textBlock.text; break; }
    }
    break;
  }
  const suffix = computeVersionSuffix(firstUserText);
  return `x-anthropic-billing-header: cc_version=${version}.${suffix}; cc_entrypoint=${entrypoint}; cch=00000;`;
}
