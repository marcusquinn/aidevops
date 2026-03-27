import { tool } from "@opencode-ai/plugin"

function normalizeVersion(version?: string): string {
  if (!version) return ""
  return version.startsWith("v") ? version : `v${version}`
}

function requireVersion(version: string, action: string): string | null {
  if (!version) {
    return `Error: Version required for ${action} action. Usage: github-release ${action} v1.2.3`
  }
  return null
}

async function createRelease(version: string, notes?: string): Promise<string> {
  const checkResult = await Bun.$`gh release view ${version} 2>&1`.text().catch(() => "not found")
  if (!checkResult.includes("not found") && !checkResult.includes("release not found")) {
    return `Release ${version} already exists. Use 'gh release view ${version}' to see details.`
  }

  if (notes) {
    const result = await Bun.$`gh release create ${version} --title ${version} --notes ${notes}`.text()
    return `Release ${version} created successfully.\n${result}`
  }
  const result = await Bun.$`gh release create ${version} --title ${version} --generate-notes`.text()
  return `Release ${version} created with auto-generated notes.\n${result}`
}

async function createDraftRelease(version: string, notes?: string): Promise<string> {
  if (notes) {
    const result = await Bun.$`gh release create ${version} --title ${version} --notes ${notes} --draft`.text()
    return `Draft release ${version} created.\n${result}`
  }
  const result = await Bun.$`gh release create ${version} --title ${version} --generate-notes --draft`.text()
  return `Draft release ${version} created with auto-generated notes.\n${result}`
}

function formatGhError(error: unknown): string {
  const errorMessage = error instanceof Error ? error.message : String(error)
  if (errorMessage.includes("gh: command not found")) {
    return "Error: gh CLI not installed. Install with: brew install gh"
  }
  if (errorMessage.includes("not logged in")) {
    return "Error: gh CLI not authenticated. Run: gh auth login"
  }
  return `Error: ${errorMessage}`
}

const HELP_TEXT = `GitHub Release Tool (uses gh CLI)

Actions:
  create <version>  Create a new release (auto-generates changelog)
  draft <version>   Create a draft release for review
  list              List recent releases
  latest            Show the latest release details
  help              Show this help message

Examples:
  github-release create v1.2.3
  github-release create v1.2.3 --notes "Custom release notes"
  github-release draft v2.0.0
  github-release list
  github-release latest

Requirements:
  - gh CLI installed and authenticated (gh auth login)
  - Repository must be a git repo with GitHub remote

Note: Uses --generate-notes for automatic changelog from commits/PRs.`

export default tool({
  description: "Create and manage GitHub releases using gh CLI with automatic changelog generation",
  args: {
    action: tool.schema.enum(["create", "draft", "list", "latest", "help"]).describe("Action to perform"),
    version: tool.schema.string().optional().describe("Version tag (e.g., v1.2.3 or 1.2.3)"),
    notes: tool.schema.string().optional().describe("Release notes (optional - auto-generates if not provided)"),
  },
  async execute(args) {
    const version = normalizeVersion(args.version)

    try {
      switch (args.action) {
        case "create": {
          const versionError = requireVersion(version, "create")
          if (versionError) return versionError
          return await createRelease(version, args.notes)
        }

        case "draft": {
          const versionError = requireVersion(version, "draft")
          if (versionError) return versionError
          return await createDraftRelease(version, args.notes)
        }

        case "list": {
          const result = await Bun.$`gh release list --limit 10`.text()
          return result || "No releases found."
        }

        case "latest": {
          const result = await Bun.$`gh release view --json tagName,name,publishedAt,url`.text()
          return result || "No releases found."
        }

        case "help":
        default:
          return HELP_TEXT
      }
    } catch (error) {
      return formatGhError(error)
    }
  },
})
