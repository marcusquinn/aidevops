/**
 * MCP Status Tool
 *
 * Reports the status of MCP servers registered by the aidevops plugin.
 * Checks which MCPs are configured, enabled, and reachable.
 */

import { tool } from "@opencode-ai/plugin"
import { loadMcpRegistry, registrySummary } from "../lib/mcp-registry"
import { existsSync } from "node:fs"
import { join } from "node:path"
import { homedir } from "node:os"

/**
 * Find the aidevops repo root from the working directory.
 */
function findRepoRoot(directory: string): string | null {
  if (existsSync(join(directory, "configs", "mcp-templates"))) {
    return directory
  }
  const mainRepo = join(homedir(), "Git", "aidevops")
  if (existsSync(join(mainRepo, "configs", "mcp-templates"))) {
    return mainRepo
  }
  const deployed = join(homedir(), ".aidevops")
  if (existsSync(join(deployed, "configs", "mcp-templates"))) {
    return deployed
  }
  return null
}

export default tool({
  description: "Check status of MCP servers registered by aidevops — shows enabled, disabled, and errored MCPs",
  args: {
    filter: tool.schema.enum(["all", "enabled", "disabled", "errors"]).optional()
      .describe("Filter results: all (default), enabled, disabled, or errors only"),
  },
  async execute(args, context) {
    const repoRoot = findRepoRoot(context.directory)
    if (!repoRoot) {
      return "Could not find aidevops configs directory. Ensure configs/mcp-templates/ exists in the repo or ~/.aidevops/"
    }

    const registry = await loadMcpRegistry(repoRoot)
    const filter = args.filter || "all"

    const entries = Object.entries(registry.entries)
    const enabled = entries.filter(([, c]) => c.enabled !== false)
    const disabled = entries.filter(([, c]) => c.enabled === false)

    const lines: string[] = []

    if (filter === "all" || filter === "enabled") {
      lines.push(`## Enabled MCPs (${enabled.length})`)
      for (const [name, config] of enabled) {
        if (config.type === "local") {
          lines.push(`  ${name}: local [${config.command.join(" ")}]`)
        } else {
          lines.push(`  ${name}: remote ${config.url}`)
        }
      }
      lines.push("")
    }

    if (filter === "all" || filter === "disabled") {
      lines.push(`## Disabled MCPs (${disabled.length})`)
      for (const [name, config] of disabled) {
        if (config.type === "local") {
          lines.push(`  ${name}: local [${config.command.join(" ")}] (needs configuration)`)
        } else {
          lines.push(`  ${name}: remote ${config.url} (needs configuration)`)
        }
      }
      lines.push("")
    }

    if (filter === "all" || filter === "errors") {
      if (registry.errors.length > 0) {
        lines.push(`## Errors (${registry.errors.length})`)
        for (const err of registry.errors) {
          lines.push(`  ${err.name}: ${err.reason}`)
        }
      } else if (filter === "errors") {
        lines.push("No errors found.")
      }
    }

    lines.push("")
    lines.push(registrySummary(registry))

    return lines.join("\n")
  },
})
