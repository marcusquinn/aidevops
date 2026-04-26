<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t2893: harness gh signature-gate JS hook errors with misleading message when --body-file is created in same bash call

## Pre-flight

- [x] Memory recall: "gh shim signature footer body-file" — 2 prior lessons surfaced (mem_20260422202420_*, related to parallel `gh` calls); this is a separate class
- [x] Discovery pass: no in-flight PRs touching `quality-hooks-signature.mjs` in last 48h. Open related: #20918 (t2861, PATH shim mutates source — different bug class)
- [x] File refs verified: `.agents/plugins/opencode-aidevops/quality-hooks-signature.mjs:299-377`, `.agents/scripts/gh:198,228`, `.agents/AGENTS.md` "Signature footer hallucination (t2685)" section all checked at HEAD `dcce82c66`
- [x] Tier: `tier:standard` — JS error-message refactor + AGENTS.md doc edits, no architectural decisions, single-purpose hook function

## Origin

- **Created:** 2026-04-26
- **Session:** OpenCode interactive session (post-`#20518` triage)
- **Created by:** ai-interactive (surfaced during the worker dispatch on aidevops#20518)
- **Parent task:** none (independent harness improvement)
- **Conversation context:** A worker dispatched on aidevops#20518 (a held parent-task) prepared a body file with valid `<!-- aidevops:sig -->` marker, then ran `gh issue comment N --body-file /path/to/file` in the same bash call as the file-creation steps. The JS hook blocked with "Hook auto-repair could not parse the command — likely a heredoc, command substitution inside the body, or a --body value whose quoting this hook declined to rewrite." The actual cause (file did not yet exist at the moment the JS hook ran the readFileSync — bash hadn't executed the cp yet) was never surfaced. The worker spent ~3 tool calls debugging temp-file paths before finding the wrapper-sourcing workaround. The pattern repeats for any single-bash-call workflow that creates a body file and then immediately posts it. User asked to file as a self-improvement task.

## What

Improve the `quality-hooks-signature.mjs` JS plugin hook so its blocking error message names the **specific** failure cause (file-not-found, file-unreadable, helper-failure, quoting-conflict, heredoc, command-substitution) instead of the generic catch-all string. Add explicit guidance for the common "file created in the same bash call" failure mode. Document the same-bash-call gotcha in the framework's "Signature footer hallucination (t2685)" rules section.

After the fix, a worker who hits the gate sees: "body-file `/path/to/foo.md` does not exist (it may be created later in this same bash call — split into two bash tool calls, or source `shared-gh-wrappers.sh` and call `gh_issue_comment` by name)" — not a guess about heredoc/quoting that doesn't match the actual cause.

## Why

**Pre-execution race in the JS hook.** The `quality-hooks-signature.mjs::checkSignatureFooterGate` function at line 335 runs **before** the bash command executes. The `tryRepairSignature` path at line 299 reads the `--body-file` path with `readFileSync`. If the file is created later in the same bash command (e.g., `cp ... /tmp/foo.md && gh issue comment --body-file /tmp/foo.md`), the readFileSync throws ENOENT, `_repairBodyFile` catches it (line 235-238: `Could not repair --body-file ${filePath}: ${e.message}`) and returns null. The outer `checkSignatureFooterGate` then throws the generic "auto-repair could not parse" error, which blames heredocs / command substitution / quoting — none of which apply.

**Cost.** A worker hitting this wastes 3-5 tool calls debugging:

1. They re-check the file content (which IS valid).
2. They try renaming the temp path (no effect — same race).
3. They look at the JS hook source.
4. They eventually find the `shared-gh-wrappers.sh` sourcing pattern documented at line 8b of build.txt.

Each tool call is a context-bearing exchange. ~3-5 tool calls × ~1-3K tokens each = 5-15K tokens of pure diagnostic burn. This recurs for any worker writing the canonical "build a comment file inline, then post it" pattern in one bash call — which is the natural shape for the model when it composes a multi-paragraph comment with a heredoc redirected to a temp file.

**The current error message is anti-mentorship.** It blames three causes the worker can verify are NOT the issue (no heredoc, no command substitution in `--body`, valid quoting), without naming the actual cause (file not yet created). Per the t1901 "prompt as mentorship" core principle, error messages must transfer the knowledge needed to fix the issue.

## Tier

### Tier checklist

- [x] **2 or fewer files to modify?** 3 files (JS hook + PATH shim header + AGENTS.md). One unchecked.
- [x] **Every target file under 500 lines?** quality-hooks-signature.mjs is 377 lines, gh shim is 337 lines, AGENTS.md is large but only one section is touched.
- [ ] **Exact `oldString`/`newString` for every edit?** The JS error-string refactor is described but not provided as literal copy-paste blocks for every catch path.
- [x] **No judgment or design decisions?** Error message wording is straightforward refactor.
- [ ] **No error handling logic to design?** The structured failure-cause threading IS error-handling design.
- [x] **No cross-package or cross-module changes?** All within `.agents/`.
- [ ] **Estimate 1h or less?** ~2-3h estimated.
- [x] **4 or fewer acceptance criteria?** 5 criteria below — one over.
- [x] **Dispatch-path classification:** Files Scope does NOT reference any file in `.agents/configs/self-hosting-files.conf`. The gh shim and JS hook are not on the dispatch path. Default `#auto-dispatch`.

**Selected tier:** `tier:standard`

**Tier rationale:** 3 unchecked tier:simple boxes (file count over 2, error-handling design needed, estimate over 1h). Single-purpose hook refactor with a clear local pattern (the existing log("WARN", ...) calls in `_repairBodyFile` already capture the right info — the work is threading it up to the throw site). Sonnet-tier reasoning is sufficient.

## PR Conventions

Leaf task — not a parent-task. PR body uses `Resolves #NNN`.

## How (Approach)

### Files to Modify

- `EDIT: .agents/plugins/opencode-aidevops/quality-hooks-signature.mjs:226-238` — `_repairBodyFile`: return a structured failure object instead of null on error
- `EDIT: .agents/plugins/opencode-aidevops/quality-hooks-signature.mjs:197-214` — `_generateSignature`: same structured-failure pattern
- `EDIT: .agents/plugins/opencode-aidevops/quality-hooks-signature.mjs:299-326` — `tryRepairSignature`: thread the structured failure up
- `EDIT: .agents/plugins/opencode-aidevops/quality-hooks-signature.mjs:335-377` — `checkSignatureFooterGate`: format the throw message using the specific failure cause
- `EDIT: .agents/scripts/gh:1-50` — header comment: document the runtime-vs-pre-execution split between the JS hook (pre-exec) and the PATH shim (exec-time)
- `EDIT: .agents/AGENTS.md` — "Signature footer hallucination (t2685)" section: add a subsection on same-bash-call gotcha + the two correct workflows
- `NEW: .agents/scripts/test-quality-hooks-signature-failures.mjs` — small JS test harness that imports `tryRepairSignature` and asserts the specific failure causes for each of the 5 failure modes (file-not-found, file-unreadable, helper-missing, quoting-conflict, heredoc/cmd-sub)

### Reference Pattern

- `.agents/plugins/opencode-aidevops/quality-hooks-signature.mjs:178-186` (`_hasUnparseableBody`) — current pattern for distinguishing failure modes via separate predicates. Extend with a "reason" field instead of bool.
- `.agents/plugins/opencode-aidevops/validators.mjs` (any structured-failure pattern in there) — model on existing JS conventions in the plugin codebase.

### Implementation Steps

1. **Define a failure-reason enum at the top of the file** (around line 40, near `SIG_MARKER`):

   ```js
   export const FAIL_REASON = {
     FILE_NOT_FOUND: "body-file not found (may be created later in this bash call)",
     FILE_UNREADABLE: "body-file exists but cannot be read",
     HELPER_MISSING: "gh-signature-helper.sh not found",
     HELPER_FAILED: "gh-signature-helper.sh invocation failed",
     UNPARSEABLE_BODY: "body uses heredoc, process substitution, or command substitution",
     BODY_ARG_QUOTING: "signature contains delimiter quote, cannot safely rewrite --body",
     BODY_ARG_NO_MATCH: "could not parse --body argument shape",
   };
   ```

2. **Refactor `_repairBodyFile` to return `{ status: "ok"|"fail", reason?: string, detail?: string }`** instead of cmd|null:

   ```js
   function _repairBodyFile(cmd, filePath, helperPath, log) {
     try {
       const current = readFileSync(filePath, "utf-8");
       if (current.includes(SIG_MARKER)) return { status: "ok", cmd };
       const sig = _generateSignature(helperPath, current, log);
       if (sig === null) {
         return { status: "fail", reason: FAIL_REASON.HELPER_FAILED, detail: filePath };
       }
       appendFileSync(filePath, sig);
       log("INFO", `Auto-appended signature footer to body-file ${filePath} (t2685)`);
       return { status: "ok", cmd };
     } catch (e) {
       const reason = (e.code === "ENOENT")
         ? FAIL_REASON.FILE_NOT_FOUND
         : FAIL_REASON.FILE_UNREADABLE;
       log("WARN", `Could not repair --body-file ${filePath}: ${e.message} (${reason})`);
       return { status: "fail", reason, detail: `${filePath}: ${e.message}` };
     }
   }
   ```

3. **Refactor `_repairBodyArg` and `_matchBodyArg` similarly** — return structured failures with `BODY_ARG_QUOTING` / `BODY_ARG_NO_MATCH` reasons.

4. **Refactor `tryRepairSignature` to return the same structured shape**:

   ```js
   export function tryRepairSignature(cmd, scriptsDir, log) {
     const helperPath = join(scriptsDir, "gh-signature-helper.sh");
     if (!existsSync(helperPath)) {
       return { status: "fail", reason: FAIL_REASON.HELPER_MISSING, detail: helperPath };
     }
     if (_hasUnparseableBody(cmd)) {
       return { status: "fail", reason: FAIL_REASON.UNPARSEABLE_BODY };
     }
     const bodyFileMatch = cmd.match(/--body-file(?:=(['"]?)([^\s'"]+)\1|\s+(['"]?)([^\s'"]+)\3)/);
     if (bodyFileMatch) {
       const filePath = bodyFileMatch[2] || bodyFileMatch[4];
       return _repairBodyFile(cmd, filePath, helperPath, log);
     }
     const parsed = _matchBodyArg(cmd);
     if (!parsed) return { status: "fail", reason: FAIL_REASON.BODY_ARG_NO_MATCH };
     return _repairBodyArg(cmd, parsed, helperPath, log);
   }
   ```

5. **Update `checkSignatureFooterGate` to format the specific cause** and include same-bash-call guidance for FILE_NOT_FOUND specifically:

   ```js
   export function checkSignatureFooterGate(cmd, log, scriptsDir, output) {
     if (!isGhWriteCommand(cmd)) return;
     if (isMachineProtocolCommand(cmd)) return;
     if (hasTrustedSignatureSignal(cmd)) return;
     if (scriptsDir && output && output.args) {
       const result = tryRepairSignature(cmd, scriptsDir, log);
       if (result.status === "ok") {
         if (result.cmd !== cmd) output.args.command = result.cmd;
         return;
       }
       // Format the specific failure cause
       const snippet = cmd.length > 300 ? cmd.substring(0, 300) + "…" : cmd;
       log("ERROR", `Blocked gh write missing signature footer (t2685): ${result.reason} ${result.detail || ""} | cmd: ${snippet}`);
       const causeBlock = `Specific cause: ${result.reason}` + (result.detail ? ` (${result.detail})` : "");
       const sameCallHint = result.reason === FAIL_REASON.FILE_NOT_FOUND
         ? `\n\nLikely cause: the body-file is created in this same bash call. The JS hook runs PRE-execution, so it cannot see files that bash hasn't created yet. Two fixes:\n  a. Split into two bash tool calls: one to create the file, one to gh issue comment.\n  b. Source shared-gh-wrappers.sh and call gh_issue_comment by name (the wrapper runs in your shell after file creation).\n`
         : "";
       throw new Error(
         `aidevops: gh write command blocked at signature gate (t2685).\n\n` +
           `${causeBlock}${sameCallHint}\n\n` +
           `Standard fixes:\n` +
           `  1. Append to --body directly: gh issue comment N --body "...$(gh-signature-helper.sh footer)"\n` +
           `  2. Append to --body-file: gh-signature-helper.sh footer >> "$BODY_FILE" && gh issue comment N --body-file "$BODY_FILE"\n` +
           `  3. Source the wrapper: source shared-gh-wrappers.sh && gh_issue_comment N --body-file "$BODY_FILE"\n\n` +
           `Emergency bypass (breaks audit trail): AIDEVOPS_GH_SHIM_DISABLE=1 gh ... — but the plugin hook still blocks.`,
       );
     }
   }
   ```

6. **Add `.agents/scripts/test-quality-hooks-signature-failures.mjs`** to assert the new structured returns. One test per failure mode. Run with `node test-quality-hooks-signature-failures.mjs`. Exit non-zero on assertion failure for CI integration.

7. **Document the gotcha in AGENTS.md** under "Signature footer hallucination (t2685)". Add the subsection:

   ```markdown
   **8e. Same-bash-call gotcha (t2893)**

   The JS plugin hook runs BEFORE bash executes. If you create a body file and then post it in the SAME bash call (e.g., `cp x /tmp/foo.md && gh issue comment --body-file /tmp/foo.md`), the JS hook's `readFileSync` sees ENOENT — the file doesn't exist yet — and blocks with a `body-file not found` error.

   Two correct patterns:
   - **Two bash calls**: write the file in call 1, post it in call 2. The JS hook reads the file in call 2 and sees the marker.
   - **Sourced wrapper**: `source shared-gh-wrappers.sh && gh_issue_comment N --body-file "$BODY_FILE"`. The wrapper runs in your shell AFTER the file-creation steps complete; the JS hook trusts the wrapper-sourced calls.
   ```

8. **Update gh PATH shim header comment** to document the split (no behaviour change to the shim itself):

   ```bash
   # Runtime-vs-pre-execution split (t2893)
   # ---------------------------------------
   # Two enforcement layers cooperate:
   #   - JS plugin hook (quality-hooks-signature.mjs): runs PRE-bash-execution.
   #     Blocks calls where the body lacks a signature, can repair --body and
   #     existing --body-file, but CANNOT see files that bash will create
   #     later in the same call.
   #   - This PATH shim: runs at exec-time (after bash creates files). Repairs
   #     --body-file when the file exists at the moment gh is invoked.
   # If the JS hook blocks a call whose --body-file is created earlier in the
   # same bash command, that's the same-call race — the worker should split
   # into two bash calls or use the sourced wrapper pattern.
   ```

### Complexity Impact

- **Target function:** `_repairBodyFile` (currently 13 lines), `tryRepairSignature` (currently 28 lines), `checkSignatureFooterGate` (currently 43 lines)
- **Estimated growth:** `_repairBodyFile` +5 lines, `tryRepairSignature` +5 lines, `checkSignatureFooterGate` +20 lines
- **Projected post-change:** all three remain well under the 100-line `function-complexity` gate. Largest will be `checkSignatureFooterGate` at ~63 lines.
- **Action required:** none — buffer to 80-line warning threshold (`AIDEVOPS_COMPLEXITY_WARN_THRESHOLD`) is comfortable.

### Verification

```bash
# 1. Unit test the structured-failure paths
node .agents/scripts/test-quality-hooks-signature-failures.mjs

