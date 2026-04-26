# t2876 — gh PATH shim: privacy-scan layer to fail-closed on private-slug references in public-repo writes

## Session Origin
Interactive session, marcusquinn 2026-04-26. Surfaced after redacting 70+ historical issues/PRs in `marcusquinn/aidevops` containing the private repo basename `<webapp>` (alias for the actual private slug). Eight of those were auto-generated leaks from `pulse-canonical-recovery.sh` (fixed by t2871/PR #20945); the remaining 60+ were prose typed by maintainer/workers describing real bugs. The existing `privacy-guard-pre-push.sh` covers `git push` only — every `gh issue/pr create|comment|edit` call to the public framework repo bypasses it.

## What
Add a privacy-scan layer to `.agents/scripts/gh` (the PATH shim) that fails-closed when a write to a public repo contains a private slug reference (full slug form OR distinctive bare basename) anywhere in `--body`, `--body-file`, `--title`, or `gh api -f body=` content.

## Why
- Pre-push hook gap: only scans `git push`, not gh API calls. Private slugs leak via prose every time a session writes to a public repo.
- Source-of-truth: `privacy_enumerate_private_slugs` already exists and returns the canonical list (mirror_upstream/local_only/extras file).
- Defense-in-depth: complements t2871 (point-fix removed one auto-generator's leak path) and the existing pre-push hook (covers TODO/README/todo/.github changes on push). This closes the systemic gap.
- Cost of no fix: every interactive/headless session can leak private slugs in maintainer-typed prose. Cleanup is manual + retroactive (this session redacted 70 items).

## How

Two layers, model on the existing signature-footer enforcement which uses the same plumbing.

### Layer A — `.agents/scripts/gh` PATH shim (primary)
Already gates on `gh issue create|comment` and `gh pr create|comment` (lines 75-76) plus `gh api`. Extend to also cover `issue edit` and `pr edit`, then add a privacy scan pass after signature-footer injection.

Decision flow:
1. After existing sig-footer injection, extract target repo from `--repo` arg or `git remote get-url origin`.
2. Source `privacy-guard-helper.sh`. Call `privacy_is_target_public <slug-as-url>`. If not public (rc 1 or 2), skip.
3. Enumerate private slugs via `privacy_enumerate_private_slugs`.
4. Build a "scannable content" blob from `--body` value, `--body-file` content, and `--title` value (and `-f body=…` content for `gh api`).
5. Call new `privacy_scan_text <blob> <slugs_file>` (added in this PR). If hits → emit mentoring error, exit 1.
6. Bypass: `AIDEVOPS_GH_PRIVACY_BYPASS=1` skips the scan with stderr audit notice.
7. Fail-open: missing helper, unauthenticated gh, mktemp failure → skip scan with stderr WARN.

### Layer B — `privacy-guard-helper.sh` library function
Add `privacy_scan_text <content> <slugs_file>`:

- Iterates each slug in `slugs_file` (skip blank/comment lines).
- For each slug `<owner>/<basename>`:
  - Match form 1: full slug `<owner>/<basename>` via `grep -F` (no false positives).
  - Match form 2: bare `<basename>` only when `${#basename} -ge 6` (avoids matching common 3-5 char names like `app`, `web`, `api`, `mvp`). Uses regex `(^|[^a-zA-Z0-9_-])<basename>([^a-zA-Z0-9_-]|$)` to enforce word boundaries.
- Output: one line per hit `<slug>` (full slug form) or `<basename> (basename of <slug>)` for the bare-basename case. Exit 1 if any hits, 0 otherwise.

### Files Scope
- `.agents/scripts/privacy-guard-helper.sh` (add `privacy_scan_text` function)
- `.agents/scripts/gh` (extend case-match, add post-sig privacy scan block)
- `.agents/scripts/test-privacy-guard-shim.sh` (new — covers shim integration end-to-end)
- `.agents/scripts/test-privacy-guard.sh` (extend with `privacy_scan_text` unit tests)
- `todo/tasks/t2876-brief.md` (this brief)

### Complexity Impact
- `privacy_scan_text`: new function, ~25 lines, well under the 100-line gate.
- gh shim: adds ~40 lines of privacy-scan block — current shim is 337 lines, new total ~380 (single file).
- No existing function exceeds 80 lines after change.

## Acceptance
1. `gh issue create --repo marcusquinn/aidevops --body 'mentions <webapp>'` → exit 1, mentoring error citing the slug
2. `gh issue create --repo marcusquinn/aidevops --body 'mentions <webapp> alias'` → exit 0 (alias allowed)
3. `gh issue create --repo private/repo --body 'mentions <webapp>'` → exit 0 (private target — out of scope)
4. `AIDEVOPS_GH_PRIVACY_BYPASS=1 gh issue create … 'mentions <webapp>'` → exit 0 with stderr audit notice
5. Unit tests for `privacy_scan_text`:
   - full slug form match → returns 1
   - bare basename match (≥6 chars) → returns 1
   - bare basename ≤5 chars (e.g. `app`) → returns 0 (no false positive)
   - alias-only content → returns 0
6. Existing `test-privacy-guard.sh` still passes
7. Existing signature-footer behaviour unchanged (verified by manual smoke or existing shim tests)
8. shellcheck clean on all modified files

## Verification
```bash
# Unit tests
bash .agents/scripts/test-privacy-guard.sh
bash .agents/scripts/test-privacy-guard-shim.sh

# Lint
shellcheck .agents/scripts/gh .agents/scripts/privacy-guard-helper.sh .agents/scripts/test-privacy-guard-shim.sh

# Integration smoke test (uses fake gh via PATH shadow)
.agents/scripts/test-privacy-guard-shim.sh
```

## Notes
- The `<webapp>` alias is the user's chosen generic placeholder for the actual private repo basename. The basename appears in the user's `~/.aidevops/configs/privacy-guard-extra-slugs.txt` (single-line entry) and in `repos.json` with `mirror_upstream: true`, so `privacy_enumerate_private_slugs` already returns it.
- This task does NOT extend extra-slugs syntax to support aliases (`slug=alias`). That was the original t2872 plan; closed as superseded. If desired later, file as a separate enhancement.
- The plugin-hook layer (`Claude-aidevops/quality-hooks.mjs`) is not modified here — the PATH shim covers all gh calls regardless of agent runtime, including bash scripts and headless workers. A plugin-hook companion is a separate enhancement if richer in-IDE feedback is desired.
