# GH#18830 — Root-cause investigation for silent abort inside dispatch_with_dedup

**Session origin**: interactive, follow-up to GH#18804 / v3.8.22
**What**: Bisect the silent-abort site inside `dispatch_with_dedup` (currently contained by a subshell wrapper in `_dff_process_candidate`) and fix at root cause.
**Why**: PR #18826 is containment, not elimination. The 28/29 candidates in the current pulse log all return `rc=1` from `dispatch_with_dedup` with no gate reason logged — the subshell isolation is silencing the real failure. We want observable "this gate blocked you" lines, and ultimately no silent abort at all.
**How**:
1. Add unconditional `[dwd-fence][#N]` log lines at entry/exit of `dispatch_with_dedup`, at every gate in `_dispatch_dedup_check_layers`, and at every layer in `check_dispatch_dedup`. Single-line `echo >>"$LOGFILE"` calls — no helper, no conditionals.
2. Deploy (setup.sh --non-interactive) and trigger a pulse cycle (`launchctl kickstart -k gui/$(id -u)/com.aidevops.aidevops-supervisor-pulse`).
3. Wait for the fill-floor stage, then grep `~/.aidevops/logs/pulse.log` for `dwd-fence.*#<any-blocked-issue>` — the LAST fence line before the silent abort names the function containing the bug.
4. Audit that function for unsafe patterns: `exit N` (vs `return`), `local var=$(cmd)` without rc capture, SIGPIPE-prone `read` from pipes, process substitution edge cases.
5. Fix the root cause. Remove the containment subshell in `_dff_process_candidate`. Keep the fence-post logs as permanent observability.
6. Verify in pulse log: the legitimate skip reasons are now logged for each blocked candidate, AND at least one of the "should-be-dispatchable" candidates (#18776, #18832, #18847, #18796, #18797) actually dispatches a worker.

**Acceptance criteria**:
- Fence-post logs pinpoint the silent-exit function
- Root cause fixed (file:line:pattern documented in PR body)
- Containment subshell removed from `_dff_process_candidate`
- Pulse log shows explicit gate reasons for every blocked candidate
- At least one currently-blocked candidate (without a legitimate reason) dispatches successfully
- Memory entry stored with the root-cause pattern

**Context**:
- Target files: `.agents/scripts/pulse-dispatch-core.sh` (dispatch_with_dedup @2006, _dispatch_dedup_check_layers @1465, check_dispatch_dedup @439), `.agents/scripts/pulse-dispatch-engine.sh` (_dff_process_candidate @391)
- Related: GH#18804 (containment PR #18826), GH#18770/#18784/#18786 (set-e propagation bugs), memory entry `mem_20260414044408_4834ab5c`
- Operational impact: contained today — pulse dispatches normally but dispatch=0 implementation workers for ~28 candidates each cycle. No user-visible breakage, only wasted reconciliation.
