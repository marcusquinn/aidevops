import { homedir } from "node:os"
import { join } from "node:path"

type DbPathEnv = {
  OPENCODE_DB?: string
  AIDEVOPS_VAULT_MANAGED_SESSION_HISTORY?: string
  AIDEVOPS_VAULT_MANAGED_HISTORY_ROOT?: string
  AIDEVOPS_VAULT_STATUS?: string
  AIDEVOPS_VAULT_STATUS_OVERRIDE?: string
  XDG_DATA_HOME?: string
  [key: string]: string | undefined
}

/**
 * Resolve the OpenCode SQLite database path.
 * OpenCode stores sessions in ${XDG_DATA_HOME:-~/.local/share}/opencode/opencode.db.
 * The OPENCODE_DB env var overrides the data-dir derived path.
 */
export function getDbPath(env: DbPathEnv = process.env): string {
  const managedHistory = env.AIDEVOPS_VAULT_MANAGED_SESSION_HISTORY
  if (managedHistory === "1" || managedHistory === "true") {
    const status = env.AIDEVOPS_VAULT_STATUS_OVERRIDE || env.AIDEVOPS_VAULT_STATUS
    if (status !== "unlocked") {
      throw new Error("VAULT_LOCKED: OpenCode managed session/history requires an unlocked Vault")
    }
    const root = env.AIDEVOPS_VAULT_MANAGED_HISTORY_ROOT || join(homedir(), ".aidevops", ".agent-workspace", "vault", "managed-session-history")
    return join(root, "opencode", "opencode.db")
  }
  if (env.OPENCODE_DB) {
    return env.OPENCODE_DB
  }
  const dataHome = env.XDG_DATA_HOME || join(homedir(), ".local", "share")
  return join(dataHome, "opencode", "opencode.db")
}
