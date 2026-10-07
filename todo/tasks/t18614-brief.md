## What

Add a reusable `tui-capture` subcommand to `.agents/scripts/opencode-test-helper.sh` that renders an OpenCode TUI session headlessly in a pty and writes the ANSI-stripped screen text, so TUI plugin changes (sidebar, footer, slots) can be verified without editing the user's global config.

## Why

t18612 (PR #33965) needed a throwaway Python pty script to prove the V1 TUI plugin rendered `▶ MCP (0 active)` and `1.18.35 · AIDevOps <version>`. Every future TUI plugin change (V1 `plugins/opencode-aidevops/v1-tui/tui.tsx`, V2 `plugins/opencode-aidevops/v2-plugin/tui.mjs`) needs the same evidence. The manual recipe is documented by t18613 in `.agents/tools/terminal/terminal-title.md` Troubleshooting; this task replaces the recipe with one command. Start after t18613 merges (same doc file).

## Tier

tier:standard — new small Python helper plus a shell dispatch case; resolved design below.

## How (Approach)

### Worker Quick-Start

```bash
# 1. Reference pattern: subcommand dispatch in main() of .agents/scripts/opencode-test-helper.sh:164-204
# 2. Project data dir derivation: build_project_session_id() in .agents/scripts/opencode-launcher-helper.sh:177-189
#    (project-<sql_escape_label basename>-<cksum of pwd -P>) under ${AIDEVOPS_WORK_DIR:-~/.aidevops/.agent-workspace/work}/opencode-interactive/
# 3. Gotchas: opencode --session fails with "Session not found" unless XDG_DATA_HOME is the project data dir;
#    the renderer blocks until the ESC[6n cursor-position query is answered (reply ESC[1;1R);
#    never write ~/.config/opencode/tui.json — use OPENCODE_TUI_CONFIG=<temp file> which layers over it.
```

### Files to Modify

- `NEW: .agents/scripts/opencode-tui-capture.py` — pty capture (proven prototype below)
- `EDIT: .agents/scripts/opencode-test-helper.sh:164-204` — add `tui-capture` case + help text; resolve the data dir by sourcing or mirroring `build_project_session_id` logic
- `EDIT: .agents/tools/terminal/terminal-title.md` — Troubleshooting bullet: point to `opencode-test-helper.sh tui-capture` instead of the manual recipe

### Complete Write Surface

- **Callers/readers:** none yet; `rg -n "opencode-test-helper.sh" .agents/` lists doc references to keep accurate.
- **Writers/mutation paths:** writes only the caller-supplied output file; must not write `tui.json` or the session DB.
- **Existing verification/tests:** none for opencode-test-helper.sh (`git ls-files '.agents/scripts/tests/*opencode-test*'` is empty); verify via the product path below.
- **Schemas/config:** reads optional temp `tui.json` passed by `--tui-config`; no schema change.
- **Generated/deployed mirrors:** deployed to `~/.aidevops/agents/scripts/` by `setup.sh`; no generated output.
- **Migrations/backfills:** N/A — new opt-in command, no stored state.
- **Cleanup/rollback paths:** child opencode must be SIGTERM then SIGKILL'd on timeout; rollback is reverting the PR.

### Implementation Steps

1. Create `.agents/scripts/opencode-tui-capture.py` from this verified prototype; add argparse flags `--session`, `--seconds` (default 20), `--out`, `--cwd`, `--tui-config`, `--data-dir`, `--cols/--rows` (200x50), SPDX header:

```python
import fcntl, os, pty, re, select, signal, struct, sys, termios, time
env = dict(os.environ)
if tui_config: env["OPENCODE_TUI_CONFIG"] = tui_config
if data_dir: env["XDG_DATA_HOME"] = data_dir; env["AIDEVOPS_OPENCODE_ISOLATED_DB"] = "1"
env["TERM"] = "xterm-256color"
pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd); os.execvpe("opencode", ["opencode", "--session", session_id], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
buf = b""; end = time.time() + seconds
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.25)
    if fd in r:
        try: data = os.read(fd, 65536)
        except OSError: break
        if not data: break
        buf += data
        if b"\x1b[6n" in data: os.write(fd, b"\x1b[1;1R")
os.kill(pid, signal.SIGTERM); time.sleep(1)
try: os.kill(pid, signal.SIGKILL)
except ProcessLookupError: pass
text = buf.decode("utf-8", "replace")
plain = re.sub(r"\x1b\[[0-9;?<>=]*[ -/]*[@-~]", "\n", text)
plain = re.sub(r"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", "", plain)
plain = re.sub(r"\x1b[PX^_][^\x1b]*\x1b\\", "", plain)
```

   Write `plain` to `--out`; exit non-zero if zero bytes were captured. Optional `--expect <text>` (repeatable): exit 1 listing any missing strings, so the command is a one-shot assertion.
2. In `opencode-test-helper.sh`, add `tui_capture()` (explicit `return 0/1`, `local var="$1"`) that defaults `--cwd` to `pwd -P`, derives the project data dir from it like `build_project_session_id`, and execs the Python helper; add the `tui-capture)` case and help line.
3. Update the terminal-title.md Troubleshooting bullet to reference the command.

### Hazards and Compatibility

- **Concurrency/atomicity:** opens the session read-only in a second TUI; do not send input. Running beside the live session was verified safe in t18612.
- **Migration/rollback:** N/A — additive command.
- **Mixed-version/backward compatibility:** verified on OpenCode 1.18.35; V2 (`opencode2`) binary/session flags may differ — accept `--binary` and document V2 as best effort if unverified.
- **Idempotency/retry:** repeatable; output overwritten.
- **Partial failure/recovery:** always kill the child on timeout or exception (try/finally).

### Verification Before Dispatch

```bash
~/.aidevops/agents/scripts/opencode-test-helper.sh tui-capture --session <live ses_id> --out "${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}/tui.txt" --expect "MCP" --expect "AIDevOps"
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** capture command proves pty render, data-dir derivation and `--expect`; linters prove ShellCheck/Python hygiene.
- **Broad verification trigger:** Not required.

### Scope Boundaries

**Hard boundaries:** never write `~/.config/opencode/tui.json`, `opencode.json` or session DBs.

**AI brief owner:** marcusquinn interactive session (t18612/t18613).

### Files Scope

- `.agents/scripts/opencode-tui-capture.py`
- `.agents/scripts/opencode-test-helper.sh`
- `.agents/tools/terminal/terminal-title.md`

## Acceptance Criteria

- [ ] `opencode-test-helper.sh tui-capture --session <id> --out <file>` writes readable screen text containing the sidebar `MCP` heading and footer `AIDevOps <version>` for a live aidevops-launched V1 session, without `Session not found`.
- [ ] `--expect <missing text>` exits non-zero naming the missing string; `~/.config/opencode/tui.json` is byte-identical before and after a run.
- [ ] ShellCheck clean; every new shell function has explicit returns.

## Relevant Files

- `.agents/plugins/opencode-aidevops/v1-tui/tui.tsx` — V1 TUI plugin this verifies
- `.agents/plugins/opencode-aidevops/v2-plugin/tui.mjs` — V2 TUI entrypoint
- `.agents/scripts/opencode-launcher-helper.sh:160-189` — data-dir derivation
