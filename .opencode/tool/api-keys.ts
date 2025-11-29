import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Securely manage API keys - list configured services, set new keys, validate keys (never exposes actual key values)",
  args: {
    action: tool.schema.enum(["list", "set", "validate", "help"]).describe("Action to perform"),
    service: tool.schema.string().optional().describe("Service name (e.g., openai, anthropic, github)"),
  },
  async execute(args) {
    const service = args.service || ""
    const result = await Bun.$`bash ${import.meta.dir}/../../.agent/scripts/setup-local-api-keys.sh ${args.action} ${service}`.text()
    return result.trim()
  },
})
