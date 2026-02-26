/**
 * Outbound Leak Detector — Scans bot responses before sending
 *
 * Gates at the bot's send boundary to prevent accidental exposure of:
 * - API keys and tokens (AWS, GitHub, GitLab, Slack, generic)
 * - JWTs and bearer tokens
 * - Database connection strings
 * - Internal/private IP addresses (RFC 1918)
 * - Absolute file paths (Unix/Windows home directories)
 * - High-entropy strings (Shannon entropy detection)
 *
 * Design: redact-and-warn, not block. The message is sent with secrets
 * replaced by [REDACTED], and the operator is warned via logger.
 *
 * Reference: t1327.9 outbound leak detection specification
 */

import type { LeakDetectionResult, LeakMatch, LeakPatternName } from "./types";

// =============================================================================
// Shannon Entropy
// =============================================================================

/** Minimum token length to evaluate for entropy (shorter strings have unreliable entropy) */
const MIN_ENTROPY_TOKEN_LENGTH = 20;

/** Entropy threshold in bits/char — English text ~3.5, base64 random ~5.5 */
const ENTROPY_THRESHOLD = 4.0;

/**
 * Calculate Shannon entropy of a string in bits per character.
 * Higher entropy = more random = more likely to be a secret.
 */
export function shannonEntropy(str: string): number {
  if (str.length === 0) {
    return 0;
  }

  const freq = new Map<string, number>();
  for (const ch of str) {
    freq.set(ch, (freq.get(ch) ?? 0) + 1);
  }

  let entropy = 0;
  const len = str.length;
  for (const count of freq.values()) {
    const p = count / len;
    if (p > 0) {
      entropy -= p * Math.log2(p);
    }
  }

  return entropy;
}

// =============================================================================
// Leak Patterns
// =============================================================================

/**
 * Named regex patterns for known credential and secret formats.
 * Each pattern is designed to match the secret value itself (for redaction).
 * Patterns use word boundaries or delimiters to reduce false positives.
 */
