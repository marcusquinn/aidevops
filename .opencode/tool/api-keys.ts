import { tool } from "@opencode-ai/plugin"

export default tool({
  description: "Securely manage API keys and multi-tenant credentials - list services, set keys, switch tenants (never exposes actual key values)",
  args: {
    action: tool.schema.enum(["list", "set", "validate", "help", "tenant-status", "tenant-switch", "tenant-list", "tenant-create", "tenant-keys"]).describe("Action to perform"),
    service: tool.schema.string().optional().describe("Service/key name (e.g., openai, anthropic, github) or tenant name for tenant-* actions"),
  },
  async execute(args) {
    const service = args.service || ""

    // Route tenant actions to credential-helper.sh
    if (args.action.startsWith("tenant-")) {
      const subcommand = args.action.replace("tenant-", "")
      const result = await Bun.$`bash ${import.meta.dir}/../../.agents/scripts/credential-helper.sh ${subcommand} ${service}`.text()
      return result.trim()
    }

    const result = await Bun.$`bash ${import.meta.dir}/../../.agents/scripts/setup-local-api-keys.sh ${args.action} ${service}`.text()
    return result.trim()
  },
})
