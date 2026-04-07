---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t1911: Add Qlty smells CI gate to prevent maintainability regression

## Origin

- **Created:** 2026-04-07
- **Session:** claude-code:qlty-maintainability-a-grade
- **Created by:** ai-interactive
- **Conversation context:** Qlty maintainability badge dropped to C. No CI step prevents new Qlty smells from landing in PRs. The existing `code-quality.yml` has shell complexity checks and Python lizard checks, but no Qlty integration. This is the gate that prevents regression once the grade recovers to A.

## What

Add a new job `qlty-smells` to `.github/workflows/code-quality.yml` that runs `qlty smells` in diff mode (vs `origin/main`) on PRs. The job fails if the PR introduces new code smells. On pushes to `main`, it runs `qlty smells --all` as an advisory baseline check.

## Why

- No CI gate currently prevents new Qlty smells from landing
- The badge dropped from A to C because complexity accumulated unchecked
- Existing CI checks (shellcheck, lizard, nesting depth) only cover shell scripts and Python CCN — not the maintainability smells Qlty scores (total complexity, function complexity, many returns, duplication, deeply nested control flow)
- Without this gate, every simplification win can be undone by the next PR

## Tier

`tier:standard`

**Tier rationale:** Adding a new CI job following existing patterns in code-quality.yml. Requires understanding Qlty CLI options but the implementation is a standard GitHub Actions job.

## How (Approach)

### Files to Modify

- `EDIT: .github/workflows/code-quality.yml` — add new `qlty-smells` job after `complexity-check`

### Implementation Steps

1. Add a new job `qlty-smells` to `code-quality.yml`:

```yaml
  qlty-smells:
    name: Qlty Maintainability Smells
    runs-on: ubuntu-latest
    # Only run on PRs — diff mode needs a comparison base
    if: github.event_name == 'pull_request'

    steps:
    - name: Checkout code
      uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4
      with:
        fetch-depth: 0

    - name: Install Qlty CLI
      run: |
        curl -sSL https://qlty.sh/install | bash
        echo "$HOME/.qlty/bin" >> "$GITHUB_PATH"

    - name: Qlty smells check (diff mode)
      run: |
        echo "Checking for new code smells vs origin/main..."
        if qlty smells 2>&1 | tee /tmp/qlty-smells-output.txt | grep -q '^[^ ]'; then
          smell_count=$(grep -c '^[^ ]' /tmp/qlty-smells-output.txt || echo "0")
          echo ""
          echo "::error::This PR introduces ${smell_count} new code smell(s). Fix before merging."
          echo "Run 'qlty smells' locally to see details."
          exit 1
        else
          echo "No new code smells introduced"
        fi
```

2. The diff mode (`qlty smells` without `--all`) automatically compares against `origin/main` — this is the default Qlty behavior and matches the existing `.qlty/qlty.toml` config.

3. Verify the install step uses a pinned version or the latest stable installer.

### Verification

```bash
# Local test — should show current smells against origin/main
~/.qlty/bin/qlty smells

# Verify workflow YAML is valid
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/code-quality.yml'))"
```

## Acceptance Criteria

- [ ] New `qlty-smells` job exists in `.github/workflows/code-quality.yml`
  ```yaml
  verify:
    method: codebase
    pattern: "qlty-smells:"
    path: ".github/workflows/code-quality.yml"
  ```
- [ ] Job runs on PRs only (`if: github.event_name == 'pull_request'`)
  ```yaml
  verify:
    method: codebase
    pattern: "pull_request"
    path: ".github/workflows/code-quality.yml"
  ```
- [ ] Job installs Qlty CLI and runs `qlty smells` in diff mode
- [ ] Job fails (exit 1) when new smells are detected
- [ ] Job passes (exit 0) when no new smells are detected
- [ ] Workflow YAML is valid
  ```yaml
  verify:
    method: bash
    run: "python3 -c \"import yaml; yaml.safe_load(open('.github/workflows/code-quality.yml'))\""
  ```

## Context & Decisions

- Diff mode (not `--all`) is deliberate — we only block new smells, not pre-existing ones. The existing smell count (224) would fail every PR if we used `--all`.
- PR-only because diff mode requires a comparison base. Main-branch pushes don't need this gate — they're already merged.
- The Qlty CLI install is lightweight (~10s) and idempotent.
- Existing `.qlty/qlty.toml` already configures exclude patterns, test patterns, and plugins — the CI step inherits that config automatically.
- `continue-on-error: false` (default) — this is a hard gate, not advisory.

## Relevant Files

- `.github/workflows/code-quality.yml:1-538` — target workflow (add job after `complexity-check` job at line ~475)
- `.qlty/qlty.toml` — Qlty configuration (exclude patterns, plugins)
- `.qltyignore` — additional exclusion patterns

## Dependencies

- **Blocked by:** nothing (can ship independently)
- **Blocks:** maintaining A grade once achieved
- **External:** Qlty CLI installer (`https://qlty.sh/install`)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 15m | Qlty CLI install/diff mode docs |
| Implementation | 45m | Add job, test YAML validity |
| Testing | 30m | PR test to verify gate fires |
| **Total** | **~1.5h** | |
