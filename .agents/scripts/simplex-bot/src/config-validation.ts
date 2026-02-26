/**
 * SimpleX Bot — Configuration Validation
 *
 * Validates and sanitizes parsed config values.
 * Extracted from config.ts to keep per-file complexity low.
 */

import { DEFAULT_BOT_CONFIG } from "./types";

/** Fields allowed in the config file (for validation) */
export const VALID_CONFIG_KEYS: ReadonlySet<string> = new Set([
  "port",
  "host",
  "displayName",
  "autoAcceptContacts",
  "welcomeMessage",
  "logLevel",
  "reconnectInterval",
  "maxReconnectAttempts",
  "useTls",
  "businessAddress",
  "autoAcceptFiles",
  "maxFileSize",
  "autoJoinGroups",
  "allowedContacts",
  "groupPermissions",
  "sessionIdleTimeout",
  "maxPromptLength",
  "responseTimeout",
  "dataDir",
  "leakDetection",
]);

/** Valid log levels */
export const VALID_LOG_LEVELS = new Set(["debug", "info", "warn", "error"]);

/** Check whether a numeric config field is valid (non-negative number) */
export function isValidPositiveNumber(value: unknown, min = 0): boolean {
  return typeof value === "number" && value >= min;
}

/** Remove a config key with a warning if it fails validation */
export function removeInvalid(parsed: Record<string, unknown>, key: string, reason: string): void {
  console.warn(`[config] Invalid ${key} "${String(parsed[key])}" — ${reason}`);
  delete parsed[key];
}

/** Validate port: must be 1-65535 */
export function validatePort(parsed: Record<string, unknown>): void {
  if (parsed.port === undefined) return;
  if (!isValidPositiveNumber(parsed.port, 1) || (parsed.port as number) > 65535) {
    removeInvalid(parsed, "port", `using default ${DEFAULT_BOT_CONFIG.port}`);
  }
}

/** Validate log level: must be one of the known levels */
export function validateLogLevel(parsed: Record<string, unknown>): void {
  if (!parsed.logLevel) return;
  if (!VALID_LOG_LEVELS.has(String(parsed.logLevel))) {
    removeInvalid(parsed, "logLevel", `using default "${DEFAULT_BOT_CONFIG.logLevel}"`);
  }
}

/** Validate numeric fields that must be non-negative */
export function validateNumericFields(parsed: Record<string, unknown>): void {
  const fields = ["reconnectInterval", "maxReconnectAttempts"] as const;
  for (const field of fields) {
    if (parsed[field] !== undefined && !isValidPositiveNumber(parsed[field])) {
      removeInvalid(parsed, field, "using default");
    }
  }
}

/** Warn about unknown keys in the parsed config */
export function warnUnknownKeys(parsed: Record<string, unknown>, configPath: string): void {
  for (const key of Object.keys(parsed)) {
    if (!VALID_CONFIG_KEYS.has(key)) {
      console.warn(`[config] Unknown key "${key}" in ${configPath} — ignored`);
    }
  }
}

/** Validate and sanitize parsed config values, removing invalid entries */
export function validateParsedConfig(parsed: Record<string, unknown>): void {
  validateLogLevel(parsed);
  validatePort(parsed);
  validateNumericFields(parsed);
}
