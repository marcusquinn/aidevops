<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2176: bash re-exec guard not firing for launchd-spawned pulse — stuck on 3.2, `${var,,}` breaks memory-pressure-monitor

## Origin

- **Created:** 2026-04-18
- **Session:** opencode:interactive
- **Created by:** marcusquinn (ai-interactive)
- **Conversation context:** Investigating why worker wasn't picking up GH#19620. The pulse.log showed `memory-pressure-monitor.sh: line 488: ${cmd_name,,}: bad substitution` every cycle. User expected us to already be running on bash 5 everywhere (per t2087/GH#18950 self-heal guard). `lsof -p <pulse-pid> txt` confirms the running pulse is `/bin/bash` (3.2.57), not the brew `/opt/homebrew/bin/bash` (5.3.9) that IS installed and available. The `shared-constants.sh` re-exec guard is supposed to catch exactly this case but isn't.

## What

The pulse supervisor process (PID varies, launched by `~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist` every 120s) must run under bash 4+ so that every framework script it invokes — including `memory-pressure-monitor.sh` which uses `${var,,}` — works without compatibility errors.

After this task:

1. The pulse process (as seen by `lsof -p <pulse-pid> txt`) runs under the modern bash binary (`/opt/homebrew/bin/bash` on macOS Apple Silicon, `/usr/local/bin/bash` on Intel, `/home/linuxbrew/.linuxbrew/bin/bash` on Linux), not `/bin/bash`.
2. `memory-pressure-monitor.sh` executes cleanly on every pulse cycle — no `bad substitution` errors.
3. The fix is robust against future launchd plists that hard-code `/bin/bash` — either the re-exec guard is strengthened to cover the indirect-source case, OR the plist `ProgramArguments` stops hard-coding the interpreter (or both).
4. A test asserts that pulse-wrapper.sh, when launched under `/bin/bash`, ends up running under modern bash by the time its body executes.

## Why

- **Direct failure.** `memory-pressure-monitor.sh` (routine `r905`, every 1 minute) exits with code 1 on line 488 (`${cmd_name,,}: bad substitution`) on every pulse cycle. The routine's job — detecting memory-pressure kill candidates — silently fails. Observed in `~/.aidevops/logs/pulse.log`:
  ```
  /Users/marcusquinn/.aidevops/agents/scripts/memory-pressure-monitor.sh: line 488: ${cmd_name,,}: bad substitution
  [pulse-wrapper] routine r905: script exited with code 1
  ```
