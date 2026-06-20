import { homedir } from "node:os"
import { join } from "node:path"

/**
 * Resolve the OpenCode SQLite database path.
 * OpenCode stores sessions in ${XDG_DATA_HOME:-~/.local/share}/opencode/opencode.db.
 * The OPENCODE_DB env var overrides the data-dir derived path.
 */
export function getDbPath(env: { OPENCODE_DB?: string; XDG_DATA_HOME?: string } = process.env): string {
  if (env.OPENCODE_DB) {
    return env.OPENCODE_DB
  }
  const dataHome = env.XDG_DATA_HOME || join(homedir(), ".local", "share")
  return join(dataHome, "opencode", "opencode.db")
}