# 2. Repro the same-bash-call failure mode (should now report FILE_NOT_FOUND specifically)
mkdir -p /tmp/sig-test
gh issue comment 99999 --repo marcusquinn/aidevops-test --body-file /tmp/sig-test/does-not-exist.md 2>&1 | tee /tmp/sig-test/error.txt
grep -q "body-file not found" /tmp/sig-test/error.txt && echo "PASS: specific cause reported" || echo "FAIL: still generic"

# 3. Verify the wrapper-sourcing path still works (regression)
echo 'test' > /tmp/sig-test/wrapper-test.md
gh-signature-helper.sh footer >> /tmp/sig-test/wrapper-test.md
bash -c "source ~/.aidevops/agents/scripts/shared-gh-wrappers.sh && gh_issue_comment 99999 --repo marcusquinn/aidevops-test --body-file /tmp/sig-test/wrapper-test.md --dry-run 2>&1" | grep -qv "Hook auto-repair could not parse" && echo "PASS: wrapper path clean"

# 4. Verify pre-created body-file path still works (regression)
echo 'test' > /tmp/sig-test/precreated.md
gh-signature-helper.sh footer >> /tmp/sig-test/precreated.md
gh issue comment 99999 --repo marcusquinn/aidevops-test --body-file /tmp/sig-test/precreated.md --dry-run 2>&1 | grep -qv "missing signature footer" && echo "PASS: pre-created file unaffected"

