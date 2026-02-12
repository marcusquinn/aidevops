/**
 * AI Research - Lightweight sub-worker for OpenCode workers
 *
 * Spawns focused research queries via the Anthropic API without burning
 * the caller's context window. Accepts agent files as system context so
 * the sub-worker inherits domain expertise.
 *
 * Key features:
 * - Domain shorthand auto-resolves to relevant agents via subagent-index.toon
 * - Extracts AI-CONTEXT-START/END sections to minimise tokens
 * - Rate-limited to 10 calls per session
 * - Calls Anthropic API directly (no CLI overhead)
 */

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface ResearchRequest {
  prompt: string
  agents?: string[]
  domain?: string
  files?: string[]
  model?: "haiku" | "sonnet" | "opus"
  max_tokens?: number
}

export interface ResearchResult {
  content: string
  model: string
  input_tokens: number
  output_tokens: number
  calls_remaining: number
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const AGENTS_BASE = `${process.env.HOME || "~"}/.aidevops/agents`

const MODEL_MAP: Record<string, string> = {
  haiku: "claude-3-5-haiku-20241022",
  sonnet: "claude-sonnet-4-20250514",
  opus: "claude-opus-4-20250514",
}

const MAX_CALLS_PER_SESSION = 10

/**
 * Compact domain -> agent file mapping.
 * Derived from subagent-index.toon. Each domain resolves to 1-3 key agent
 * files that give the sub-worker enough context for that domain.
 */
export const DOMAIN_AGENTS: Record<string, string[]> = {
  git: [
    "workflows/git-workflow.md",
    "tools/git/github-cli.md",
    "tools/git/conflict-resolution.md",
  ],
  planning: ["workflows/plans.md", "tools/task-management/beads.md"],
  code: [
    "tools/code-review/code-standards.md",
    "tools/code-review/code-simplifier.md",
  ],
  seo: ["seo.md", "seo/dataforseo.md", "seo/google-search-console.md"],
  content: [
    "content.md",
    "content/research.md",
    "content/production/writing.md",
  ],
  wordpress: ["tools/wordpress/wp-dev.md", "tools/wordpress/mainwp.md"],
  browser: [
    "tools/browser/browser-automation.md",
    "tools/browser/playwright.md",
  ],
  deploy: [
    "tools/deployment/coolify.md",
    "tools/deployment/coolify-cli.md",
    "tools/deployment/vercel.md",
  ],
  security: [
    "tools/security/tirith.md",
    "tools/credentials/encryption-stack.md",
  ],
  video: [
    "tools/video/video-prompt-design.md",
    "tools/video/remotion.md",
    "tools/video/wavespeed.md",
  ],
  voice: [
    "tools/voice/speech-to-speech.md",
    "tools/voice/voice-bridge.md",
  ],
  mobile: [
    "tools/mobile/agent-device.md",
    "tools/mobile/maestro.md",
  ],
  mcp: [
    "tools/build-mcp/build-mcp.md",
    "tools/build-mcp/server-patterns.md",
  ],
  agent: [
    "tools/build-agent/build-agent.md",
    "tools/build-agent/agent-review.md",
  ],
  framework: [
    "aidevops/architecture.md",
    "aidevops/setup.md",
  ],
  hosting: [
    "services/hosting/hostinger.md",
    "services/hosting/cloudflare.md",
    "services/hosting/hetzner.md",
  ],
  email: [
    "services/email/email-testing.md",
    "services/email/email-delivery-test.md",
  ],
  accessibility: [
    "tools/accessibility/accessibility.md",
    "services/accessibility/accessibility-audit.md",
  ],
  containers: ["tools/containers/orbstack.md"],
  orchestration: [
    "tools/ai-assistants/headless-dispatch.md",
  ],
  context: [
    "tools/context/model-routing.md",
    "tools/context/toon.md",
    "tools/context/mcp-discovery.md",
  ],
  vision: [
    "tools/vision/overview.md",
    "tools/vision/image-generation.md",
  ],
  release: ["workflows/release.md", "workflows/version-bump.md"],
  pr: ["workflows/pr.md", "workflows/preflight.md"],
}

// ---------------------------------------------------------------------------
// Session-scoped rate limiter
// ---------------------------------------------------------------------------

let callCount = 0

function checkRateLimit(): void {
  if (callCount >= MAX_CALLS_PER_SESSION) {
    throw new Error(
      `Rate limit reached: ${MAX_CALLS_PER_SESSION} ai-research calls per session. ` +
        "Consolidate your queries or start a new session."
    )
  }
  callCount++
}

export function getCallsRemaining(): number {
  return MAX_CALLS_PER_SESSION - callCount
}

export function resetRateLimit(): void {
  callCount = 0
}

// ---------------------------------------------------------------------------
// Agent file loading
// ---------------------------------------------------------------------------

/**
 * Extract content between AI-CONTEXT-START and AI-CONTEXT-END markers.
 * Falls back to full content if markers are absent.
 */
export function extractAIContext(content: string): string {
  const startMarker = "<!-- AI-CONTEXT-START -->"
  const endMarker = "<!-- AI-CONTEXT-END -->"

  const startIdx = content.indexOf(startMarker)
  if (startIdx === -1) return content

  const endIdx = content.indexOf(endMarker, startIdx)
  if (endIdx === -1) return content

  return content.slice(startIdx + startMarker.length, endIdx).trim()
}

/**
 * Load an agent file, extracting AI-CONTEXT section if present.
 * Paths are resolved relative to AGENTS_BASE.
 */
async function loadAgentFile(path: string): Promise<string | null> {
  const fullPath = path.startsWith("/") ? path : `${AGENTS_BASE}/${path}`
  const file = Bun.file(fullPath)

  if (!(await file.exists())) return null

  const content = await file.text()
  return extractAIContext(content)
}

/**
 * Resolve domain shorthand to agent file paths.
 */
export function resolveDomain(domain: string): string[] {
  const key = domain.toLowerCase().replace(/[^a-z]/g, "")
  return DOMAIN_AGENTS[key] || []
}

/**
 * Load a file with optional line range (format: "path:10-50" or "path:10").
 */
async function loadFileWithRange(spec: string): Promise<string | null> {
  const match = spec.match(/^(.+?)(?::(\d+)(?:-(\d+))?)?$/)
  if (!match) return null

  const [, filePath, startLine, endLine] = match
  const file = Bun.file(filePath)

  if (!(await file.exists())) return null

  const content = await file.text()

  if (!startLine) return content

  const lines = content.split("\n")
  const start = Math.max(0, parseInt(startLine, 10) - 1)
  const end = endLine ? parseInt(endLine, 10) : start + 1

  return lines.slice(start, end).join("\n")
}

// ---------------------------------------------------------------------------
// System prompt assembly
// ---------------------------------------------------------------------------

async function buildSystemPrompt(
  agents?: string[],
  domain?: string,
  files?: string[]
): Promise<string> {
  const parts: string[] = []

  parts.push(
    "You are a focused research sub-worker. Answer the query concisely " +
      "using the provided context. Do not explain your reasoning process " +
      "unless asked. Return actionable information: file paths, line numbers, " +
      "function names, config values, or brief explanations."
  )

  // Load domain agents
  if (domain) {
    const domainPaths = resolveDomain(domain)
    for (const p of domainPaths) {
      const content = await loadAgentFile(p)
      if (content) {
        parts.push(`--- ${p} ---\n${content}`)
      }
    }
  }

  // Load explicit agent files
  if (agents?.length) {
    for (const a of agents) {
      const content = await loadAgentFile(a)
      if (content) {
        parts.push(`--- ${a} ---\n${content}`)
      }
    }
  }

  // Load file context
  if (files?.length) {
    for (const f of files) {
      const content = await loadFileWithRange(f)
      if (content) {
        parts.push(`--- ${f} ---\n${content}`)
      }
    }
  }

  return parts.join("\n\n")
}

// ---------------------------------------------------------------------------
// Anthropic API call
// ---------------------------------------------------------------------------

function getApiKey(): string {
  // Check environment variable first
  const key = process.env.ANTHROPIC_API_KEY
  if (key) return key

  throw new Error(
    "ANTHROPIC_API_KEY not found. Set it via: aidevops secret set ANTHROPIC_API_KEY"
  )
}

export async function research(req: ResearchRequest): Promise<ResearchResult> {
  checkRateLimit()

  const modelTier = req.model || "haiku"
  const modelId = MODEL_MAP[modelTier]
  if (!modelId) {
    throw new Error(
      `Unknown model tier: ${modelTier}. Use: haiku, sonnet, or opus`
    )
  }

  const maxTokens = req.max_tokens || 500
  const systemPrompt = await buildSystemPrompt(
    req.agents,
    req.domain,
    req.files
  )

  const apiKey = getApiKey()

  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: modelId,
      max_tokens: maxTokens,
      system: systemPrompt,
      messages: [{ role: "user", content: req.prompt }],
    }),
  })

  if (!response.ok) {
    const body = await response.text()
    throw new Error(`Anthropic API error (${response.status}): ${body}`)
  }

  const data = (await response.json()) as {
    content: Array<{ type: string; text: string }>
    usage: { input_tokens: number; output_tokens: number }
  }

  const text = data.content
    .filter((c) => c.type === "text")
    .map((c) => c.text)
    .join("")

  return {
    content: text,
    model: modelId,
    input_tokens: data.usage.input_tokens,
    output_tokens: data.usage.output_tokens,
    calls_remaining: getCallsRemaining(),
  }
}
