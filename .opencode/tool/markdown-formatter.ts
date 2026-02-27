import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Format and lint markdown files - fix formatting issues, validate structure, ensure consistency",
  args: {
    action: tool.schema.enum(["format", "lint", "fix", "check"]).describe("Action to perform"),
    target: tool.schema.string().optional().describe("Target file or directory (defaults to current directory)"),
  },
  async execute(args) {
    const target = args.target || "."
    const proc = Bun.spawn(
      ["bash", `${import.meta.dir}/../../.agents/scripts/markdown-formatter.sh`, args.action, target],
      { stdout: "pipe", stderr: "pipe" },
    )
    const [stdout, stderr] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ])
    await proc.exited
    const output = (stdout + (stderr ? "\n" + stderr : "")).trim()
    if (proc.exitCode !== 0) {
      return `[exit ${proc.exitCode}] ${output}`
    }
    return output
  },
})
