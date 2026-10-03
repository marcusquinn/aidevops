/**
 * AI Research Tool for OpenCode Workers
 *
 * Lightweight sub-worker that routes focused research through OpenCode's
 * configured providers without burning the caller's context window. Workers
 * call this to get domain-specific answers using agent files as context.
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
  formatResearchResult,
  research,
  getCallsRemaining,
  DOMAIN_AGENTS,
} from "../lib/ai-research"

export default tool({
  // Sent on every request in this repository; keep wording compact (GH#32592).
  description:
    "Focused provider-neutral research sub-query that spares your context. " +
    "Inference-only (no browsing or repo access): pass source excerpts via files and guidance via agents; paths only named in the prompt are not loaded. " +
    "10 calls per session.",
  args: {
    prompt: tool.schema.string().describe("Research question"),
    agents: tool.schema
      .string()
      .optional()
      .describe("Comma-separated paths under ~/.aidevops/agents/, e.g. 'workflows/git-workflow.md'"),
    domain: tool.schema
      .string()
      .optional()
      .describe("Shorthand resolving to agents: " + Object.keys(DOMAIN_AGENTS).join(", ")),
    files: tool.schema
      .string()
      .optional()
      .describe("Comma-separated files with optional line ranges, e.g. 'src/index.ts:10-50,README.md'"),
    model: tool.schema
      .enum(["simple", "standard", "thinking", "haiku", "sonnet", "opus"])
      .optional()
      .describe("Workload tier (default simple); haiku/sonnet/opus are legacy aliases"),
    max_tokens: tool.schema
      .number()
      .optional()
      .describe("Approximate response-token budget (default 500, max 4096)"),
  },
  async execute(args, context) {
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
        model: args.model,
        max_tokens: maxTokens,
      }, {
        cwd: context.directory,
        signal: context.abort,
      })

      return formatResearchResult(result)
    } catch (error) {
      const remaining = getCallsRemaining()
      const message = error instanceof Error ? error.message : String(error)
      return `Error: ${message}\n(${remaining} calls remaining)`
    }
  },
})
