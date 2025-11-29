import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Clean up system - remove caches, temporary files, logs, and other cleanup tasks",
  args: {
    target: tool.schema.enum(["all", "cache", "logs", "temp", "node_modules", "dry-run"]).describe("What to clean up"),
  },
  async execute(args) {
    const result = await Bun.$`bash ${import.meta.dir}/../../.agent/scripts/system-cleanup.sh ${args.target}`.text()
    return result.trim()
  },
})
