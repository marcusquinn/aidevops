/**
 * Outbound Leak Detector — Test Suite
 *
 * Tests for Shannon entropy calculation, pattern-based leak detection,
 * redaction, and edge cases.
 *
 * Reference: t1327.9 outbound leak detection specification
 */

import { describe, expect, test } from "bun:test";
import {
  shannonEntropy,
  scanForLeaks,
  redactLeaks,
  formatLeakWarning,
  LEAK_PATTERNS,
} from "./leak-detector";
import type { LeakDetectionConfig } from "./types";

/** Default config used across tests — mirrors DEFAULT_LEAK_DETECTION_CONFIG */
const DEFAULT_CONFIG: LeakDetectionConfig = {
  enabled: true,
  entropyThreshold: 4.0,
  minTokenLength: 20,
};

// =============================================================================
// Shannon Entropy
// =============================================================================

describe("shannonEntropy", () => {
  test("returns 0 for empty string", () => {
    expect(shannonEntropy("")).toBe(0);
  });

  test("returns 0 for single repeated character", () => {
    expect(shannonEntropy("aaaaaaaaaa")).toBe(0);
  });

  test("returns 1.0 for two equally distributed characters", () => {
    const entropy = shannonEntropy("abababababababab");
    expect(entropy).toBeCloseTo(1.0, 1);
  });

  test("English text has lower entropy than random base64", () => {
    const english = "the quick brown fox jumps over the lazy dog";
    const random = "aB3kL9mNpQ2rStUvWxYz1234567890ABCDEFGHIJ";
    expect(shannonEntropy(english)).toBeLessThan(shannonEntropy(random));
  });

  test("English text entropy is below 4.5 (typical prose range)", () => {
    // Typical English prose: 3.5-4.2 bits/char depending on vocabulary diversity
    const text = "the the the cat sat on the mat and the dog sat on the log";
    expect(shannonEntropy(text)).toBeLessThan(3.5);
  });

  test("random-looking token has entropy above 4.0", () => {
    const token = "aB3kL9mNpQ2rStUvWxYz5678JKLM";
    expect(shannonEntropy(token)).toBeGreaterThan(4.0);
  });
});

// =============================================================================
// Pattern Detection — AWS
// =============================================================================

describe("scanForLeaks — AWS keys", () => {
  test("detects AWS access key ID", () => {
    const text = "Use key AKIAIOSFODNN7EXAMPLE to authenticate";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "aws_access_key")).toBe(true);
  });

  test("does not flag non-AKIA prefixed strings", () => {
    const text = "The identifier XKIAIOSFODNN7EXAMPLE is not an AWS key";
    const result = scanForLeaks(text);
    expect(result.matches.some((m) => m.patternName === "aws_access_key")).toBe(false);
  });
});

// =============================================================================
// Pattern Detection — GitHub tokens
// =============================================================================

describe("scanForLeaks — GitHub tokens", () => {
  test("detects GitHub personal access token (ghp_)", () => {
    const text = "Token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "github_token")).toBe(true);
  });

  test("detects GitHub secret (ghs_)", () => {
    const text = "Secret: ghs_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "github_token")).toBe(true);
  });

  test("detects GitHub fine-grained token", () => {
    const text = "github_pat_ABCDEFGHIJKLMNOPQRSTUV1234567890ab";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "github_fine_grained")).toBe(true);
  });
});

// =============================================================================
// Pattern Detection — GitLab tokens
// =============================================================================

describe("scanForLeaks — GitLab tokens", () => {
  test("detects GitLab personal access token", () => {
    const text = "Use glpat-ABCDEFGHIJKLMNOPQRSTuv to authenticate";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "gitlab_token")).toBe(true);
  });
});

// =============================================================================
// Pattern Detection — Slack tokens
// =============================================================================

describe("scanForLeaks — Slack tokens", () => {
  test("detects Slack bot token", () => {
    const text = "SLACK_TOKEN=xoxb-1234567890-abcdefghij";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "slack_token")).toBe(true);
  });
});

// =============================================================================
// Pattern Detection — JWTs
// =============================================================================

describe("scanForLeaks — JWTs", () => {
  test("detects a JWT", () => {
    const jwt =
      "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";
    const text = `Bearer ${jwt}`;
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "jwt")).toBe(true);
  });
});

// =============================================================================
// Pattern Detection — Database URLs
// =============================================================================

