import { tool } from "@opencode-ai/plugin"
import { Database } from "bun:sqlite"
import { homedir } from "os"
import { join } from "path"

/**
 * Resolve the OpenCode SQLite database path.
 * OpenCode stores sessions in ~/.local/share/opencode/opencode.db (Drizzle ORM).
 * The OPENCODE_DB env var overrides the default path.
 */
function getDbPath(): string {
  if (process.env.OPENCODE_DB) {
    return process.env.OPENCODE_DB
  }
  return join(homedir(), ".local", "share", "opencode", "opencode.db")
}

/**
 * Rename a session by updating the title directly in the SQLite database.
 *
 * OpenCode CLI sessions do not expose an HTTP API — Session.setTitle() is a
 * Drizzle ORM call that writes to the local SQLite DB. The TUI reads from the
 * same DB and picks up changes immediately (verified empirically).
 */
function renameSession(sessionID: string, title: string): { success: boolean; message: string } {
  const dbPath = getDbPath()

  try {
    const db = new Database(dbPath)
    try {
      const nowMs = Date.now()
      const result = db.run(
        "UPDATE session SET title = ?, time_updated = ? WHERE id = ?",
        [title, nowMs, sessionID],
      )

      if (result.changes === 0) {
        return { success: false, message: `Session ${sessionID} not found in database` }
      }

      return { success: true, message: title }
    } finally {
      db.close()
    }
  } catch (error) {
    return {
      success: false,
      message: error instanceof Error ? error.message : String(error),
    }
  }
}

export default tool({
  description:
    "Rename the current session to a new title. Use this after creating a git branch to sync the session name with the branch name.",
  args: {
    title: tool.schema
      .string()
      .describe("New title for the session (e.g., branch name like 'feature/my-feature')"),
  },
  async execute(args, context) {
    const { sessionID } = context
    const { title } = args

    const result = renameSession(sessionID, title)

    if (result.success) {
      return `Session renamed to: ${result.message}`
    }
    return `Failed to rename session: ${result.message}`
  },
})

// Also export a tool that syncs with the current git branch
export const sync_branch = tool({
  description:
    "Rename the current session to match the current git branch name. Call this after creating or switching branches.",
  args: {},
  async execute(_args, context) {
    const { sessionID } = context

    // Get current branch name
    let branch: string
    try {
      const branchResult = await Bun.$`git branch --show-current`.text()
      branch = branchResult.trim()
    } catch {
      return "Not in a git repository or git command failed"
    }

    if (!branch) {
      return "No branch checked out (detached HEAD state or not a git repository)"
    }

    const result = renameSession(sessionID, branch)

    if (result.success) {
      return `Session synced with branch: ${result.message}`
    }
    return `Failed to sync session with branch: ${result.message}`
  },
})