- **Regression of an already-shipped guard.** t2087 (GH#18950) shipped `shared-constants.sh` with a runtime re-exec guard that was supposed to transparently re-launch 339 framework scripts under modern bash when invoked via `/bin/bash`. The docstring at `shared-constants.sh:20-43` explicitly states this case. For pulse-wrapper.sh it isn't working, which means any other script launched the same way (directly by launchd with hard-coded `/bin/bash`) is ALSO running on bash 3.2 and silently broken at any `${var,,}`, `${arr[-1]}`, `mapfile`, associative-array, `wait -n`, etc. construct.
- **Blast radius unknown.** Until the guard is proven working, we don't know how many other launchd/cron/direct-invoked scripts have the same problem. This task quantifies the blast radius AND fixes it.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** — likely 2 (the plist + shared-constants) but the root-cause investigation may surface more.
- [x] **Every target file under 500 lines?** — plist ~40 lines; shared-constants.sh guard block ~20 lines; test script <200 lines.
- [ ] **Exact `oldString`/`newString` for every edit?** — NO. The worker must first *diagnose* why the existing guard doesn't fire (hypotheses below, but not pre-verified). Diagnostic output drives the fix.
- [ ] **No judgment or design decisions?** — NO. The worker chooses between three plausible fixes (see Approach) based on what the diagnostic reveals.
- [x] **No error handling or fallback logic to design?**
- [x] **No cross-package or cross-module changes?**
- [x] **Estimate 1h or less?** — borderline; see estimate below.
- [x] **4 or fewer acceptance criteria?**

**Selected tier:** `tier:thinking`

**Tier rationale:** Diagnosis-required. The re-exec guard EXISTS and LOOKS correct at `shared-constants.sh:44-58`, yet observably isn't firing for pulse-wrapper.sh. The worker must reason about `BASH_SOURCE[]` stack depth when `pulse-wrapper.sh` sources `config-helper.sh` BEFORE sourcing `shared-constants.sh` (and `config-helper.sh` may or may not itself source `shared-constants.sh` indirectly). That's the kind of problem where skeleton code blocks are inadequate — a standard tier worker will apply the most obvious fix and leave the root cause in place for the next victim.

## PR Conventions

Leaf task — use `Resolves #NNN` when the GitHub issue is created.

## How (Approach)

### Worker Quick-Start

```bash
# 1. Confirm the symptom
ps -o pid,command= -p "$(pgrep -f 'pulse-wrapper.sh' | head -1)"
lsof -p "$(pgrep -f 'pulse-wrapper.sh' | head -1)" 2>/dev/null | awk '$4=="txt"{print; exit}'
# Expect: /bin/bash (3.2) — NOT /opt/homebrew/bin/bash

# 2. Confirm the guard SHOULD fire
/bin/bash -c 'source /Users/marcusquinn/.aidevops/agents/scripts/shared-constants.sh; echo "BASH_VERSINFO[0]=${BASH_VERSINFO[0]}" ; echo "AIDEVOPS_BASH_REEXECED=${AIDEVOPS_BASH_REEXECED:-UNSET}"'
# If re-exec works: BASH_VERSINFO[0]=5, AIDEVOPS_BASH_REEXECED=1
# If re-exec fails: BASH_VERSINFO[0]=3, AIDEVOPS_BASH_REEXECED=UNSET

# 3. Key files
# - shared-constants.sh:44-58 — re-exec guard
# - pulse-wrapper.sh:1, :149-151 — shebang + source order (config-helper.sh BEFORE shared-constants.sh)
# - ~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist — hard-codes /bin/bash

# 4. Brew bash is present
/opt/homebrew/bin/bash --version | head -1  # → 5.3.9
```

### Files to Modify

- `EDIT: .agents/scripts/shared-constants.sh:44-58` — possibly: walk BASH_SOURCE[] to find the outermost caller, not just BASH_SOURCE[1]. Or: set AIDEVOPS_BASH_REEXECED=1 with a loop-guard timestamp to prevent runaway self-exec.
- `EDIT: .agents/scripts/pulse-wrapper.sh:149-151` — source shared-constants.sh BEFORE config-helper.sh so the guard fires on the top-level BASH_SOURCE[1] (which is pulse-wrapper.sh itself).
- `EDIT: setup.sh OR ~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist` template — stop hard-coding `/bin/bash` in the `ProgramArguments` array; either use modern bash directly if available, or invoke the script and let the shebang resolve via `/usr/bin/env bash`.
- `NEW: .agents/scripts/tests/test-bash-reexec-guard.sh` — asserts: `/bin/bash -c 'source shared-constants.sh'` from a parent script ends up running under modern bash.

### Implementation Steps

1. **Diagnose first.** Reproduce the failure in isolation:
   ```bash
   mkdir -p /tmp/bash-reexec-test
   cat > /tmp/bash-reexec-test/parent.sh <<'EOF'
   #!/bin/bash
   echo "parent start: BASH_VERSINFO[0]=${BASH_VERSINFO[0]}, pid=$$"
   source /Users/marcusquinn/.aidevops/agents/scripts/shared-constants.sh
   echo "parent after source: BASH_VERSINFO[0]=${BASH_VERSINFO[0]}, pid=$$"
   EOF
   chmod +x /tmp/bash-reexec-test/parent.sh
   /bin/bash /tmp/bash-reexec-test/parent.sh
   ```
   Expected (if guard works): `parent start: ...=3` then `parent after source: ...=5`.

   Then reproduce with a config-helper.sh-style intermediate sourcing to test the BASH_SOURCE[] stack depth hypothesis. Capture the output — the worker's diagnosis must explicitly state whether the guard fires, and if not, which condition in `shared-constants.sh:44-46` failed.

2. **Pick the right fix based on diagnosis.** Three paths:
   - **Path A (most likely root cause): BASH_SOURCE[] stack depth.** If `pulse-wrapper.sh` sources `config-helper.sh` first, and `config-helper.sh` (directly or transitively) sources `shared-constants.sh`, then inside the guard `BASH_SOURCE[1]` is `config-helper.sh`, and the `exec` re-launches config-helper.sh as a standalone script — which doesn't do the pulse's work. Fix: walk the BASH_SOURCE stack to find the outermost caller:
     ```bash
     local _aidevops_top_caller
     _aidevops_top_caller="${BASH_SOURCE[${#BASH_SOURCE[@]}-1]:-${BASH_SOURCE[1]:-}}"
     # ... then exec with $_aidevops_top_caller instead of ${BASH_SOURCE[1]}
     ```
     Plus: ensure `pulse-wrapper.sh` sources `shared-constants.sh` BEFORE `config-helper.sh` (swap lines 149-151 — order matters so the guard fires at depth 1 where the top caller is unambiguous).

   - **Path B: launchd plist hard-codes the interpreter.** `~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist` has:
     ```xml
     <array>
         <string>/bin/bash</string>
         <string>/Users/marcusquinn/.aidevops/agents/scripts/pulse-wrapper.sh</string>
     </array>
     ```
     Even with the shebang `#!/usr/bin/env bash`, launchd bypasses it by explicitly invoking `/bin/bash`. Fix: either (a) resolve modern bash at install time in `setup.sh` and write the discovered path into the plist's `ProgramArguments`, or (b) drop the `/bin/bash` entry entirely and let the shebang resolve it, or (c) use `/usr/bin/env bash` in `ProgramArguments`. Each has trade-offs; Path B(a) is most deterministic and survives across machines that DO have brew bash.

   - **Path C: harden the guard to work even when plist hard-codes.** Keep the plist, fix only the guard. This is what the existing code attempts; if Path A explains the failure, this is covered. If something else explains it (e.g., exec failing silently due to a permissions issue), fix that too.

   The worker should apply the SMALLEST fix that resolves the symptom, with a preference for Path A+B together (the guard should work even against future plists AND current plists should stop hard-coding).

3. **Audit other launchd plists.** Run:
   ```bash
   find ~/Library/LaunchAgents /Library/LaunchAgents /Library/LaunchDaemons -name "*aidevops*.plist" -o -name "*sh.aidevops*.plist" 2>/dev/null | \
       xargs -I{} grep -l "/bin/bash" {}
   ```
   Every match is a candidate for the same hard-code bug. Update the plists OR the generator templates in `setup.sh` / `~/.aidevops/agents/scripts/aidevops-*-helper.sh` that emit them.

4. **Regression test.** Create `.agents/scripts/tests/test-bash-reexec-guard.sh` modelled on `.agents/scripts/tests/test-compute-counter-seed-octal.sh`. Test cases:
   - Direct source from a top-level script under `/bin/bash` → resulting script runs under bash 4+.
   - Indirect source (parent sources helper A, which sources `shared-constants.sh`) under `/bin/bash` → resulting top-level script runs under bash 4+.
   - Source with `AIDEVOPS_BASH_REEXECED=1` preset → no re-exec, runs under original bash (anti-loop guard intact).
   - Source with no modern bash available (hide `/opt/homebrew/bin/bash` via a PATH shim) → falls through gracefully, no infinite loop.

5. **Deploy path.** Run `~/Git/aidevops/setup.sh --non-interactive` after the fix so the deployed copies at `~/.aidevops/agents/scripts/` match source. Restart the pulse:
   ```bash
   launchctl kickstart -k gui/$(id -u)/com.aidevops.aidevops-supervisor-pulse
   ```
   Then confirm via `lsof -p $(pgrep -f pulse-wrapper.sh | head -1) txt`.

### Verification

```bash
# 1. Unit regression
bash .agents/scripts/tests/test-bash-reexec-guard.sh
# Expect: Results: 4 passed, 0 failed

# 2. Running pulse is on modern bash
PULSE_PID=$(pgrep -f "pulse-wrapper.sh" | head -1)
lsof -p "$PULSE_PID" 2>/dev/null | awk '$4=="txt"{print $NF}'
# Expect: /opt/homebrew/bin/bash (or /usr/local/bin/bash on Intel, /home/linuxbrew/.linuxbrew/bin/bash on Linux)
# NOT /bin/bash.

# 3. No "bad substitution" in pulse log after one full cycle
sleep 180 && grep "bad substitution" ~/.aidevops/logs/pulse.log | tail -5
# Expect: no new entries after the deploy timestamp.

# 4. memory-pressure-monitor.sh exits 0
bash .agents/scripts/memory-pressure-monitor.sh
echo "exit: $?"
# Expect: exit: 0

# 5. Shellcheck clean
shellcheck .agents/scripts/shared-constants.sh .agents/scripts/pulse-wrapper.sh
```

## Acceptance Criteria

- [ ] Running pulse process's `txt` binary is a bash 4+ interpreter, not `/bin/bash` 3.2.

  ```yaml
  verify:
    method: bash
    run: "lsof -p \"$(pgrep -f pulse-wrapper.sh | head -1)\" 2>/dev/null | awk '$4==\"txt\" && $NF !~ \"/bin/bash$\"{found=1} END{exit !found}'"
  ```

- [ ] `memory-pressure-monitor.sh` exits 0 when invoked under `/bin/bash` explicitly (the re-exec guard takes over inside).

  ```yaml
  verify:
    method: bash
    run: "/bin/bash .agents/scripts/memory-pressure-monitor.sh 2>&1 | grep -q 'bad substitution' && exit 1 || exit 0"
  ```

- [ ] Zero `bad substitution` lines in `~/.aidevops/logs/pulse.log` during a fresh pulse cycle after deploy.

  ```yaml
  verify:
    method: manual
    prompt: "After deploy and a full 3-minute pulse cycle, grep ~/.aidevops/logs/pulse.log for 'bad substitution' from after the deploy timestamp. Expect zero matches."
  ```

- [ ] `.agents/scripts/tests/test-bash-reexec-guard.sh` exists and passes 4/4.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-bash-reexec-guard.sh"
  ```

- [ ] `ProgramArguments` in the supervisor-pulse plist template does NOT hard-code `/bin/bash` (either uses modern bash path, `/usr/bin/env bash`, or drops the interpreter entry).

  ```yaml
  verify:
    method: codebase
    pattern: '<string>/bin/bash</string>'
    path: setup.sh
    expect: absent
  ```

## Context & Decisions

- **Why not just swap the `${var,,}` for `tr` in `memory-pressure-monitor.sh`?** That would patch the symptom for THIS script only, and the comment at line 487 (`# Use bash 4+ ${var,,} lowercasing to avoid tr subprocess forks`) is intentional — forks in a tight loop are costly. Real fix: get the runtime right.
- **Why not just edit the plist and call it done?** The plist is ONE entry point. Any future script invoked directly by another launchd agent, cron job, or automation that hard-codes `/bin/bash` hits the same bug. The re-exec guard is the defense-in-depth; it must work. Fix both.
- **Why tier:thinking?** A tier:standard worker will likely apply the most obvious fix (update the plist) and report complete, leaving the root-cause re-exec guard bug in place. When the next launchd plist ships with the same hard-code, we re-fight the same bug. Thinking tier is warranted because diagnosis is required.
- **Non-goals:** this task does NOT try to install/upgrade bash on machines that don't have brew bash — t2087/t2094 already handle that. If the fallback (`/bin/bash` 3.2 with no modern bash available) is hit, the guard legitimately falls through and the user gets the existing advisory. This task is about fixing the fires-but-doesn't-exec case, not the no-modern-bash case.

## Relevant Files

- `.agents/scripts/shared-constants.sh:15-58` — include guard + re-exec guard (the logic under test).
- `.agents/scripts/pulse-wrapper.sh:1` — shebang `#!/usr/bin/env bash`.
- `.agents/scripts/pulse-wrapper.sh:148-162` — source order (config-helper BEFORE shared-constants).
- `.agents/scripts/config-helper.sh` — possibly sources shared-constants.sh indirectly; worker must verify.
- `.agents/scripts/memory-pressure-monitor.sh:87` — sources shared-constants.sh explicitly.
- `.agents/scripts/memory-pressure-monitor.sh:487-489` — the `${var,,}` callsites that fail under bash 3.2.
- `~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist` — the plist that hard-codes `/bin/bash`.
- `setup.sh` — generator that writes the plist during install.
- `.agents/scripts/bash-upgrade-helper.sh` — the install/upgrade path for modern bash (NOT being fixed here; complementary).
- `.agents/scripts/tests/test-compute-counter-seed-octal.sh` — model for the new regression test.
- `reference/bash-compat.md` — prior art on bash compat work.

## Dependencies

- **Blocked by:** none. Everything needed is in the framework already.
- **Blocks:** reliable runtime for every helper that uses bash 4+ syntax (there are ~50 based on prior grep for `${,,}`, `${^^}`, `mapfile`, `declare -A`, etc.).
- **External:** modern bash must be installable. On macOS Apple Silicon this is `/opt/homebrew/bin/bash` (already present on dev machines); t2087's `bash-upgrade-helper.sh ensure` handles install.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Diagnosis | 30m | Reproduce in `/tmp`, confirm which guard condition fails, identify BASH_SOURCE depth or plist interaction as root cause. |
| Implementation | 45m | Fix the guard (Path A) + update the plist template (Path B) + audit other plists. |
| Testing | 30m | New regression test, local run, deploy + live pulse verification. |
| **Total** | **~1h45m** | tier:thinking justified by diagnosis requirement. |