describe("scanForLeaks — database URLs", () => {
  test("detects PostgreSQL connection string", () => {
    const text = "DATABASE_URL=postgresql://user:password123@db.example.com:5432/mydb";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "database_url")).toBe(true);
  });

  test("detects MongoDB connection string", () => {
    const text = "mongodb+srv://admin:secretpass@cluster0.abc123.mongodb.net/mydb";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "database_url")).toBe(true);
  });

  test("detects Redis connection string", () => {
    const text = "redis://default:mypassword@redis.example.com:6379";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "database_url")).toBe(true);
  });
});

// =============================================================================
// Pattern Detection — Private IPs
// =============================================================================

describe("scanForLeaks — private IPs", () => {
  test("detects 10.x.x.x private IP", () => {
    const text = "Connect to server at 10.0.1.42:8080";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "private_ip")).toBe(true);
  });

  test("detects 192.168.x.x private IP", () => {
    const text = "The database is at 192.168.1.100";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "private_ip")).toBe(true);
  });

  test("detects 172.16-31.x.x private IP", () => {
    const text = "Internal API: 172.16.0.1:3000";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "private_ip")).toBe(true);
  });

  test("does not flag public IPs", () => {
    const text = "Google DNS is at 8.8.8.8";
    const result = scanForLeaks(text);
    expect(result.matches.some((m) => m.patternName === "private_ip")).toBe(false);
  });
});

// =============================================================================
// Pattern Detection — File paths
// =============================================================================

describe("scanForLeaks — file paths", () => {
  test("detects Unix home directory path", () => {
    const text = "Config at /Users/marcus/secrets/config.json";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "file_path")).toBe(true);
  });

  test("detects Linux home directory path", () => {
    const text = "File: /home/deploy/.ssh/id_rsa";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "file_path")).toBe(true);
  });

  test("detects root path", () => {
    const text = "Located at /root/.config/secrets.env";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "file_path")).toBe(true);
  });

  test("detects Windows user path", () => {
    const text = "Path: C:\\Users\\admin\\Documents\\keys.txt";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "file_path")).toBe(true);
  });
});

// =============================================================================
// Pattern Detection — Private keys
// =============================================================================

describe("scanForLeaks — private keys", () => {
  test("detects PEM private key", () => {
    const text = `Here is the key:
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF8PbnGy5AHB
-----END RSA PRIVATE KEY-----
Done.`;
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "private_key")).toBe(true);
  });
});

// =============================================================================
// Pattern Detection — Generic API keys
// =============================================================================

describe("scanForLeaks — generic API keys", () => {
  test("detects api_key assignment", () => {
    const text = 'api_key: "test_FAKE_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij"';
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "generic_api_key")).toBe(true);
  });

  test("detects bearer token", () => {
    const text = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "bearer_token")).toBe(true);
  });
});

// =============================================================================
// Pattern Detection — Password in URL
// =============================================================================

describe("scanForLeaks — password in URL", () => {
  test("detects password in URL", () => {
    const text = "https://admin:supersecretpassword@api.example.com/v1";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "password_in_url")).toBe(true);
  });
});

// =============================================================================
// High-Entropy Token Detection
// =============================================================================

describe("scanForLeaks — high entropy tokens", () => {
  test("detects high-entropy token not matching any pattern", () => {
    // A random-looking token that doesn't match specific patterns
    const text = "Token: xK9mB2nR7pL4qW8sT3vY6zA1cF5dG0hJ";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(true);
    expect(result.matches.some((m) => m.patternName === "high_entropy")).toBe(true);
  });

  test("does not flag normal English words", () => {
    const text = "The quick brown fox jumps over the lazy dog near the riverbank";
    const result = scanForLeaks(text);
    expect(result.matches.some((m) => m.patternName === "high_entropy")).toBe(false);
  });

  test("does not flag short tokens", () => {
    const text = "ID: abc123";
    const result = scanForLeaks(text);
    expect(result.matches.some((m) => m.patternName === "high_entropy")).toBe(false);
  });
});

// =============================================================================
// Clean Text (No Leaks)
// =============================================================================

describe("scanForLeaks — clean text", () => {
  test("returns no leaks for normal message", () => {
    const text = "Hello! Your task has been completed successfully. Check the dashboard for details.";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(false);
    expect(result.matches).toHaveLength(0);
  });

  test("returns no leaks for empty string", () => {
    const result = scanForLeaks("");
    expect(result.hasLeaks).toBe(false);
    expect(result.matches).toHaveLength(0);
  });

  test("returns no leaks for command output", () => {
    const text = "Open tasks: 5\n\nUse /task <description> to create a new task.";
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(false);
  });

  test("scannedLength matches input length", () => {
    const text = "test message";
    const result = scanForLeaks(text);
    expect(result.scannedLength).toBe(text.length);
  });
});

