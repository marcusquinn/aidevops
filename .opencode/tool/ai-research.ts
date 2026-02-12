/**
 * AI Research Tool for OpenCode Workers
 *
 * Lightweight sub-worker that spawns focused research queries via the
 * Anthropic API without burning the caller's context window. Workers call
 * this to get domain-specific answers using agent files as system context.
 *
 * Rate limit: 10 calls per session.
 *
 * Usage examples:
 *   ai_research(prompt: "What branch naming conventions does this project use?", domain: "git")
 *   ai_research(prompt: "Find the dispatch function", files: [".agents/scripts/supervisor-helper.sh:4900-5000"])
 *   ai_research(prompt: "How does TOON encoding work?", agents: ["tools/context/toon.md"])
 */

import { tool } from "@opencode-ai/plugin"
import {
  research,
  getCallsRemaining,
  DOMAIN_AGENTS,
} from "../lib/ai-research"

export default tool({
  description:
    "Spawn a focused research query via Anthropic API without burning your context. " +
    "Accepts agent files as system context for domain expertise. " +
    "Rate limit: 10 calls per session. Default model: haiku (cheapest).",
  args: {
    prompt: tool.schema
      .string()
      .describe("The research question or query (required)"),
    agents: tool.schema
      .string()
      .optional()
      .describe(
        "Comma-separated agent file paths relative to ~/.aidevops/agents/ " +
          "(e.g. 'workflows/git-workflow.md,tools/git/github-cli.md')"
      ),
    domain: tool.schema
      .string()
      .optional()
      .describe(
        "Domain shorthand — auto-resolves to relevant agents. " +
          "Available: " +
          Object.keys(DOMAIN_AGENTS).join(", ")
      ),
    files: tool.schema
      .string()
      .optional()
      .describe(
        "Comma-separated file paths with optional line ranges " +
          "(e.g. 'src/index.ts:10-50,README.md')"
      ),
    model: tool.schema
      .enum(["haiku", "sonnet", "opus"])
      .optional()
      .describe(
        "Model tier: haiku (default, cheapest), sonnet (code), opus (complex reasoning)"
      ),
    max_tokens: tool.schema
      .number()
      .optional()
      .describe("Max response tokens (default: 500, max: 4096)"),
  },
  async execute(args) {
    try {
      // Parse comma-separated lists
      const agents = args.agents
        ? args.agents.split(",").map((s) => s.trim()).filter(Boolean)
        : undefined
      const files = args.files
        ? args.files.split(",").map((s) => s.trim()).filter(Boolean)
        : undefined

      // Clamp max_tokens
      const maxTokens = args.max_tokens
        ? Math.min(Math.max(args.max_tokens, 50), 4096)
        : undefined

      const result = await research({
        prompt: args.prompt,
        agents,
        domain: args.domain,
        files,
        model: args.model as "haiku" | "sonnet" | "opus" | undefined,
        max_tokens: maxTokens,
      })

      return (
        `${result.content}\n\n` +
        `--- ai-research: ${result.model} | ` +
        `in:${result.input_tokens} out:${result.output_tokens} | ` +
        `${result.calls_remaining} calls remaining ---`
      )
    } catch (error) {
      const remaining = getCallsRemaining()
      const message = error instanceof Error ? error.message : String(error)
      return `Error: ${message}\n(${remaining} calls remaining)`
    }
  },
})
