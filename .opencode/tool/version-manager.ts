import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Manage project versions - bump versions, validate consistency, generate changelogs",
  args: {
    action: tool.schema.enum(["bump", "get", "validate", "sync", "help"]).describe("Action to perform"),
    type: tool.schema.enum(["major", "minor", "patch"]).optional().describe("Version bump type"),
  },
  async execute(args) {
    const type = args.type || ""
    const result = await Bun.$`bash ${import.meta.dir}/../../.agents/scripts/version-manager.sh ${args.action} ${type}`.text()
    return result.trim()
  },
})
