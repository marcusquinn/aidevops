import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Manage code linters - install, configure, run, or check status of various linting tools",
  args: {
    action: tool.schema.enum(["install", "status", "run", "fix", "help"]).describe("Action to perform"),
    linter: tool.schema.string().optional().describe("Specific linter (shellcheck, markdownlint, eslint, etc.)"),
  },
  async execute(args) {
    const linter = args.linter || ""
    const result = await Bun.$`bash ${import.meta.dir}/../../.agents/scripts/linter-manager.sh ${args.action} ${linter}`.text()
    return result.trim()
  },
})
