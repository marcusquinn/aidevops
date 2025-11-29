import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Run comprehensive code quality checks using multiple linters (Codacy, SonarCloud, Qlty, CodeRabbit)",
  args: {
    target: tool.schema.string().optional().describe("Target directory or file to check (defaults to current directory)"),
    fix: tool.schema.boolean().optional().describe("Attempt to auto-fix issues where possible"),
  },
  async execute(args) {
    const target = args.target || "."
    const fixFlag = args.fix ? "--fix" : ""
    const result = await Bun.$`bash ${import.meta.dir}/../../.agent/scripts/quality-check.sh ${target} ${fixFlag}`.text()
    return result.trim()
  },
})
