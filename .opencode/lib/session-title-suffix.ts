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

// GH#37630: mirrors .agents/plugins/opencode-aidevops/session-title-suffix.mjs.
// Interactive root-session titles end with `· @<last 6 of the session ID>`,
// a session-bus address. Order: `<title> · @xxxxxx[ · AIDevOps <version>]`.
const SESSION_ADDRESS_TOKEN_RE = /\s+· @[a-z0-9]{6}(?![a-z0-9])/g
const SESSION_ID_RE = /^ses_[A-Za-z0-9]{6,}$/

export function sessionAddressToken(sessionID: string): string {
  return SESSION_ID_RE.test(sessionID) ? `@${sessionID.slice(-6).toLowerCase()}` : ""
}

/** Off for headless workers or AIDEVOPS_SESSION_TITLE_ID=false|0. */
export function isSessionTitleAddressEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  if (env.FULL_LOOP_HEADLESS || env.AIDEVOPS_HEADLESS || env.OPENCODE_HEADLESS || env.GITHUB_ACTIONS) return false
  const value = (env.AIDEVOPS_SESSION_TITLE_ID || "").trim().toLowerCase()
  return value !== "false" && value !== "0"
}

export function stripSessionTitleDecorations(title: string): string {
  return sanitizeSessionTitle(title.replace(SESSION_ADDRESS_TOKEN_RE, "").replace(AIDEVOPS_TITLE_SUFFIX_RE, ""))
}

export function withSessionTitleDecorations(
  title: string,
  { version = sessionTitleVersion(), sessionID = "" }: { version?: string; sessionID?: string } = {},
): string {
  const baseTitle = stripSessionTitleDecorations(title)
  if (!baseTitle) return baseTitle
  const token = sessionAddressToken(sessionID)
  return [baseTitle, token, version ? `AIDevOps ${version}` : ""].filter(Boolean).join(" · ")
}
