---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2206: Add markdownlint-cli2 and biome CI jobs to code-quality.yml

## Origin

- **Created:** 2026-04-18
- **Session:** OpenCode interactive (marcusquinn)
- **Created by:** marcusquinn (human-directed AI-interactive)
- **Parent task:** t2191 (follow-up)
- **Conversation context:** While diagnosing a Codacy grade drop (E → B), we discovered 132 markdownlint and 156 biome findings had accumulated because neither tool gates at CI. Codacy was the only place they surfaced. t2191 added `biome.json` (suppressing 18 Qwik FPs) and a local pre-commit hook; this task wires both tools into CI so findings gate at PR time, not after-the-fact.

## What

Two new jobs in `.github/workflows/code-quality.yml`:

1. **markdownlint-cli2 job** — runs on every PR touching `*.md`, fails on violations in changed files.
2. **biome ci job** — runs `biome ci .` against the tree, fails on Errors, advisory on Warnings (while we work through the 156-finding backlog).

## Why

- Codacy catches these, but only after merge and full re-index. By then the debt is committed.
- markdownlint / biome at CI = immediate feedback to the PR author, no "Codacy surprise" three hours after merge.
- 132 markdownlint findings + 156 biome findings currently sit in the repo unchecked. Gating new additions is the first step; ratcheting down the backlog is a separate concern (not this task).

## Tier

### Tier checklist (verify before assigning)

- [x] 2 or fewer files to modify? — **Yes** (`.github/workflows/code-quality.yml`)
- [x] Every target file under 500 lines? — **Yes** (workflow file is ~300 lines)
- [ ] Exact `oldString`/`newString` for every edit? — **No** (YAML insertion point depends on existing file structure)
- [x] No judgment or design decisions? — **Yes** (pattern exists in file)
- [x] No error handling or fallback logic to design? — **Yes**
- [x] No cross-package or cross-module changes? — **Yes**
- [x] Estimate 1h or less? — **Yes**
- [x] 4 or fewer acceptance criteria? — **Yes**

**Selected tier:** `tier:standard`

**Tier rationale:** Single-file YAML edit with an existing in-file pattern to model on. One "no" in the checklist (oldString/newString blocks — worker needs to read the file first to pick insertion point), so standard not simple.

## PR Conventions

Leaf (non-parent) issue. Use `Resolves #19692` in the PR body.

## How (Approach)

### Files to Modify

- `EDIT: .github/workflows/code-quality.yml` — add two new jobs. Model on an existing Node-based job in the same file (e.g. Bash 3.2 Compatibility pattern uses `actions/setup-node` + `npx`).

### Implementation Steps

1. **Read the existing workflow** to find the job structure and the trigger/paths pattern used.
2. **Add markdownlint job** — runs only when PRs touch `*.md`:

   ```yaml
   markdownlint:
     name: Markdown Lint
     runs-on: ubuntu-latest
     if: github.event_name == 'pull_request'
     steps:
       - uses: actions/checkout@v4
         with:
           fetch-depth: 0
       - uses: actions/setup-node@v4
         with:
           node-version: '20'
       - name: Get changed markdown files
         id: changed
         run: |
           base="${{ github.event.pull_request.base.sha }}"
           head="${{ github.event.pull_request.head.sha }}"
           files=$(git diff --name-only --diff-filter=ACM "$base" "$head" -- '*.md' | tr '\n' ' ')
           echo "files=$files" >> "$GITHUB_OUTPUT"
       - name: Run markdownlint-cli2
         if: steps.changed.outputs.files != ''
         run: npx --yes markdownlint-cli2 ${{ steps.changed.outputs.files }}
   ```

3. **Add biome job** — runs on every PR (JS/TS changes or config changes may affect ruleset):

   ```yaml
   biome:
     name: Biome CI
     runs-on: ubuntu-latest
     if: github.event_name == 'pull_request'
     steps:
       - uses: actions/checkout@v4
       - uses: actions/setup-node@v4
         with:
           node-version: '20'
       - name: Run biome ci
         run: npx --yes @biomejs/biome ci .
   ```

4. **Pin versions** — don't rely on `latest`. Pick the current major of markdownlint-cli2 (0.x) and biome (2.x) and pin to specific patch versions to avoid surprise breakage. Reference: `biome.json` pins `https://biomejs.dev/schemas/2.4.12/schema.json` — use `@biomejs/biome@2.4.12` for consistency.
5. **Verify both jobs pass** on a no-op PR before merging this one. Opening a draft PR with a trivial markdown fix + a trivial JS fix and confirming both gates fire is sufficient.

### Verification

```bash
# Reproduce locally before pushing:
npx --yes markdownlint-cli2 README.md
npx --yes @biomejs/biome@2.4.12 ci .

# After PR opens, confirm the two new check names appear:
gh pr checks <PR> --repo marcusquinn/aidevops | grep -E "Markdown Lint|Biome CI"
```

## Acceptance Criteria

- [ ] `Markdown Lint` job present in `code-quality.yml`, gated on PR events, only runs when markdown files changed.
- [ ] `Biome CI` job present in `code-quality.yml`, gated on PR events, runs `npx @biomejs/biome@2.4.12 ci .`.
- [ ] Both jobs pass on a clean PR; both fail when a PR introduces a deliberate violation.
- [ ] Tool versions pinned to specific patch releases (no `@latest`).

## Context & Decisions

- **Why pin versions:** the framework has a history of CI breakage from tool updates (CodeRabbit placeholder edits, SonarCloud API deprecations). Pinning makes CI failures reproducible and upgrade-explicit.
- **Why not ratchet-down the existing 288 findings in this PR:** ratchet work is incremental and context-heavy. Gating new additions first means the backlog stops growing; a separate task can grind through the existing findings.
- **Why biome `ci` not `check --error-on-warnings`:** `ci` is Biome's CI-optimised mode — no color, no interactive output, single-pass. Same fail-on-error semantics.
- **Relation to `qlty` jobs already in `code-quality.yml`:** qlty covers shell/Python/generic smells; biome covers JS/TS; markdownlint covers Markdown. No overlap.

## Relevant Files

- `.github/workflows/code-quality.yml` — target file.
- `biome.json` — config added in t2191 (disables `useQwikValidLexicalScope`).
- `.markdownlint-cli2.jsonc` or `.markdownlint.json` — may or may not exist; if not, create minimal config to match Codacy's effective ruleset.

## Dependencies

- **Blocked by:** none.
- **Blocks:** ratchet-down task for existing 288 findings (follow-up to this).
- **External:** none.
