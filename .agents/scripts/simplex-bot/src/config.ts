/**
 * SimpleX Bot — Configuration Loader
 *
 * Loads bot configuration from ~/.config/aidevops/simplex-bot.json
 * with environment variable overrides and validation.
 *
 * Priority: env vars > config file > defaults
 *
 * Reference: t1327.4 bot framework specification
 */

import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { homedir } from "node:os";
import type { BotConfig } from "./types";
import { DEFAULT_BOT_CONFIG } from "./types";

/** Path to the config file */
const CONFIG_PATH = resolve(
  homedir(),
  ".config/aidevops/simplex-bot.json",
);

/** Fields allowed in the config file (for validation) */
const VALID_CONFIG_KEYS: ReadonlySet<string> = new Set([
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
const VALID_LOG_LEVELS = new Set(["debug", "info", "warn", "error"]);

/** Check whether a numeric config field is valid (non-negative number) */
export function isValidPositiveNumber(value: unknown, min = 0): boolean {
  return typeof value === "number" && value >= min;
}

/** Warn about unknown keys in the parsed config */
export function warnUnknownKeys(parsed: Record<string, unknown>): void {
  for (const key of Object.keys(parsed)) {
    if (!VALID_CONFIG_KEYS.has(key)) {
      console.warn(`[config] Unknown key "${key}" in ${CONFIG_PATH} — ignored`);
    }
  }
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

/** Validate and sanitize parsed config values, removing invalid entries */
export function validateParsedConfig(parsed: Record<string, unknown>): void {
  validateLogLevel(parsed);
  validatePort(parsed);
  validateNumericFields(parsed);
}

/**
 * Load config from JSON file if it exists.
 * Returns partial config (only fields present in the file).
 */
export function loadConfigFile(): Partial<BotConfig> {
  if (!existsSync(CONFIG_PATH)) {
    return {};
  }

  try {
    const text = readFileSync(CONFIG_PATH, "utf-8");
    const parsed = JSON.parse(text) as Record<string, unknown>;

    warnUnknownKeys(parsed);
    validateParsedConfig(parsed);

    return parsed as Partial<BotConfig>;
  } catch (err) {
    console.error(`[config] Failed to load ${CONFIG_PATH}:`, err);
    return {};
  }
}

/** Env var → config key mapping for simple string assignments */
const STRING_ENV_MAP: ReadonlyArray<[string, keyof BotConfig]> = [
  ["SIMPLEX_HOST", "host"],
  ["SIMPLEX_BOT_NAME", "displayName"],
];

/** Env var → config key mapping for boolean assignments */
const BOOLEAN_ENV_MAP: ReadonlyArray<[string, keyof BotConfig]> = [
  ["SIMPLEX_AUTO_ACCEPT", "autoAcceptContacts"],
  ["SIMPLEX_TLS", "useTls"],
  ["SIMPLEX_BUSINESS_ADDRESS", "businessAddress"],
];

/** Parse port from env var, returning undefined if invalid */
export function parseEnvPort(): number | undefined {
  const raw = process.env.SIMPLEX_PORT;
  if (!raw) return undefined;
  const port = Number(raw);
  return port >= 1 && port <= 65535 ? port : undefined;
}

/** Parse log level from env var, returning undefined if invalid */
export function parseEnvLogLevel(): BotConfig["logLevel"] | undefined {
  const level = process.env.SIMPLEX_LOG_LEVEL;
  if (!level || !VALID_LOG_LEVELS.has(level)) return undefined;
  return level as BotConfig["logLevel"];
}

/**
 * Parse environment variable overrides.
 * Env vars take highest priority.
 */
export function loadEnvOverrides(): Partial<BotConfig> {
  const overrides: Partial<BotConfig> = {};

  const port = parseEnvPort();
  if (port !== undefined) overrides.port = port;

  const logLevel = parseEnvLogLevel();
  if (logLevel !== undefined) overrides.logLevel = logLevel;

  for (const [envKey, configKey] of STRING_ENV_MAP) {
    const val = process.env[envKey];
    if (val) (overrides as Record<string, unknown>)[configKey] = val;
  }

  for (const [envKey, configKey] of BOOLEAN_ENV_MAP) {
    const val = process.env[envKey];
    if (val) (overrides as Record<string, unknown>)[configKey] = val === "true";
  }

  return overrides;
}

/**
 * Load the full bot configuration.
 * Merges: defaults < config file < env vars
 */
export function loadConfig(): BotConfig {
  const fileConfig = loadConfigFile();
  const envConfig = loadEnvOverrides();

  const merged: BotConfig = {
    ...DEFAULT_BOT_CONFIG,
    ...fileConfig,
    ...envConfig,
  };

  return merged;
}

/** Get the config file path (for diagnostics) */
export function getConfigPath(): string {
  return CONFIG_PATH;
}

/** Check whether a config file exists */
export function configFileExists(): boolean {
  return existsSync(CONFIG_PATH);
}
