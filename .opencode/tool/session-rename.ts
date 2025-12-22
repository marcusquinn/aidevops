import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Rename the current session to a new title. Use this after creating a git branch to sync the session name with the branch name.",
  args: {
    title: tool.schema.string().describe("New title for the session (e.g., branch name like 'feature/my-feature')"),
  },
  async execute(args, context) {
    const { sessionID } = context
    const { title } = args
    
    // Call the OpenCode API to update the session
    // The server runs on localhost:4096 by default
    const port = process.env.OPENCODE_PORT || "4096"
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
        return `Failed to rename session: ${error}`
      }
      
      const session = await response.json()
      return `Session renamed to: ${session.title || title}`
    } catch (error) {
      return `Error renaming session: ${error instanceof Error ? error.message : String(error)}`
    }
  },
})

// Also export a tool that syncs with the current git branch
export const sync_branch = tool({
  description: "Rename the current session to match the current git branch name. Call this after creating or switching branches.",
  args: {},
  async execute(_args, context) {
    const { sessionID } = context
    
    // Get current branch name
    const branchResult = await Bun.$`git branch --show-current`.text()
    const branch = branchResult.trim()
    
    if (!branch) {
      return "Not in a git repository or no branch checked out"
    }
    
    // Call the OpenCode API to update the session
    const port = process.env.OPENCODE_PORT || "4096"
    const baseUrl = `http://localhost:${port}`
    
    try {
      const response = await fetch(`${baseUrl}/session/${sessionID}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ title: branch }),
      })
      
      if (!response.ok) {
        const error = await response.text()
        return `Failed to sync session with branch: ${error}`
      }
      
      const session = await response.json()
      return `Session synced with branch: ${session.title || branch}`
    } catch (error) {
      return `Error syncing session: ${error instanceof Error ? error.message : String(error)}`
    }
  },
})
