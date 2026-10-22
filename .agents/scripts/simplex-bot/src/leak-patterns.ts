/**
 * Named regex patterns for known credential and secret formats.
 * Each pattern is designed to match the secret value itself (for redaction).
 * Patterns use word boundaries or delimiters to reduce false positives.
 */
const namedLeakPatterns = [
  // --- Cloud provider keys ---
  {
    name: "aws_access_key",
    pattern: /\b(AKIA[0-9A-Z]{16})\b/g,
    description: "AWS Access Key ID",
  },
  {
    name: "aws_secret_key",
    // Require a contextual keyword nearby to reduce false positives (e.g. git SHAs)
    pattern: /(?:aws[_-]?secret[_-]?(?:access[_-]?)?key|secret[_-]?key|secret)\s*[:=]\s*["']?([0-9a-zA-Z/+]{40})["']?/gi,
    description: "AWS Secret Access Key (40-char base64 with context keyword)",
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
    pattern: /\b(xox[bpors]-[0-9A-Za-z-]{10,})\b/g,
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
    // Capture only the token value (not the 'Bearer ' prefix) for consistent redaction.
    // Case-insensitive to handle 'bearer', 'BEARER', etc.
    pattern: /\bBearer\s+([A-Za-z0-9_\-/.+]{20,})\b/gi,
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
] as const;

/** Regex-backed names plus the scanner's computed entropy match. */
export type LeakPatternName = (typeof namedLeakPatterns)[number]["name"] | "high_entropy";

/** Keep the public registry's existing readonly-array, mutable-entry signature. */
export const LEAK_PATTERNS: ReadonlyArray<{
  name: LeakPatternName;
  pattern: RegExp;
  description: string;
}> = namedLeakPatterns;
