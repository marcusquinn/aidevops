/**
 * MCP Registry — reads MCP template configs and provides them in OpenCode format.
 *
 * Sources (in priority order):
 *   1. User overrides in ~/.config/aidevops/mcp-overrides.json
 *   2. configs/mcp-templates/*.json  (each file has an "opencode" section)
 *   3. configs/mcp-servers-config.json.txt (legacy fallback)
 *
 * The registry normalises every entry to the OpenCode McpLocalConfig | McpRemoteConfig
 * shape so the plugin's `config` hook can merge them into the running config.
 */

import { readdir } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { homedir } from 'node:os'

// ── Types matching @opencode-ai/sdk McpLocalConfig | McpRemoteConfig ──

export interface McpLocalConfig {
  type: 'local'
  command: string[]
  environment?: Record<string, string>
  enabled?: boolean
  timeout?: number
}

export interface McpRemoteConfig {
  type: 'remote'
  url: string
  enabled?: boolean
  headers?: Record<string, string>
}

export type McpConfig = McpLocalConfig | McpRemoteConfig

export interface McpRegistry {
  /** name → config map ready to merge into Config.mcp */
  entries: Record<string, McpConfig>
  /** names of MCPs that failed to load (for diagnostics) */
  errors: Array<{ name: string; reason: string }>
}

// ── Paths ──

const HOME = homedir()
const OVERRIDES_PATH = join(HOME, '.config', 'aidevops', 'mcp-overrides.json')

/**
 * Resolve the configs directory relative to the repo root.
 * Works both when running from the repo and from the deployed plugin.
 */
function configsDir(repoRoot: string): string {
  return join(repoRoot, 'configs', 'mcp-templates')
}

function legacyConfigPath(repoRoot: string): string {
  return join(repoRoot, 'configs', 'mcp-servers-config.json.txt')
}

// ── Helpers ──

/** Safely read and parse a JSON file. Returns null on any error. */
async function readJson<T>(path: string): Promise<T | null> {
  try {
    const file = Bun.file(path)
    if (!(await file.exists())) return null
    return (await file.json()) as T
  } catch {
    return null
  }
}

/**
 * Normalise a legacy mcpServers entry (command string + args array)
 * into the OpenCode McpLocalConfig | McpRemoteConfig shape.
 */
function normaliseLegacyEntry(
  name: string,
  raw: Record<string, unknown>,
): McpConfig | null {
  // Remote server
  if (raw.type === 'remote' && typeof raw.url === 'string') {
    return {
      type: 'remote',
      url: raw.url,
      enabled: raw.enabled !== false,
      ...(raw.headers ? { headers: raw.headers as Record<string, string> } : {}),
    }
  }

  // Local server — legacy format uses command (string) + args (string[])
  const cmd = raw.command
  const args = Array.isArray(raw.args) ? (raw.args as string[]) : []

  if (typeof cmd === 'string') {
    const command = [cmd, ...args]
    const env = raw.env ?? raw.environment
    const entry: McpLocalConfig = {
      type: 'local',
      command,
      enabled: raw.enabled !== false,
    }
    if (env && typeof env === 'object') {
      entry.environment = env as Record<string, string>
    }
    return entry
  }

  // Already in OpenCode format (command is string[])
  if (Array.isArray(cmd)) {
    const entry: McpLocalConfig = {
      type: 'local',
      command: cmd as string[],
      enabled: raw.enabled !== false,
    }
    const env = raw.env ?? raw.environment
    if (env && typeof env === 'object') {
      entry.environment = env as Record<string, string>
    }
    return entry
  }

  return null
}

/**
 * Extract the OpenCode MCP config from a template file.
 *
 * Template files have an `opencode` key containing one or more MCP entries
 * in the format: { "mcp-name": { type, command, ... } }
 */
function extractFromTemplate(
  json: Record<string, unknown>,
): Record<string, McpConfig> {
  const result: Record<string, McpConfig> = {}
  const opencode = json.opencode as Record<string, unknown> | undefined
  if (!opencode || typeof opencode !== 'object') return result

  for (const [key, value] of Object.entries(opencode)) {
    // Skip metadata keys
    if (key.startsWith('_')) continue
    if (typeof value !== 'object' || value === null) continue

    const raw = value as Record<string, unknown>

    // Check if it's already in McpLocalConfig/McpRemoteConfig shape
    if (raw.type === 'remote' && typeof raw.url === 'string') {
      result[key] = {
        type: 'remote',
        url: raw.url,
        enabled: raw.enabled !== false,
        ...(raw.headers ? { headers: raw.headers as Record<string, string> } : {}),
      }
    } else if (Array.isArray(raw.command)) {
      const entry: McpLocalConfig = {
        type: 'local',
        command: raw.command as string[],
        enabled: raw.enabled !== false,
      }
      if (raw.environment && typeof raw.environment === 'object') {
        entry.environment = raw.environment as Record<string, string>
      }
      result[key] = entry
    }
  }

  return result
}