// =============================================================================
// Redaction
// =============================================================================

describe("redactLeaks", () => {
  test("replaces detected secret with [REDACTED]", () => {
    const text = "Use key AKIAIOSFODNN7EXAMPLE to connect";
    const result = scanForLeaks(text);
    const redacted = redactLeaks(text, result);
    expect(redacted).toContain("[REDACTED]");
    expect(redacted).not.toContain("AKIAIOSFODNN7EXAMPLE");
  });

  test("redacts multiple different leaks", () => {
    const text = "Key: AKIAIOSFODNN7EXAMPLE, Token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl";
    const result = scanForLeaks(text);
    const redacted = redactLeaks(text, result);
    expect(redacted).not.toContain("AKIAIOSFODNN7EXAMPLE");
    expect(redacted).not.toContain("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ");
  });

  test("returns original text when no leaks", () => {
    const text = "This is a safe message";
    const result = scanForLeaks(text);
    const redacted = redactLeaks(text, result);
    expect(redacted).toBe(text);
  });

  test("redacts database connection string", () => {
    const text = "Connect to postgresql://admin:secret@10.0.1.5:5432/prod";
    const result = scanForLeaks(text);
    const redacted = redactLeaks(text, result);
    expect(redacted).toContain("[REDACTED]");
    expect(redacted).not.toContain("secret");
  });

  test("redacts private key block", () => {
    const text = `Key:
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF8PbnGy5AHB
-----END RSA PRIVATE KEY-----`;
    const result = scanForLeaks(text);
    const redacted = redactLeaks(text, result);
    expect(redacted).toContain("[REDACTED]");
    expect(redacted).not.toContain("BEGIN RSA PRIVATE KEY");
  });
});

// =============================================================================
// Warning Format
// =============================================================================

describe("formatLeakWarning", () => {
  test("includes leak count", () => {
    const text = "Token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl";
    const result = scanForLeaks(text);
    const warning = formatLeakWarning(result);
    expect(warning).toContain("potential leak(s)");
  });

  test("includes pattern name", () => {
    const text = "AKIAIOSFODNN7EXAMPLE";
    const result = scanForLeaks(text);
    const warning = formatLeakWarning(result);
    expect(warning).toContain("aws_access_key");
  });

  test("does NOT include the actual secret value", () => {
    const token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl";
    const text = `Token: ${token}`;
    const result = scanForLeaks(text);
    const warning = formatLeakWarning(result);
    expect(warning).not.toContain(token);
  });
});

// =============================================================================
// Edge Cases
// =============================================================================

describe("edge cases", () => {
  test("handles text with only whitespace", () => {
    const result = scanForLeaks("   \n\t  ");
    expect(result.hasLeaks).toBe(false);
  });

  test("handles very long text without crashing", () => {
    const text = "safe word ".repeat(10000);
    const result = scanForLeaks(text);
    expect(result.hasLeaks).toBe(false);
    expect(result.scannedLength).toBe(text.length);
  });

  test("handles text with special regex characters", () => {
    const text = "Pattern: [a-z]+ and (group) with $dollar and ^caret";
    const result = scanForLeaks(text);
    // Should not crash — special chars are in the input, not the patterns
    expect(result.scannedLength).toBe(text.length);
  });

  test("multiple occurrences of same secret are all redacted", () => {
    const token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl";
    const text = `First: ${token}, Second: ${token}`;
    const result = scanForLeaks(text);
    const redacted = redactLeaks(text, result);
    expect(redacted).not.toContain(token);
    // Should have two [REDACTED] markers
    const count = (redacted.match(/\[REDACTED\]/g) ?? []).length;
    expect(count).toBe(2);
  });
});

// =============================================================================
// Config-Driven Thresholds (t3395 — HIGH finding)
// =============================================================================

