<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Context-Efficient Tool Output

RTK reduces context load for noisy terminal summaries. It is an efficiency layer,
not an evidence boundary: capability, correctness, and exact output take priority
over token savings.

## Default workflow

1. **Start narrow** with `rtk-helper.sh` for supported summary commands:
   - `rtk-helper.sh git status`
   - `rtk-helper.sh git log --oneline -20`
   - `rtk-helper.sh gh pr list --repo owner/repo --limit N`
   - `rtk-helper.sh gh issue list --repo owner/repo --limit N`
2. **Assess sufficiency**: proceed only if the filtered output contains every
   fact needed for the next decision.
3. **Broaden immediately** when output is incomplete, ambiguous, expanded rather
   than reduced, or exact evidence is needed:
   - rerun the raw/direct command;
   - use a narrower raw command with explicit fields;
   - read exact files with the Read tool;
   - request logs/check output directly for terminal failures.

## Diagnostics workflow

When RTK output seems misleading, too large, too small, or insufficient for a
decision, record a comparison before changing guidance:

```bash
rtk-helper.sh --compare gh pr list --repo owner/repo --limit 10
```

The comparison reports raw vs RTK-filtered exit codes, bytes, approximate token
counts, line counts, and a first-pass recommendation. It intentionally omits the
command output to avoid copying noisy or sensitive data into diagnostics. Rerun
the raw command directly when exact evidence is needed.

Use comparison results to classify a command:

- **Good first-pass RTK candidate**: exit codes match, output shrinks, and the
  summary preserves all facts needed for the next decision.
- **Raw or narrower command preferred**: output expands, output is unchanged, or
  structured fields can answer the question more precisely.
- **Unsafe for RTK**: exit codes differ, omitted lines could alter diagnosis, or
  exact evidence/security/JSON/diff semantics are required.

## Always bypass RTK

- File reads and source inspection.
- JSON used for assertions, parsing, or automation decisions.
- Exact/verbatim diffs, patches, or blame output.
- Security scans, credential-sensitive output, or prompt-injection checks.
- Terminal failures where omitted lines could change diagnosis.
- Any command whose output must be cited byte-for-byte in an issue, PR, review,
  or audit trail.

## Validation notes

Initial validation for GH#23212 found RTK useful for list-style GitHub context
(`gh issue list`, `gh pr list`) and not useful for tiny `git status`, already
compact `git log --oneline`, or full issue bodies. Prefer RTK for discovery and
triage summaries; prefer raw output or structured fields for exact task briefs.

For future regressions, capture:

1. the exact command;
2. `rtk-helper.sh --compare ...` output;
3. whether the RTK-filtered response was sufficient, required fallback, or was
   unsafe for RTK;
4. the raw command output only when it is safe and necessary to prove the issue.