# 5. Verify quality-hooks log records the structured cause
tail -5 ~/.aidevops/logs/quality-hooks.log | grep -E "Specific cause:|FAIL_REASON" && echo "PASS: structured logging"

# 6. AGENTS.md docs render correctly
markdownlint-cli2 .agents/AGENTS.md 2>&1 | grep -v "^$" | head -10
# Expect: no new MD violations from the added subsection

# Cleanup
rm -rf /tmp/sig-test
```

### Files Scope

- `.agents/plugins/opencode-aidevops/quality-hooks-signature.mjs`
- `.agents/scripts/gh`
- `.agents/AGENTS.md`
- `.agents/scripts/test-quality-hooks-signature-failures.mjs`
- `todo/tasks/t2893-brief.md`

## Acceptance Criteria

- [ ] JS hook's blocking error names the SPECIFIC failure cause (one of FILE_NOT_FOUND, FILE_UNREADABLE, HELPER_MISSING, HELPER_FAILED, UNPARSEABLE_BODY, BODY_ARG_QUOTING, BODY_ARG_NO_MATCH) instead of the generic "likely heredoc/cmd-sub/quoting" string.
- [ ] FILE_NOT_FOUND error includes targeted hint about same-bash-call race + the two correct workflows.
- [ ] AGENTS.md "Signature footer hallucination (t2685)" section gains a "Same-bash-call gotcha" subsection that documents the gotcha and lists the two correct workflows.
- [ ] gh PATH shim header comment documents the runtime-vs-pre-execution split (no behaviour change to the shim itself).
- [ ] `.agents/scripts/test-quality-hooks-signature-failures.mjs` test harness asserts each of the 7 failure-reason returns.
- [ ] Existing pre-created body-file path continues to work (regression test in Verification step 4 PASSes).
- [ ] Existing wrapper-sourcing path continues to work (regression test in Verification step 3 PASSes).

## Context & Decisions

- **Why structured returns vs sentinel strings?** A `{ status, reason, detail }` object scales as new failure modes are added. A sentinel-string contract leaks into every caller as parsing.
- **Why not auto-detect file-creation in the same bash call?** The static analysis is brittle (shell variable resolution, heredocs creating files, `mktemp` outputs assigned to vars). The error-message fix is 90% of the value at 10% of the cost. If a future task wants the static-analysis enhancement, it can be filed independently.
- **Why a doc subsection (`8e`) rather than rewriting `8`?** Existing `8` rule is well-trafficked; subsection placement preserves the existing prose while adding the new gotcha at the right adjacency.
- **Why include the gh shim header comment update?** The shim and the JS hook are sibling enforcement layers. A worker reading either should be told about the other. This is a 10-line doc change with zero runtime impact.
- **What about #20918 (t2861)?** That's about the PATH shim mutating the user's source on disk — orthogonal bug class. Both fixes can land independently.

## Relevant Files

- `.agents/plugins/opencode-aidevops/quality-hooks-signature.mjs:299-377` — primary edit target
- `.agents/scripts/gh:184-250` — secondary file (header comment update only)
- `.agents/AGENTS.md` "Signature footer hallucination (t2685)" — tertiary edit target (doc subsection)
- `.agents/scripts/shared-gh-wrappers.sh:323,810` — `_gh_wrapper_auto_sig` and `gh_issue_comment` (the wrapper-sourcing workaround that already works)
- `.agents/plugins/opencode-aidevops/quality-hooks.mjs` — sibling hook file (sourced via `from "./quality-hooks-signature.mjs"`)
- `~/.aidevops/logs/quality-hooks.log` — where structured failure logs land

## Dependencies

- **Blocked by:** none
- **Blocks:** none (improves DX for all future workers, but no other task waits on it)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Read JS source for full failure paths | 15m | confirm all current null returns map to a reason |
| Refactor structured returns | 45m | 4 functions touched, careful with backward-compat callers |
| Update throw site + error message | 30m | format the specific cause + same-call hint |
| Add test harness + 7 cases | 30m | one assert per FAIL_REASON value |
| AGENTS.md subsection + gh shim header | 15m | doc-only edits |
| Manual verification (steps 2-5) | 15m | run repro, confirm new error message |
| **Total** | **~150m (~2.5h)** | |
