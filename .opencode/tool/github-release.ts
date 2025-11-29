import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Create and manage GitHub releases with automatic changelog generation and version bumping",
  args: {
    action: tool.schema.enum(["create", "draft", "list", "latest", "help"]).describe("Action to perform"),
    version: tool.schema.string().optional().describe("Version tag (e.g., v1.2.3)"),
    notes: tool.schema.string().optional().describe("Release notes or changelog"),
  },
  async execute(args) {
    const version = args.version || ""
    const notes = args.notes || ""
    const result = await Bun.$`bash ${import.meta.dir}/../../.agent/scripts/github-release-helper.sh ${args.action} ${version} ${notes}`.text()
    return result.trim()
  },
})
