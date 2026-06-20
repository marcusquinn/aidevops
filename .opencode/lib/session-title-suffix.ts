import { existsSync, readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const AIDEVOPS_TITLE_SUFFIX_RE = /\s+· AIDevOps \d+\.\d+\.\d+$/

function readVersionFile(path: string): string {
  if (!existsSync(path)) return ""
  return readFileSync(path, "utf8").trim()
}

export function getAidevopsVersion(): string {
  if (process.env.AIDEVOPS_VERSION) return process.env.AIDEVOPS_VERSION.trim()

  const here = dirname(fileURLToPath(import.meta.url))
  const candidates = [
    join(here, "..", "..", "VERSION"),
    join(here, "..", "..", ".agents", "VERSION"),
    join(process.env.HOME || "", ".aidevops", "agents", "VERSION"),
  ]

  for (const candidate of candidates) {
    const version = readVersionFile(candidate)
    if (version) return version
  }

  return ""
}

export function withAidevopsTitleSuffix(title: string, version = getAidevopsVersion()): string {
  const baseTitle = title.replace(AIDEVOPS_TITLE_SUFFIX_RE, "")
  if (!version) return baseTitle
  return `${baseTitle} · AIDevOps ${version}`
}
