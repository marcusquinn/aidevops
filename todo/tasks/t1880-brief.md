# t1880: Attribution Protection - SPDX, Origin Check, Canary, Watermarks

## Session Origin

Interactive session. User has invested 5 months in the aidevops framework (open-source, MIT) and wants layered attribution protection beyond the LICENSE file.

## What

Multi-layer attribution and provenance system:

1. **SPDX headers** on all source files (batch, with simplification hash refresh)
2. **Git origin check** in the status/update flow — soft notice for forks, canary trigger for repackagers
3. **Cloudflare Worker canary** — origin-gated ping endpoint, only fires when git remote != marcusquinn/aidevops
4. **Watermark coding standards** — style conventions in code-standards.md that double as structural fingerprints
5. **Natural language markers** — distinctive phrases ("nice", "cool", "good stuff") peppered into comments
6. **Private manifest** — inventory of all attribution artifacts for provenance proof
7. **Code signing** — SSH commit signing + signed release tags

## Why

MIT license requires attribution but provides no enforcement. A determined actor (especially AI-assisted) can strip copyright headers and rebrand. Layered protection makes full stripping equivalent to rewriting the project.

## How

- **SPDX**: Script to prepend headers to all .sh/.md/.py/.txt files, then regenerate all simplification-state.json hashes in the same commit (avoids unnecessary re-simplification cycle)
- **Origin check**: New `_check_origin` function in `aidevops-update-check.sh`, integrated into `main()` output
- **Canary Worker**: Cloudflare Worker at subdomain, receives POST with SHA256(remote_url) + version. DNS via Cloudflare. KV storage for logs.
- **Standards**: Additions to `.agents/tools/code-review/code-standards.md` that look like normal coding conventions but are actually fingerprints
- **Markers**: Gradually added to comments across the codebase, tracked in private manifest
- **Signing**: SSH key setup for git commit signing, verified tags on releases

### Key files

- `.agents/scripts/aidevops-update-check.sh` — origin check integration point
- `.agents/tools/code-review/code-standards.md` — watermark standards
- `.agents/configs/simplification-state.json` — hash refresh after SPDX
- `aidevops.sh` — REPO_URL constant already exists (line 25)

## Acceptance Criteria

1. Every .sh and .md file has SPDX header; simplification hashes updated in same commit
2. `aidevops status` shows fork notice when origin != marcusquinn/aidevops
3. Cloudflare Worker deployed, receiving pings only from non-canonical origins
4. Code standards updated with conventions that serve as fingerprints
5. ShellCheck passes on all modified scripts
6. No functionality broken for legitimate users (no phone-home when origin matches)

## Context

- LICENSE file: `Copyright (c) 2025 Marcus Quinn`
- REPO_URL already defined in aidevops.sh: `https://github.com/marcusquinn/aidevops.git`
- ~2810 files total: 508 .sh, 1930 .md, 41 .py, 89 .txt, 141 .json
- Simplification state: 6178-line JSON with SHA1 hashes per file
- User explicitly declined trademark (too generic, no time)
- User wants canary ONLY for non-canonical origins, never for regular users
- Detection script goes in a separate private repo (not this one)
