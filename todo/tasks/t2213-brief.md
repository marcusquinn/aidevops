<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2213: sync cloudron skill files with upstream

**Session origin:** interactive (maintainer, Marcus Quinn)
**GitHub:** GH#19702
**Tier:** tier:simple (three bounded edit blocks, docs-only, upstream canonical source)

## What

Three focused docs-only edits to align our imported Cloudron skill files with upstream `git.cloudron.io/docs/skills`, the canonical source our `cloudron-app-*-skill.md` files are imported from. Side-by-side review identified three concrete drifts.

## Why

- `cloudron-server-ops-skill.md` omits the entire `cloudron sync` command family. Users asking "how do I sync a directory to a Cloudron app" get the wrong shape (push/pull) when upstream explicitly says to prefer `sync` for directory transfers.
- `cloudron-app-packaging-skill.md` has a placeholder `@sha256:...` on the base image line and doesn't carry upstream's rationale for why the final stage MUST be the pinned tag.
- Internal drift: our native `cloudron-app-packaging.md` uses a different memory-per-worker divisor (128MB) than upstream (150MB), and doesn't pin the base image SHA — so a reader following either path gets a subtly different message.

Deployed skills at `~/.claude/skills/cloudron-*/SKILL.md` are symlinks to our repo files, so fixing the source fixes the deployment automatically.

## How

### P1 — `.agents/tools/deployment/cloudron-server-ops-skill.md`

Model on upstream `https://git.cloudron.io/docs/skills/-/raw/master/cloudron-server-ops/SKILL.md`. Add, in this order:

- After the File Transfer section (currently lines 83-89), insert `cloudron sync push`/`sync pull` examples with `--delete` / `--force`, and the rule: "A trailing slash on the source syncs its contents; without it, the directory itself is placed inside the destination (rsync convention)." Plus the guidance: "For directory transfers, prefer `cloudron sync`; keep `cloudron push`/`pull` for one-off file copy and stream-oriented use cases."
- Add `cloudron completion` under Utilities (currently lines 117-120).
- Add a "Common workflows" section at the end with compact code blocks for: (a) check and restart a misbehaving app, (b) debug a crashing app, (c) backup and restore, (d) set env vars for an app.

### P2 — `.agents/tools/deployment/cloudron-app-packaging-skill.md`

Model on upstream `https://git.cloudron.io/docs/skills/-/raw/master/cloudron-app-packaging/SKILL.md`. Apply:

- Replace line 55 `FROM cloudron/base:5.0.0@sha256:...` with the concrete pin `FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c`.
- Add a one-line rationale paragraph before or after the Dockerfile block: "The final stage must use the SHA-pinned `cloudron/base` — platform tooling (file manager, web terminal, log viewer) depends on utilities provided by this base image."
- Extend the "Manifest Essentials" minimal JSON (no change) with a follow-up common-fields table covering: `configurePath`, `postInstallMessage` (note `<sso>`/`<nosso>` substitution), `tcpPorts`, `udpPorts`, `httpPorts`, `multiDomain`, `optionalSso`, `memoryLimit`, `minBoxVersion`. Keep the pointer to `manifest-ref.md` for full depth.

### P3 — `.agents/tools/deployment/cloudron-app-packaging.md` (native guide)

- Line 90: update `FROM cloudron/base:5.0.0` (in prose) to point to the pinned SHA via cross-reference ("See `cloudron-app-packaging-skill.md` for the current SHA pin") or quote the pin directly.
- Lines 104-115 (worker-count snippet): change divisor from `128` to `150` to match upstream, and add a cap at 8 workers (upstream: `worker_count=$((worker_count > 8 ? 8 : worker_count))`). Both are defensible; matching upstream reduces maintenance burden.

## Acceptance criteria

- [ ] `cloudron-server-ops-skill.md` documents `cloudron sync push` and `cloudron sync pull` with flags and trailing-slash convention
- [ ] `cloudron-server-ops-skill.md` documents `cloudron completion`
- [ ] `cloudron-server-ops-skill.md` has a "Common workflows" block
- [ ] `cloudron-app-packaging-skill.md` pins the concrete SHA on the base image line
- [ ] `cloudron-app-packaging-skill.md` has the upstream base-image rationale line
- [ ] `cloudron-app-packaging-skill.md` manifest table lists the six common fields plus `memoryLimit`/`minBoxVersion`
- [ ] `cloudron-app-packaging.md` base image is consistent with skill (pin or cross-ref)
- [ ] `cloudron-app-packaging.md` worker-count divisor matches upstream (`/150`, cap 1-8)
- [ ] `markdownlint-cli2` clean on all three files
- [ ] Deployed `~/.claude/skills/cloudron-*/SKILL.md` symlinks resolve to updated content (verify post-merge)

## Verification

```bash
# Lint
markdownlint-cli2 .agents/tools/deployment/cloudron-server-ops-skill.md \
                  .agents/tools/deployment/cloudron-app-packaging-skill.md \
                  .agents/tools/deployment/cloudron-app-packaging.md

# Content checks
grep -l "cloudron sync push" .agents/tools/deployment/cloudron-server-ops-skill.md
grep -l "sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c" .agents/tools/deployment/cloudron-app-packaging-skill.md
grep "memory_limit / 1024 / 1024 / 150" .agents/tools/deployment/cloudron-app-packaging.md

# Symlink integrity (post-merge)
readlink ~/.claude/skills/cloudron-server-ops/SKILL.md
readlink ~/.claude/skills/cloudron-app-packaging/SKILL.md
```

## Context

- Upstream canonical: https://git.cloudron.io/docs/skills (master branch)
- Imported files carry `imported_from: external` YAML frontmatter
- Deployed via symlink: `~/.claude/skills/cloudron-{packaging,publishing,server-ops}/SKILL.md` → `~/.aidevops/agents/tools/deployment/cloudron-*-skill.md`
- Upstream `cloudron-app-publishing` is already aligned — no changes needed
- Our native `cloudron-app-packaging.md` and `services/hosting/cloudron.md` are intentionally ahead of upstream (pre-packaging scoring, 9.1+ features, diagnostic playbook) — no scope change
