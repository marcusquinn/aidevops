## What

Make the positional-parameter ratchet in `.agents/scripts/pre-commit-hook.sh`
(`validate_positional_parameters`, the `_awk_script` near line 264) ignore `$N`
inside single-quoted strings that span several lines, such as multi-line
`awk '...'` programs. Today it strips single-quoted segments one line at a time
(`gsub(/\047[^\047]*\047/, "", line)`), so `$1`/`$2` awk field references on
the inner lines of a multi-line awk program count as shell positional
parameters.

## Why (evidence, 2026-11-25)

- t19368 / GH#40332 added a multi-line awk program to
  `.agents/scripts/sandbox-exec-helper.sh` (`_sandbox_descendant_rows`). The
  commit was blocked with `NEW direct positional parameter usage ... (new: 3)`
  for inner awk lines such as `$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {` and
  `kids[$2] = kids[$2] " " n`. None of these is a shell expansion.
- The workaround was renaming the fields through `awk -v pid_col=1 -v ppid_col=2`
  and `$pid_col`. That is fine once, but every multi-line awk, sed or jq program
  in a shell helper hits the same false block. Authors are pushed toward
  workarounds or `--no-verify`, which skips every other validator.
- The same per-line stripping likely shapes the pre-existing counts. For
  example, `sandbox-exec-helper.sh` reports 10 pre-existing usages, so the
  ratchet baselines are inflated by awk bodies.

## How

File: `.agents/scripts/pre-commit-hook.sh`, `validate_positional_parameters`
`_awk_script`. The same script runs over staged and HEAD content, so both counts
change consistently and the ratchet stays fair.

1. Carry a single-quote state across lines (`in_sq`). While `in_sq`, drop
   everything up to the next `'`. Outside it, strip complete `'...'` segments as
   today. An unmatched opening `'` sets `in_sq` and drops the rest of the line.
2. Do not let apostrophes outside shell single-quoting open a multi-line quote.
   This is the design risk, because swallowing lines would hide real violations
   (false negatives):
   - Pure comment lines (`^[[:space:]]*#`) must be skipped *before* quote
     tracking when not `in_sq` (for example `# don't`).
   - `'` inside double quotes is literal (for example `"it's $1"` must still
     flag `$1`).
   - Heredoc bodies may hold apostrophes. Either skip quote tracking between
     `<<WORD`/`<<'WORD'`/`<<-WORD` and the terminator, or treat the body as
     plain text for `$N` detection; quoted-delimiter heredocs do not expand
     `$N`.
   - `\'` outside quotes is a literal quote.
   - Keep the `'"'"'` idiom working (close, literal, reopen).
3. Fail safe: if quote state is still open at end of file, do not suppress the
   lines after the opening quote. Re-scan them with the old per-line logic so a
   parsing miss cannot hide a violation.

Reference pattern: the existing ratchet scenarios in
`.agents/scripts/tests/test-pre-commit-ratchet.sh`
(`test_positional_params_preexisting_pass`,
`test_positional_params_new_usage_blocks`).

### Files Scope

- `.agents/scripts/pre-commit-hook.sh`
- `.agents/scripts/tests/test-pre-commit-ratchet.sh`

## Acceptance

- A staged multi-line `awk '...$1...$2...'` program adds 0 to the positional
  count.
- Bare `$1` in shell code after a comment containing an apostrophe still counts.
- `"... $1 ..."` with an apostrophe inside double quotes still counts.
- A heredoc body containing an apostrophe does not suppress later shell lines.
- An unterminated quote does not suppress later lines (fail safe).
- `bash .agents/scripts/tests/test-pre-commit-ratchet.sh` passes, with new
  scenarios for the cases above (the repository already has this ratchet test
  file; add scenarios there).
- `shellcheck .agents/scripts/pre-commit-hook.sh` clean.

## Verification

```bash
shellcheck .agents/scripts/pre-commit-hook.sh
bash .agents/scripts/tests/test-pre-commit-ratchet.sh
```

Spot check: for every `.agents/scripts/*.sh`, compare old and new positional
counts. Each change must be a decrease attributable to multi-line single-quoted
programs. List any increase in the PR and explain it.