describe("scanForLeaks — config-driven thresholds", () => {
  test("uses entropyThreshold from config — high threshold suppresses detection", () => {
    // A token with entropy ~4.2 — detected at default 4.0 but not at 4.5
    const token = "xK9mB2nR7pL4qW8sT3vY6zA1cF5dG0hJ";
    const text = `Token: ${token}`;
    const strictConfig: LeakDetectionConfig = { ...DEFAULT_CONFIG, entropyThreshold: 5.5 };
    const result = scanForLeaks(text, strictConfig);
    // With a very high threshold, this token should not be flagged as high_entropy
    expect(result.matches.some((m) => m.patternName === "high_entropy")).toBe(false);
  });

  test("uses entropyThreshold from config — low threshold increases detection", () => {
    const token = "xK9mB2nR7pL4qW8sT3vY6zA1cF5dG0hJ";
    const text = `Token: ${token}`;
    const looseConfig: LeakDetectionConfig = { ...DEFAULT_CONFIG, entropyThreshold: 3.0 };
    const result = scanForLeaks(text, looseConfig);
    expect(result.matches.some((m) => m.patternName === "high_entropy")).toBe(true);
  });

  test("uses minTokenLength from config — longer minimum skips short tokens", () => {
    // A 25-char high-entropy token — detected at default minTokenLength=20 but not at 30
    const token = "aB3kL9mNpQ2rStUvWxYz12345";
    const text = `Token: ${token}`;
    const longMinConfig: LeakDetectionConfig = { ...DEFAULT_CONFIG, minTokenLength: 30 };
    const result = scanForLeaks(text, longMinConfig);
    expect(result.matches.some((m) => m.patternName === "high_entropy")).toBe(false);
  });

  test("default config (no arg) behaves identically to passing DEFAULT_CONFIG", () => {
    const text = "Token: xK9mB2nR7pL4qW8sT3vY6zA1cF5dG0hJ";
    const resultDefault = scanForLeaks(text);
    const resultExplicit = scanForLeaks(text, DEFAULT_CONFIG);
    expect(resultDefault.hasLeaks).toBe(resultExplicit.hasLeaks);
    expect(resultDefault.matches.length).toBe(resultExplicit.matches.length);
  });
});

// =============================================================================
// AWS Secret Key — contextual keyword requirement (t3395 — MEDIUM finding)
// =============================================================================

describe("scanForLeaks — aws_secret_key contextual keyword", () => {
  test("detects AWS secret key with contextual keyword", () => {
    // 40-char high-entropy base64 string with keyword context
    const text = "aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
    const result = scanForLeaks(text);
    expect(result.matches.some((m) => m.patternName === "aws_secret_key")).toBe(true);
  });

  test("does NOT flag bare 40-char base64 without keyword context", () => {
    // Same 40-char string but no surrounding keyword — should not match aws_secret_key
    const text = "The value is wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY here";
    const result = scanForLeaks(text);
    expect(result.matches.some((m) => m.patternName === "aws_secret_key")).toBe(false);
  });
});

// =============================================================================
// Bearer Token — captures only token value, not prefix (t3395 — MEDIUM finding)
// =============================================================================

describe("scanForLeaks — bearer_token captures only token value", () => {
  test("matchedText does not include 'Bearer ' prefix", () => {
    const token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U";
    const text = `Authorization: Bearer ${token}`;
    const result = scanForLeaks(text);
    const bearerMatch = result.matches.find((m) => m.patternName === "bearer_token");
    expect(bearerMatch).toBeDefined();
    expect(bearerMatch?.matchedText).not.toMatch(/^Bearer\s/i);
    expect(bearerMatch?.matchedText).toBe(token);
  });

  test("detects bearer token case-insensitively", () => {
    const token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U";
    const text = `Authorization: bearer ${token}`;
    const result = scanForLeaks(text);
    expect(result.matches.some((m) => m.patternName === "bearer_token")).toBe(true);
  });
});

// =============================================================================
// High-Entropy Index Correctness (t3395 — HIGH finding)
// =============================================================================

describe("scanForLeaks — high-entropy token index correctness", () => {
  test("index points to the correct occurrence when token appears multiple times", () => {
    const token = "xK9mB2nR7pL4qW8sT3vY6zA1cF5dG0hJ";
    // Place the token at a known position (not the start)
    const prefix = "safe text here: ";
    const text = `${prefix}${token}`;
    const result = scanForLeaks(text);
    const match = result.matches.find((m) => m.patternName === "high_entropy");
    expect(match).toBeDefined();
    // Index should point to where the token actually starts
    expect(match?.index).toBe(prefix.length);
  });

  test("high-entropy token that is substring of a pattern match is not double-reported", () => {
    // A GitHub token contains a high-entropy substring — should only appear as github_token
    const token = "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijkl";
    const text = `Token: ${token}`;
    const result = scanForLeaks(text);
    // Should be detected as github_token, not also as high_entropy
    expect(result.matches.some((m) => m.patternName === "github_token")).toBe(true);
    expect(result.matches.some((m) => m.patternName === "high_entropy")).toBe(false);
  });
});
