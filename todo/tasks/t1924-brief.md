<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1924: aidevops init-routines — scaffold private routines repo

## Origin

- **Created:** 2026-04-08
- **Session:** OpenCode interactive
- **Created by:** marcus + ai-interactive
- **Conversation context:** Designing the routines system as an extension of TODO format. Need a scaffolding command to create the private routines repo, register it, and provide the structure for routine definitions and issue tracking.

## What

New CLI command `aidevops init-routines` and helper script that scaffolds a private git repo for routine definitions. Supports personal repos, per-org repos, and local-only (no remote).

Scaffolded repo structure:
```
~/Git/aidevops-routines/
├── TODO.md              # Routine definitions with repeat: fields
├── routines/            # YAML specs for complex routines
│   └── .gitkeep
├── .gitignore
└── .github/
    └── ISSUE_TEMPLATE/
        └── routine.md   # Template for routine tracking issues
```

## Why

Routine definitions need to be version-controlled and trackable via issues. The routines repo is the single source of truth — `cron-jobs.json` becomes a derived cache. Repos are always private (enforced, no override). Users who don't want a remote set `local_only: true`.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** — 3 new files
- [ ] **Complete code blocks for every edit?** — function signatures provided, not verbatim
- [x] **No judgment or design decisions?** — scaffolding is specified
- [x] **No error handling or fallback logic to design?** — standard error handling
- [ ] **Estimate 1h or less?** — ~2h
- [x] **4 or fewer acceptance criteria?** — 6

**Selected tier:** `tier:standard`

**Tier rationale:** 3 new files, standard helper script pattern, but needs gh API integration and repos.json registration logic.

## How (Approach)

### Files to Modify

- `NEW: .agents/scripts/init-routines-helper.sh` — model on existing init patterns in `init-helper.sh`
- `NEW: .agents/scripts/commands/init-routines.md` — slash command doc
- `NEW: .agents/scripts/setup/_routines.sh` — setup module for interactive setup flow
- `EDIT: .agents/scripts/aidevops-cli.sh` (or equivalent) — add `init-routines` subcommand routing
- `EDIT: setup.sh` — add `confirm_step "Set up routines repo" && setup_routines` to interactive mode

### Implementation Steps

1. Create `init-routines-helper.sh` with:
   - `init_personal()` — `gh repo create aidevops-routines --private`, clone, scaffold
   - `init_org(org_name)` — `gh repo create $org/aidevops-routines --private`, clone, scaffold
   - `init_local()` — `git init`, scaffold, set `local_only: true`
   - `scaffold_repo(path)` — creates TODO.md (with Routines section header and format reference), routines/.gitkeep, .github/ISSUE_TEMPLATE/routine.md, .gitignore
   - `register_repo(path, slug)` — appends to `repos.json` initialized_repos array with `pulse: true, priority: "tooling"`
   - `detect_and_create_all()` — for setup integration:
     - Detect username: `gh api user --jq '.login'`
     - Check if `<username>/aidevops-routines` exists, create if not
     - Detect admin orgs: `gh api user/orgs --jq '.[].login'`, filter by admin role
     - For each admin org, check/create `<org>/aidevops-routines`
     - Register all in repos.json
   - Privacy enforcement: `--private` flag hardcoded, no override

2. Create setup module `_routines.sh`:
   - Sources `init-routines-helper.sh`
   - Calls `detect_and_create_all()` in interactive mode
   - In non-interactive mode: only creates personal repo (orgs require confirmation)

3. Create slash command doc `init-routines.md`

4. Wire into setup.sh interactive flow and CLI entrypoint

Note: `aidevops update` does NOT auto-create repos. At most verifies local clone exists and warns if missing.

### Verification

```bash
# Dry run test
~/.aidevops/agents/scripts/init-routines-helper.sh --help
# After running:
test -f ~/Git/aidevops-routines/TODO.md
jq '.initialized_repos[] | select(.slug | contains("routines"))' ~/.config/aidevops/repos.json
```

## Acceptance Criteria

- [ ] `aidevops init-routines` creates a private repo with correct structure
  ```yaml
  verify:
    method: bash
    run: "grep -q 'init.routines\\|init-routines' .agents/scripts/init-routines-helper.sh"
  ```
- [ ] `aidevops init-routines --org <name>` creates per-org variant
- [ ] `aidevops init-routines --local` creates local-only (no remote)
- [ ] Repo registered in `repos.json` with `pulse: true`
- [ ] TODO.md in scaffolded repo has Routines section with format reference
- [ ] `/init-routines` slash command doc exists
  ```yaml
  verify:
    method: bash
    run: "test -f .agents/scripts/commands/init-routines.md"
  ```

## Context & Decisions

- Always private — no flag to make public. Routine definitions may contain client names, internal schedules, etc.
- Per-org variant uses `<org>/aidevops-routines` naming convention
- `local_only: true` for users who don't want any remote — git still works locally for history
- `cron-jobs.json` remains as derived cache, not definition source
- Custom scripts/agents for routines live in `~/.aidevops/agents/custom/` (referenced by `run:` field)

## Relevant Files

- `.agents/scripts/init-helper.sh` — existing init pattern to model on
- `~/.config/aidevops/repos.json` — registration target
- `.agents/AGENTS.md` — repos.json structure docs
- `.agents/scripts/commands/routine.md` — related routine command

## Dependencies

- **Blocked by:** t1923 (format must be defined for scaffolded TODO.md)
- **Blocks:** t1925, t1926 (need routines repo to exist)
- **External:** `gh` CLI for repo creation

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Read init-helper.sh pattern |
| Implementation | 1.5h | Helper script, command doc, CLI routing |
| Testing | 30m | Test personal, org, local variants |
| **Total** | **~2h** | |
