import { tool } from "@opencode-ai/plugin"
import { Database } from "bun:sqlite"
import { homedir } from "os"
import { join } from "path"
import { isDefaultBranchTitle, isTitleOverwritable } from "../lib/session-rename-guards"

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

/**
 * Guarded branch-sync rename: skips default branch names and preserves
 * meaningful existing titles. Returns structured outcome so the caller
 * (tool export) can format user-facing text.
 */
function syncSessionWithBranch(
  sessionID: string,
  branch: string,
): { outcome: "renamed" | "skipped" | "error"; message: string } {
  // Guard 1: never write default branch names as session titles.
  if (isDefaultBranchTitle(branch)) {
    return {
      outcome: "skipped",
      message: `Skipping session rename: '${branch}' is not a meaningful title`,
    }
  }

  const dbPath = getDbPath()

  try {
    const db = new Database(dbPath)
    try {
      // Guard 2: do not clobber a meaningful existing title.
      if (!isTitleOverwritable(db, sessionID)) {
        return {
          outcome: "skipped",
          message: "Skipping session rename: session already has a meaningful title",
        }
      }

      const nowMs = Date.now()
      const result = db.run(
        "UPDATE session SET title = ?, time_updated = ? WHERE id = ?",
        [branch, nowMs, sessionID],
      )

      if (result.changes === 0) {
        return { outcome: "error", message: `Session ${sessionID} not found in database` }
      }

      return { outcome: "renamed", message: branch }
    } finally {
      db.close()
    }
  } catch (error) {
    return {
      outcome: "error",
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

    // Explicit rename is a manual override — no guards. Matches the
    // session-rename-helper.sh contract where `rename` is unguarded but
    // `sync-branch` enforces the meaningful-title invariants (t2039/t2252).
    const result = renameSession(sessionID, title)

    if (result.success) {
      return `Session renamed to: ${result.message}`
    }
    return `Failed to rename session: ${result.message}`
  },
})

// Also export a tool that syncs with the current git branch.
// This path IS guarded — auto-compaction and routine syncs from a canonical
// repo on main must not clobber meaningful titles (t2252).
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

    const result = syncSessionWithBranch(sessionID, branch)

    switch (result.outcome) {
      case "renamed":
        return `Session synced with branch: ${result.message}`
      case "skipped":
        return result.message
      case "error":
        return `Failed to sync session with branch: ${result.message}`
    }
  },
})
