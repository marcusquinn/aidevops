import { tool } from "@opencode-ai/plugin"

export const setup = tool({
  description: "Setup and configure MCP server integrations for AI assistants",
  args: {
    server: tool.schema.string().optional().describe("Specific MCP server to setup (or 'all')"),
  },
  async execute(args) {
    const server = args.server || "all"
    const result = await Bun.$`bash ${import.meta.dir}/../../.agent/scripts/setup-mcp-integrations.sh setup ${server}`.text()
    return result.trim()
  },
})

export const validate = tool({
  description: "Validate MCP server configurations and connectivity",
  args: {
    server: tool.schema.string().optional().describe("Specific MCP server to validate (or 'all')"),
  },
  async execute(args) {
    const server = args.server || "all"
    const result = await Bun.$`bash ${import.meta.dir}/../../.agent/scripts/validate-mcp-integrations.sh ${server}`.text()
    return result.trim()
  },
})
