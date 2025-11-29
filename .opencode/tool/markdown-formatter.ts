import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Format and lint markdown files - fix formatting issues, validate structure, ensure consistency",
  args: {
    action: tool.schema.enum(["format", "lint", "fix", "check"]).describe("Action to perform"),
    target: tool.schema.string().optional().describe("Target file or directory (defaults to current directory)"),
  },
  async execute(args) {
    const target = args.target || "."
    const result = await Bun.$`bash ${import.meta.dir}/../../.agent/scripts/markdown-formatter.sh ${args.action} ${target}`.text()
    return result.trim()
  },
})