export const LEAK_PATTERNS: ReadonlyArray<{
  name: LeakPatternName;
  pattern: RegExp;
  description: string;
}> = [
  // --- Cloud provider keys ---
  {
    name: "aws_access_key",
    pattern: /\b(AKIA[0-9A-Z]{16})\b/g,
    description: "AWS Access Key ID",
  },
  {
    name: "aws_secret_key",
    pattern: /\b([0-9a-zA-Z/+]{40})\b/g,
    description: "AWS Secret Access Key (40-char base64)",
  },

  // --- Git platform tokens ---
  {
    name: "github_token",
    pattern: /\b(gh[ps]_[A-Za-z0-9_]{36,255})\b/g,
    description: "GitHub personal access token or secret",
  },
  {
    name: "github_fine_grained",
    pattern: /\b(github_pat_[A-Za-z0-9_]{22,255})\b/g,
    description: "GitHub fine-grained personal access token",
  },
  {
    name: "gitlab_token",
    pattern: /\b(glpat-[A-Za-z0-9\-_]{20,})\b/g,
    description: "GitLab personal access token",
  },

  // --- Chat/messaging tokens ---
  {
    name: "slack_token",
    pattern: /\b(xox[bpors]-[0-9A-Za-z\-]{10,})\b/g,
    description: "Slack bot/user/app token",
  },
  {
    name: "discord_token",
    pattern: /\b([MN][A-Za-z0-9]{23,}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,})\b/g,
    description: "Discord bot token",
  },

  // --- Generic API key patterns ---
  {
    name: "generic_api_key",
    pattern: /(?:api[_-]?key|apikey|api[_-]?secret|api[_-]?token)\s*[:=]\s*["']?([A-Za-z0-9_\-/.+]{20,})["']?/gi,
    description: "Generic API key assignment",
  },
  {
    name: "bearer_token",
    pattern: /\b(Bearer\s+[A-Za-z0-9_\-/.+]{20,})\b/g,
    description: "Bearer authentication token",
  },

  // --- JWTs ---
  {
    name: "jwt",
    pattern: /\b(eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_\-+/=]{10,})\b/g,
    description: "JSON Web Token",
  },

  // --- Database connection strings ---
  {
    name: "database_url",
    pattern: /((?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|mssql):\/\/[^\s"'`]{10,})/gi,
    description: "Database connection string with credentials",
  },

  // --- Private/internal IPs (RFC 1918 + loopback) ---
  {
    name: "private_ip",
    pattern: /\b((?:10\.\d{1,3}\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3})(?::\d{1,5})?)\b/g,
    description: "Private/internal IP address (RFC 1918)",
  },

  // --- Absolute file paths (home directories) ---
  {
    name: "file_path",
    pattern: /(?:\/(?:Users|home|root)\/[^\s"'`,:;)}\]]{3,}|[A-Z]:\\Users\\[^\s"'`,:;)}\]]{3,})/g,
    description: "Absolute file path exposing username/directory structure",
  },

  // --- Private keys ---
  {
    name: "private_key",
    pattern: /(-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----)/g,
    description: "PEM-encoded private key",
  },

  // --- Password in URL ---
  {
    name: "password_in_url",
    pattern: /:\/\/[^:]+:([^@\s]{8,})@/g,
    description: "Password embedded in URL",
  },
];

// =============================================================================
// Scanner
// =============================================================================

/**
 * Scan text for potential credential/secret leaks.
 *
 * Returns a result with all matches found. The caller decides whether
 * to redact, block, or warn based on the results.
 */
export function scanForLeaks(text: string): LeakDetectionResult {
  const matches: LeakMatch[] = [];

  // --- Pattern-based detection ---
  for (const { name, pattern, description } of LEAK_PATTERNS) {
    // Reset lastIndex for global regexes (they're stateful)
    pattern.lastIndex = 0;

    let match: RegExpExecArray | null;
    while ((match = pattern.exec(text)) !== null) {
      // Use the first capture group if present, otherwise the full match
      const value = match[1] ?? match[0];

      // For aws_secret_key (40-char base64), require high entropy to reduce false positives
      if (name === "aws_secret_key") {
        if (shannonEntropy(value) < ENTROPY_THRESHOLD) {
          continue;
        }
      }

      matches.push({
        patternName: name,
        description,
        matchedText: value,
        index: match.index,
        entropy: shannonEntropy(value),
      });
    }
  }

  // --- High-entropy token detection (catch-all for unknown formats) ---
  // Split on whitespace and common delimiters, check each token
  const tokens = text.split(/[\s"'`=:,;{}[\]()]+/);
  for (const token of tokens) {
    if (token.length < MIN_ENTROPY_TOKEN_LENGTH) {
      continue;
    }

    // Skip tokens already caught by pattern matching
    const alreadyCaught = matches.some((m) => m.matchedText === token);
    if (alreadyCaught) {
      continue;
    }

    // Only flag tokens that look like secrets (alphanumeric + special chars, no spaces)
    if (!/^[A-Za-z0-9_\-/.+=]{20,}$/.test(token)) {
      continue;
    }

    const entropy = shannonEntropy(token);
    if (entropy >= ENTROPY_THRESHOLD) {
      matches.push({
        patternName: "high_entropy",
        description: `High-entropy token (${entropy.toFixed(2)} bits/char)`,
        matchedText: token,
        index: text.indexOf(token),
        entropy,
      });
    }
  }

  return {
    hasLeaks: matches.length > 0,
    matches,
    scannedLength: text.length,
  };
}

// =============================================================================
// Redaction
// =============================================================================

/** Redaction placeholder */
const REDACTED = "[REDACTED]";

/**
 * Redact all detected leaks from the text.
 *
 * Replaces each matched secret with [REDACTED]. Returns the cleaned text.
 * Processes matches from longest to shortest to avoid partial replacements.
 */
export function redactLeaks(text: string, result: LeakDetectionResult): string {
  if (!result.hasLeaks) {
    return text;
  }

  // Sort by match length descending — replace longest matches first
  // to avoid partial replacement of overlapping matches
  const sorted = [...result.matches].sort(
    (a, b) => b.matchedText.length - a.matchedText.length,
  );

  let redacted = text;
  for (const match of sorted) {
    // Use split+join for reliable replacement (no regex special char issues)
    redacted = redacted.split(match.matchedText).join(REDACTED);
  }

  return redacted;
}

/**
 * Format a human-readable leak warning for operator logs.
 */
export function formatLeakWarning(result: LeakDetectionResult): string {
  const lines = [`Outbound leak detection: ${result.matches.length} potential leak(s) found and redacted:`];
  for (const match of result.matches) {
    // Show pattern name and description, but NOT the matched text (that would defeat the purpose)
    lines.push(`  - ${match.patternName}: ${match.description} (entropy: ${match.entropy.toFixed(2)})`);
  }
  return lines.join("\n");
}
