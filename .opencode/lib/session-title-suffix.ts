import { existsSync, readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const AIDEVOPS_TITLE_SUFFIX_RE = /\s+· AIDevOps \d+\.\d+\.\d+$/
const IMAGE_PLACEHOLDER_RE = /\[Image\s+\d+\]/gi

function readVersionFile(path: string): string {
  try {
    if (!existsSync(path)) return ""
    return readFileSync(path, "utf8").trim()
  } catch {
    return ""
  }
}

export function getAidevopsVersion(env: NodeJS.ProcessEnv = process.env): string {
  const here = dirname(fileURLToPath(import.meta.url))
  const activeAgentsDir = env.AIDEVOPS_ACTIVE_AGENTS_DIR || join(env.HOME || "", ".aidevops", "agents")
  const activeVersion = readVersionFile(join(activeAgentsDir, "VERSION"))
  if (activeVersion) return activeVersion
  if (env.AIDEVOPS_VERSION?.trim()) return env.AIDEVOPS_VERSION.trim()

  const candidates = [
    join(here, "..", "..", "VERSION"),
    join(here, "..", "..", ".agents", "VERSION"),
  ]

  for (const candidate of candidates) {
    const version = readVersionFile(candidate)
    if (version) return version
  }

  return ""
}

export function sanitizeSessionTitle(title: string): string {
  return title.replace(IMAGE_PLACEHOLDER_RE, " ").replace(/\s+/g, " ").trim()
}

// Paused (t18612): session titles no longer carry `· AIDevOps <version>`; the
// OpenCode 1.x sidebar footer (v1-tui plugin) shows it, as OpenCode 2 does.
// Set AIDEVOPS_SESSION_TITLE_VERSION_SUFFIX=true to restore.
export function isSessionTitleVersionSuffixEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  const value = (env.AIDEVOPS_SESSION_TITLE_VERSION_SUFFIX || "").trim().toLowerCase()
  return value === "true" || value === "1"
}

export function sessionTitleVersion(env: NodeJS.ProcessEnv = process.env): string {
  return isSessionTitleVersionSuffixEnabled(env) ? getAidevopsVersion(env) : ""
}

export function withAidevopsTitleSuffix(title: string, version = sessionTitleVersion()): string {
  const baseTitle = sanitizeSessionTitle(title.replace(AIDEVOPS_TITLE_SUFFIX_RE, ""))
  if (!version) return baseTitle
  return `${baseTitle} · AIDevOps ${version}`
}
