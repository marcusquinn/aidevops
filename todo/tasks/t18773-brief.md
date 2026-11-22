## What

`check_python_complexity` in `.agents/scripts/linters-local-analysis.sh` reports a false pass when `lizard` or `pyflakes` is on `PATH` but cannot run.

Both checks use `command -v <tool>` and then `out=$(<tool> ... 2>/dev/null || true)`. A tool whose shebang points at a removed interpreter (observed: pip entry points left in `/opt/homebrew/bin` with `#!/opt/homebrew/opt/python@3.11/bin/python3.11` after Homebrew dropped python@3.11) exits 126 with only stderr ("bad interpreter"). Stdout is empty, so the check prints `Python complexity: N files checked, no issues` instead of saying the tool is unavailable.

## Fix

Distinguish "ran and found nothing" from "could not run":

- Capture each tool's exit status instead of `|| true`. pyflakes exits 0 (clean) or 1 (findings); lizard with `--warnings_only` exits 0 or 1 when warnings exist. Any other status, or a status that is non-zero with empty stdout, means the tool did not run.
- When a tool did not run, print a warning naming the resolved path and the reinstall hint (`pipx install <tool>`) and do not claim "no issues" in the summary line; name the skipped tool instead.
- Keep the check advisory (`return 0`), as today.

### Files Scope

- `.agents/scripts/linters-local-analysis.sh`

## Files to modify

- `.agents/scripts/linters-local-analysis.sh:868-938` (`check_python_complexity`). Shared helper or inline status capture; follow the existing `print_warning`/`print_info` style.

## Verification

- `shellcheck .agents/scripts/linters-local-analysis.sh` clean.
- Reproduce with a temporary `PATH` directory containing `pyflakes` and `lizard` scripts whose shebang is a missing interpreter: before the fix the summary says "no issues"; after, it warns that each tool is not runnable and the summary names the skipped tools.
- With working tools (`pipx install pyflakes lizard`), output is unchanged for clean files and still counts findings for a file with an unused import.
- `.agents/scripts/linters-local.sh --changed --base-ref origin/main` passes.
