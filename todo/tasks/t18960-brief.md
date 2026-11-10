# t18960: feat(opencode-test-helper): add mouse-click injection to tui-capture

## Origin

While verifying t18958 / PR #37647 (clickable sidebar Messages rows that open a dialog), `opencode-test-helper.sh tui-capture` could only render and assert text; it cannot interact. Verifying the click needed a throwaway driver that monkey-patched `read_render` in `opencode-tui-capture.py` to find a row and inject SGR mouse events. That pattern should be a supported, reusable option.

## What

Add a repeatable click option to `tui-capture`, e.g. `--click-text TEXT` (click the last rendered occurrence of TEXT) and optionally `--click ROW:COL`, plus optional `--keys SEQ` sent after the click, with `--expect` assertions evaluated against the post-interaction screen.

## Why

Any TUI plugin feature with mouse interaction (sidebar rows, dialogs, buttons) currently needs ad-hoc scripts to get runtime-verified evidence, which the full-loop PR evidence gate requires for critical runtime risk.

## Tier

`tier:standard` — new CLI options across a bash wrapper and a Python pty driver, with terminal-protocol details.

## How (Approach)

### Files to Modify

- EDIT: `.agents/scripts/opencode-tui-capture.py` — `read_render()` (line ~53), `capture()` (line ~89), argparse in `main()` (line ~200).
- EDIT: `.agents/scripts/opencode-test-helper.sh` — help text (line ~39-44) and `tui_capture()` option skipping (line ~203) so new value-taking flags are not misparsed.
- EDIT: `.agents/tools/opencode/opencode.md` — document the new options next to existing `tui-capture` usage.

### Reference pattern (verified working against OpenCode 1.19.5)

The throwaway driver did this; port it into the capture script rather than monkey-patching:

1. Pump the pty for ~60% of `--seconds`, answering terminal queries (`ESC[6n`, `ESC[?6n`, `ESC[c`, `ESC[?u`, `ESC[14t`, `ESC P+q`) as the existing reader does.
2. Locate the target: `raw.rfind(TARGET)`; take the last cursor-position sequence `ESC[<row>;<col>H` before it; click column = col + 3 (inside the text).
3. Send SGR mouse events: motion `ESC[<35;{col};{row}M`, sleep 0.2s, press `ESC[<0;{col};{row}M`, sleep 0.05s, release `ESC[<0;{col};{row}m`. Hover first matters; OpenTUI dialogs open on mouse-up.
4. Pump the remaining time, then (optionally) write `--keys` (unicode-escape decoded) and pump again.
5. Write plain text via the existing `plain_text()` and run `check_render()` against the final screen; insert visible `=====CLICK=====` markers in a debug/raw output only.

### Hazards

- Fail clearly (non-zero exit, message) when click target text is not rendered, rather than silently passing.
- Keep the existing no-interaction path byte-for-byte unchanged when no click flags are given.
- `--isolated-config` is required to load a worktree plugin; keep that behaviour and mention it in docs.
- Do not add new test runners; a focused case in an existing test is optional.

### Files Scope

- `.agents/scripts/opencode-tui-capture.py`
- `.agents/scripts/opencode-test-helper.sh`
- `.agents/tools/opencode/opencode.md`

## Acceptance Criteria

- `opencode-test-helper.sh tui-capture --session <id> --out <file> --isolated-config --tui-config <overlay> --click-text "<row text>" --expect "<dialog text>"` clicks the row and passes when the dialog text appears.
- Missing click target exits non-zero with a clear message.
- Existing invocations without click flags behave as before.
- ShellCheck clean; Python passes `python3 -m py_compile`.

## Verification

- Runtime: with a temp `AIDEVOPS_SESSION_BUS_DIR` containing one inbox message (format in `.agents/reference/session-bus.md`), run the command above with `--click-text` on the sidebar Messages row and `--expect "Status: not yet delivered to the model"`; it must pass (this reproduces the t18958 verification without a throwaway script).
- `shellcheck .agents/scripts/opencode-test-helper.sh`; `python3 -m py_compile .agents/scripts/opencode-tui-capture.py`.
