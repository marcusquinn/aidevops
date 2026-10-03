import { Database } from "bun:sqlite"
import { tool } from "@opencode-ai/plugin"
import { getDbPath } from "../lib/opencode-db-path"
import {
  isDefaultBranchTitle,
  isTitleOverwritable,
  purposePreservingTitle,
} from "../lib/session-rename-guards"
import { withAidevopsTitleSuffix } from "../lib/session-title-suffix"
import { emitTerminalTitle } from "../lib/terminal-title"

/**
 * Rename a session by updating the title directly in the SQLite database.
 *
 * OpenCode CLI sessions do not expose an HTTP API — Session.setTitle() is a
 * Drizzle ORM call that writes to the local SQLite DB. The TUI reads from the
 * same DB and picks up changes immediately (verified empirically).
 */
function renameSession(
  sessionID: string,
  title: string,
  replacePurpose = false,
): { success: boolean; message: string } {
  const dbPath = getDbPath()

  try {
    const db = new Database(dbPath)
    try {
      const current = db
        .query("SELECT COALESCE(title, '') AS title FROM session WHERE id = ?")
        .get(sessionID) as { title: string } | null
      const preservedTitle = purposePreservingTitle(current?.title || "", title, replacePurpose)
      const displayTitle = withAidevopsTitleSuffix(preservedTitle)
      const nowMs = Date.now()
      const result = db.run(
        "UPDATE session SET title = ?, time_updated = ? WHERE id = ?",
        [displayTitle, nowMs, sessionID],
      )

      if (result.changes === 0) {
        return { success: false, message: `Session ${sessionID} not found in database` }
      }

      return { success: true, message: displayTitle }
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

      const displayTitle = withAidevopsTitleSuffix(branch)
      const nowMs = Date.now()
      const result = db.run(
        "UPDATE session SET title = ?, time_updated = ? WHERE id = ?",
        [displayTitle, nowMs, sessionID],
      )

      if (result.changes === 0) {
        return { outcome: "error", message: `Session ${sessionID} not found in database` }
      }

      return { outcome: "renamed", message: displayTitle }
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

// Descriptions are sent on every request in this repository; keep them
// compact without dropping title rules (GH#32592).
export default tool({
  description:
    "Set or extend the session title. The first meaningful purpose stays as the stable prefix; later phases append '— Current: ...'. Skip renames for transient state (branch, phase, review, release) when the title already identifies the session. Keep issue/PR identity first. Long titles are fine; the AIDevOps version suffix is automatic.",
  args: {
    title: tool.schema
      .string()
      .describe("Title or current-context description"),
    replace_purpose: tool.schema
      .boolean()
      .optional()
      .describe("Replace the stable purpose; only when the user explicitly repurposes the whole session"),
  },
  async execute(args, context) {
    const { sessionID } = context
    const { title, replace_purpose: replacePurpose = false } = args

    const result = renameSession(sessionID, title, replacePurpose)

    if (result.success) {
      emitTerminalTitle(result.message)
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
    "Rename the session to the current git branch after creating or switching branches, unless an 'Issue #N: <title>' or 'PR #N: <title>' prefix is already set.",
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
        emitTerminalTitle(result.message)
        return `Session synced with branch: ${result.message}`
      case "skipped":
        return result.message
      case "error":
        return `Failed to sync session with branch: ${result.message}`
    }
  },
})
