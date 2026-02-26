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
import { VALID_LOG_LEVELS, warnUnknownKeys, validateParsedConfig } from "./config-validation";

/** Path to the config file */
const CONFIG_PATH = resolve(
  homedir(),
  ".config/aidevops/simplex-bot.json",
);

// Re-export validation utilities for external consumers
export {
  isValidPositiveNumber,
  removeInvalid,
  validatePort,
  validateLogLevel,
  validateNumericFields,
  warnUnknownKeys,
  validateParsedConfig,
} from "./config-validation";

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

    warnUnknownKeys(parsed, CONFIG_PATH);
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