/**
 * Check if an MCP config contains placeholder values that need user configuration.
 * MCPs with placeholders are registered but disabled by default.
 */
function hasPlaceholders(config: McpConfig): boolean {
  const check = (val: string): boolean =>
    /YOUR_.*_HERE|REPLACE_ME|<.*>/i.test(val)

  if (config.type === 'local') {
    if (config.environment) {
      return Object.values(config.environment).some(check)
    }
  } else if (config.type === 'remote') {
    if (config.headers) {
      return Object.values(config.headers).some(check)
    }
  }
  return false
}

// ── Main loader ──

/**
 * Load all MCP configurations from template files and legacy config.
 *
 * @param repoRoot - Path to the aidevops repo root (for finding configs/)
 * @returns McpRegistry with all discovered MCP entries
 */
export async function loadMcpRegistry(repoRoot: string): Promise<McpRegistry> {
  const entries: Record<string, McpConfig> = {}
  const errors: Array<{ name: string; reason: string }> = []

  // 1. Load from template files
  const templatesDir = configsDir(repoRoot)
  try {
    const files = await readdir(templatesDir)
    const jsonFiles = files.filter(f => f.endsWith('.json'))

    for (const file of jsonFiles) {
      const filePath = join(templatesDir, file)
      const json = await readJson<Record<string, unknown>>(filePath)
      if (!json) {
        errors.push({ name: file, reason: 'Failed to parse JSON' })
        continue
      }

      const extracted = extractFromTemplate(json)
      for (const [name, config] of Object.entries(extracted)) {
        // Disable MCPs with placeholder credentials
        if (hasPlaceholders(config)) {
          config.enabled = false
        }
        entries[name] = config
      }
    }
  } catch {
    errors.push({ name: 'mcp-templates/', reason: 'Directory not found or unreadable' })
  }

  // 2. Load from legacy config (lower priority — don't overwrite template entries)
  const legacyPath = legacyConfigPath(repoRoot)
  const legacy = await readJson<Record<string, unknown>>(legacyPath)
  if (legacy?.mcpServers && typeof legacy.mcpServers === 'object') {
    const servers = legacy.mcpServers as Record<string, Record<string, unknown>>
    for (const [name, raw] of Object.entries(servers)) {
      if (entries[name]) continue // Template takes priority
      const config = normaliseLegacyEntry(name, raw)
      if (config) {
        if (hasPlaceholders(config)) {
          config.enabled = false
        }
        entries[name] = config
      } else {
        errors.push({ name, reason: 'Could not normalise legacy config' })
      }
    }
  }

  // 3. Apply user overrides (highest priority)
  const overrides = await readJson<Record<string, unknown>>(OVERRIDES_PATH)
  if (overrides && typeof overrides === 'object') {
    for (const [name, raw] of Object.entries(overrides)) {
      if (typeof raw !== 'object' || raw === null) continue

      const override = raw as Record<string, unknown>

      // Allow disabling specific MCPs
      if (override.enabled === false) {
        if (entries[name]) {
          entries[name].enabled = false
        }
        continue
      }

      // Allow enabling with custom config
      const config = normaliseLegacyEntry(name, override)
      if (config) {
        entries[name] = config
      }
    }
  }

  return { entries, errors }
}

/**
 * Get a summary of the registry for diagnostics.
 */
export function registrySummary(registry: McpRegistry): string {
  const enabled = Object.entries(registry.entries).filter(([, c]) => c.enabled !== false)
  const disabled = Object.entries(registry.entries).filter(([, c]) => c.enabled === false)
  const local = enabled.filter(([, c]) => c.type === 'local')
  const remote = enabled.filter(([, c]) => c.type === 'remote')

  const lines = [
    `MCP Registry: ${enabled.length} enabled, ${disabled.length} disabled, ${registry.errors.length} errors`,
    `  Local: ${local.map(([n]) => n).join(', ') || 'none'}`,
    `  Remote: ${remote.map(([n]) => n).join(', ') || 'none'}`,
  ]

  if (disabled.length > 0) {
    lines.push(`  Disabled: ${disabled.map(([n]) => n).join(', ')}`)
  }

  if (registry.errors.length > 0) {
    lines.push(`  Errors: ${registry.errors.map(e => `${e.name} (${e.reason})`).join(', ')}`)
  }

  return lines.join('\n')
}
