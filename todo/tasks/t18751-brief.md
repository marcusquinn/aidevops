<!-- aidevops:brief-schema=v2 -->

# tls-trust phase 3: advisory → check linkage with verified auto-dismiss

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `advisory dismiss check` → 0 hits
- [x] Discovery pass: 0 PRs touch advisory check linkage; depends on phase 1 (GH#35278)
- [x] File refs verified: 3 refs checked, all present at HEAD
- [x] Tier: `tier:standard` — small, specified change to the advisory display and `aidevops security`
- [x] Seeded draft PR decision recorded: skipped — depends on the phase-1 merge

## Origin

- **Created:** 2026-10-21
- **Session:** opencode:unknown-2026-10-21
- **Created by:** ai-interactive
- **Parent task:** t18748 (GH#35277). Blocked by: t18749 (GH#35278).

## What

1. **Optional header in `.advisory` files.** Add an optional header line `# check: <helper-subcommand> [args]`, for example `# check: tls-trust local --canary emudhra-2026-10-direct`. The first line stays the human summary, so `_check_advisories`' `head -1` display is unchanged.
2. **`aidevops security` (no-arg full assessment).** For each undismissed advisory with a `# check:` line:
   - Run `tls-trust-helper.sh <args>` through a fixed allowlist mapping. Only `tls-trust` is allowed now; never `eval` advisory text.
   - On exit 0 (no TRUSTED client), append the advisory id to `~/.aidevops/advisories/dismissed.txt` and print `auto-dismissed <id>: verified clean`.
   - On exit 2, keep the advisory and print the TRUSTED rows with their remediation hints.
3. **Session startup.** Do not run checks at startup. Network probes at session start are too slow and too noisy. Startup only displays.
4. **eMudhra advisory.** Add the `# check:` line to the advisory that GH#35271 shipped under `.agents/advisories/`.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Header parsing plus an allowlisted dispatch in two known functions → tier:standard.

## How

- Display: `.agents/scripts/aidevops-update-check.sh:373-441` (`_check_advisories`). Only the `# check:` header must stay out of the displayed text.
- Full assessment: `aidevops.sh` `_cmd_security` no-arg branch, near line 1764.
- Dismiss format: one id per line in `~/.aidevops/advisories/dismissed.txt`, matched with `grep -qxF`.

### Files Scope

- `aidevops.sh`
- `.agents/scripts/aidevops-update-check.sh`
- `.agents/advisories/emudhra-ca-compromise-2026-10.advisory`
- `.agents/tools/security/tls-trust.md`

### Verification Before Dispatch

```bash
shellcheck aidevops.sh .agents/scripts/aidevops-update-check.sh
aidevops security   # on a patched host: prints "auto-dismissed ..." for the eMudhra advisory
.agents/scripts/linters-local.sh --changed
```

## Acceptance Criteria

- [ ] An advisory with `# check: tls-trust ...` is auto-dismissed by `aidevops security` only when the check exits 0, and stays active with remediation output when it exits 2.
- [ ] Negative: advisory text is never executed directly. Only the allowlisted helper is called.

  ```yaml
  verify:
    method: codebase
    pattern: "eval .*advisory"
    path: "aidevops.sh"
    expect: absent
  ```

- [ ] Advisories without a `# check:` line behave exactly as before.
- [ ] `shellcheck` is clean, and `linters-local.sh --changed` passes.
