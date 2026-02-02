import { tool } from "@opencode-ai/plugin"

/**
 * Auto-detect the OpenCode API port by scanning common ports.
 * OpenCode typically runs on 4096, but may use 4097-4099 if ports are busy.
 */
async function findOpenCodePort(): Promise<string | null> {
  // Check environment variable first
  if (process.env.OPENCODE_PORT) {
    return process.env.OPENCODE_PORT
  }
  
  // Scan common ports
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

/**
 * Helper function to rename a session via the OpenCode API.
 * Extracts common logic to avoid duplication between tools.
 */
async function renameSession(sessionID: string, title: string): Promise<{ success: boolean; message: string }> {
  const port = await findOpenCodePort()
  
  if (!port) {
    return { 
      success: false, 
      message: "Unable to find OpenCode API. Tried ports 4096-4099. Set OPENCODE_PORT env var if using a different port." 
    }
  }
  
  const baseUrl = `http://localhost:${port}`
  
  try {
    const response = await fetch(`${baseUrl}/session/${sessionID}`, {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
      },
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

export default tool({
  description: "Rename the current session to a new title. Use this after creating a git branch to sync the session name with the branch name.",
  args: {
    title: tool.schema.string().describe("New title for the session (e.g., branch name like 'feature/my-feature')"),
  },
  async execute(args, context) {
    const { sessionID } = context
    const { title } = args
    
    const result = await renameSession(sessionID, title)
    
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
    const { sessionID } = context
    
    // Get current branch name - wrapped in try/catch to handle non-git directories
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
    
    const result = await renameSession(sessionID, branch)
    
    if (result.success) {
      return `Session synced with branch: ${result.message}`
    }
    return `Failed to sync session with branch: ${result.message}`
  },
})
