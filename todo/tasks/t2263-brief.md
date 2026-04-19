<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# t2263: complexity-regression-helper.sh emits wc -l errors for new files

## Origin

- **Created:** 2026-04-18
- **Session:** Claude Code (interactive, t2249 session)
- **Observation:** Pre-push blocked with `wc -l: No such file or directory` errors on `test-oauth-*.sh` files that were net-new to PR #19790. Forced `COMPLEXITY_GUARD_DISABLE=1` bypass.

## What

`complexity-regression-helper.sh check` tries to compute line-count deltas between base and head for every changed file. For files that are additions-only (`--diff-filter=A`), the base-ref path does not exist — `wc -l` gets passed a nonexistent path and errors out.

## Why

Two costs:

1. Bypass via `COMPLEXITY_GUARD_DISABLE=1` disables the guard entirely for that push — a pure regression in coverage.
2. The failure mode is noisy and confusing: the user sees a shell error rather than a useful signal, so the signal-to-noise ratio on the pre-push gate degrades.

## How

In `.agents/scripts/complexity-regression-helper.sh`, find the loop that computes base line count per changed file. Guard with a base-existence check:

```bash
# Current (buggy) shape — illustrative:
base_lines=$(git show "$base:$path" | wc -l)

# Fixed:
if git cat-file -e "$base:$path" 2>/dev/null; then
    base_lines=$(git show "$base:$path" | wc -l)
else
    base_lines=0
fi
```

New files contribute their full line count as the delta (consistent with "new code is new debt"). Existing files compute the real delta. No error path.

## Tier

Tier:standard. Single-file edit with verbatim diff, but needs care to verify the loop's existing control flow isn't broken and that threshold comparisons still work for the new-file case.

## Acceptance

- [ ] Running `complexity-regression-helper.sh check` against a PR that adds new files emits no `wc -l: No such file or directory`.
- [ ] New-file line counts still factored into threshold comparison (not skipped entirely).
- [ ] Pre-push hook works without `COMPLEXITY_GUARD_DISABLE=1` on the t2249 test fixtures or equivalent.

## Relevant files

- `.agents/scripts/complexity-regression-helper.sh` — loop that computes per-file deltas
- `.agents/hooks/complexity-regression-pre-push.sh` — pre-push hook that wraps the helper
