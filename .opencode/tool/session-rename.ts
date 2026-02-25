import { tool } from "@opencode-ai/plugin"
import { Database } from "bun:sqlite"
import { join } from "path"
import { existsSync } from "fs"

/**
 * Resolve the OpenCode database path.
 * Uses XDG_DATA_HOME if set, otherwise ~/.local/share/opencode/opencode.db
 */
function getDbPath(): string {
  const dataHome = process.env.XDG_DATA_HOME || join(process.env.HOME || "", ".local", "share")
  return join(dataHome, "opencode", "opencode.db")
}

/**
 * Rename a session directly in the OpenCode SQLite database.
 * This works in both TUI and serve mode — no HTTP API required.
 *
 * Falls back to the HTTP API if the DB is unavailable (e.g., remote server).
 */
async function renameSession(sessionID: string, title: string, _directory: string): Promise<{ success: boolean; message: string }> {
  // Primary: direct SQLite update (works in TUI mode)
  const dbPath = getDbPath()
  if (existsSync(dbPath)) {
    try {
      const db = new Database(dbPath)
      const stmt = db.prepare("UPDATE session SET title = ?, time_updated = ? WHERE id = ?")
      const result = stmt.run(title, Math.floor(Date.now() / 1000), sessionID)
      db.close()

      if (result.changes > 0) {
        return { success: true, message: title }
      }
      return { success: false, message: `Session ${sessionID} not found in database` }
    } catch (error) {
      // DB locked or other error — fall through to HTTP API
    }
  }

  // Fallback: HTTP API (works in serve/web mode)
  const port = await findOpenCodePort()
  if (!port) {
    return {
      success: false,
      message: "Database not found and OpenCode API not responding. Cannot rename session.",
    }
  }

  const baseUrl = `http://localhost:${port}`
  const params = new URLSearchParams({ directory: _directory })

  try {
    const response = await fetch(`${baseUrl}/session/${sessionID}?${params}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title }),
    })

    if (!response.ok) {
      const error = await response.text()
      return { success: false, message: `API error (port ${port}): ${error}` }
    }

    const session = await response.json()
    return { success: true, message: session.title || title }
  } catch (error) {
    return { success: false, message: error instanceof Error ? error.message : String(error) }
  }
}

/**
 * Auto-detect the OpenCode API port by scanning common ports.
 * Only used as fallback when direct DB access fails.
 */
async function findOpenCodePort(): Promise<string | null> {
  if (process.env.OPENCODE_PORT) {
    return process.env.OPENCODE_PORT
  }

  const ports = ["4096", "4097", "4098", "4099"]
  for (const port of ports) {
    try {
      const controller = new AbortController()
      const timeout = setTimeout(() => controller.abort(), 500)

      const response = await fetch(`http://localhost:${port}/session`, {
        method: "GET",
        signal: controller.signal,
      })

      clearTimeout(timeout)

      if (response.ok) {
        return port
      }
    } catch {
      // Port not responding, try next
    }
  }

  return null
}

export default tool({
  description: "Rename the current session to a new title. Use this after creating a git branch to sync the session name with the branch name.",
  args: {
    title: tool.schema.string().describe("New title for the session (e.g., branch name like 'feature/my-feature')"),
  },
  async execute(args, context) {
    const { sessionID, directory } = context
    const { title } = args

    const result = await renameSession(sessionID, title, directory)

    if (result.success) {
      return `Session renamed to: ${result.message}`
    }
    return `Failed to rename session: ${result.message}`
  },
})

// Also export a tool that syncs with the current git branch
export const sync_branch = tool({
  description: "Rename the current session to match the current git branch name. Call this after creating or switching branches.",
  args: {},
  async execute(_args, context) {
    const { sessionID, directory } = context

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

    const result = await renameSession(sessionID, branch, directory)

    if (result.success) {
      return `Session synced with branch: ${result.message}`
    }
    return `Failed to sync session with branch: ${result.message}`
  },
})
