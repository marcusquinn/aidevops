---
description: Structured code review issue categories with examples, exceptions, and severity levels
mode: reference
---

# Code Review Categories

<!-- AI-CONTEXT-START -->

**Purpose**: Reference for code review agents. Each category has a kebab-case ID, examples, exceptions, and severity.

**Severity scale**: CRITICAL (must fix before merge) | MAJOR (should fix) | MINOR (could fix) | NITPICK (optional polish)

**Usage**: Reference via `auditing.md` or `agent-review.md`. Apply categories consistently.

<!-- AI-CONTEXT-END -->

## commit-message-mismatch

Commit message doesn't match the actual diff, or omits significant changes.

**Examples**:

- `fix: typo in README` but diff includes logic changes to a helper script
- `chore: update config` but adds a new feature flag with branching logic
- Headless worker commit references a task ID that doesn't match the PR

**Exceptions**: Minor incidental fixes alongside a larger change (if primary change is accurately described); auto-generated commits from tools like `version-manager.sh`.

**Severity**: MAJOR — misleading history makes bisect and audit unreliable

---

## instruction-file-disobeyed

Code or agent output violates an explicit rule in `AGENTS.md`, `build.txt`, or a referenced workflow doc.

**Examples**:

- Editing files on `main` without a worktree when `pre-edit-check.sh` would have blocked it
- Using `$1` directly in a shell function body instead of assigning to a local variable
- Missing `return 0`/`return 1` at the end of a shell function
- Committing a `.env` file or credentials file

**Exceptions**: Documented deviations with explicit rationale (`# SONAR:` comments); emergency hotfixes with `--skip-preflight` explicitly invoked and documented.

**Severity**: CRITICAL for security rules; MAJOR for workflow rules; MINOR for style rules

---

## user-request-artifacts

Code or comments describe past actions instead of current behavior.

**Examples**:

- `# Fixed the race condition in the polling loop` → should describe what the code does
- `# Added null check here because it was crashing` → should be `# Guard against null config — crashes on cold start`
- PR description written as a changelog rather than describing what the code now does

**Exceptions**: `CHANGELOG.md` entries; git commit messages (past-tense is conventional); `# TODO:`/`# FIXME:` markers.

**Severity**: MINOR — reduces long-term readability; MAJOR if it obscures security-relevant behavior

---

## fails-silently

Operations that can fail do so without logging, alerting, or returning a non-zero exit code.

**Examples**:

- `curl "$URL" > /tmp/output` with no `|| { print_error "Download failed"; return 1; }`
- `gh pr create ...` in a script with no exit code check
- A function that catches an error with `2>/dev/null` and continues as if it succeeded

**Exceptions**: Intentional best-effort operations explicitly documented as non-critical; `grep` exit 1 on no match (expected behavior).

**Severity**: MAJOR for operations affecting state (writes, deploys, API calls); MINOR for read-only operations

---

## documentation-implementation-mismatch

Documentation describes behavior that differs from the actual implementation.

**Examples**:

- `auditing.md` says "run `code-audit-helper.sh audit`" but the command was renamed to `run-audit`
- README shows a config key that no longer exists in the schema
- An agent doc lists a tool that was removed from the agent's frontmatter

**Exceptions**: Aspirational docs marked `TODO:` or `planned:`; version-specific docs where the version is clearly indicated.

**Severity**: MAJOR — agents and users following stale docs will fail silently or produce wrong output

---

## incomplete-integration

New code doesn't follow established patterns of the surrounding codebase.

**Examples**:

- A new helper script that doesn't use `print_info`/`print_error` when all other scripts do
- A new agent missing standard YAML frontmatter (`description`, `mode`, `tools`)
- A new workflow that bypasses `pre-edit-check.sh` when all other workflows call it

**Exceptions**: Intentional divergence from a deprecated pattern (document the reason); experimental/draft agents in `draft/`.

**Severity**: MINOR for style inconsistency; MAJOR if it breaks a contract (e.g., missing frontmatter causing agent routing to fail)

---

## repetitive-code

The same logic appears in multiple places without abstraction.

**Examples**:

- The same `curl` + `jq` API call pattern repeated across 3 helper scripts instead of a shared function
- Identical error-handling boilerplate in every function instead of a shared `handle_error` utility

**Exceptions**: Two-instance duplication where abstraction adds more complexity than it removes; intentionally self-contained scripts (e.g., one-shot installers).

**Severity**: MINOR for 2 instances; MAJOR for 3+ instances of identical logic

---

## poor-naming

Names that are ambiguous, misleading, or inconsistent with codebase conventions.

**Examples**:

- `tmp` when `temp_file_path` would be unambiguous
- A function named `process_data` that specifically validates API tokens
- Inconsistent casing: `myVar` in a codebase that uses `my_var` throughout

**Exceptions**: Loop variables (`i`, `f`, `line`) in short obvious loops; conventional names (`stdin`, `stdout`, `err`); names inherited from external APIs.

**Severity**: NITPICK for single-use locals; MINOR for function names; MAJOR for exported/public API names

---

## logic-error

Incorrect logic: wrong conditionals, inverted boolean checks, off-by-one errors, or incorrect operator usage.

**Examples**:

- `if [[ $count -lt 0 ]]` when the intent is "if no items found" (should be `-eq 0`)
- `&&` used where `||` is needed in an error-handling chain
- Comparing a string with `-eq` instead of `=`

**Exceptions**: Intentional guard conditions that look inverted but are correct (add a comment explaining the intent).

**Severity**: CRITICAL if it affects security, data integrity, or auth; MAJOR otherwise

---

## runtime-error-risk

Code likely to fail at runtime due to missing guards, unquoted variables, or environment assumptions.

**Examples**:

- `rm -rf "$DIR/"` where `$DIR` could be empty (becomes `rm -rf /`)
- Unquoted `$VARIABLE` where it could contain spaces or glob characters
- `source "$CONFIG_FILE"` without checking the file exists first

**Exceptions**: Variables guaranteed non-empty by prior validation in the same function; `set -euo pipefail` at script top (reduces but doesn't eliminate the need for guards).

**Severity**: CRITICAL for destructive operations (rm, overwrite, deploy); MAJOR for read operations

---

## security-violation

Code that exposes credentials, bypasses security controls, or introduces a vulnerability.

**Examples**:

- Hardcoded API key or password in a script or config file
- `echo "$SECRET"` in a log statement visible in CI output
- Passing a secret as a command-line argument (visible in `ps` output)
- Committing a `.env` file or `credentials.json`

**Exceptions**: Placeholder values clearly marked as examples (`YOUR_API_KEY_HERE`); `# SONAR:` annotated patterns (see `code-standards.md`).

**Severity**: CRITICAL — no exceptions for actual credential exposure

---

## missing-error-handling

Operations that can fail have no error handler, leaving the caller in an undefined state.

**Examples**:

- `git push` with no check for push failure (e.g., rejected due to non-fast-forward)
- A function calling an external API with no handler for HTTP 4xx/5xx responses
- A pipeline where a middle stage failure is masked by the final stage's exit code

**Exceptions**: `set -e` scripts where any failure aborts (if abort behavior is correct); explicitly documented best-effort operations.

**Severity**: MAJOR for operations affecting persistent state; MINOR for read-only operations

---

## abstraction-violation

Code bypasses an established abstraction layer, accessing internals directly instead of using the provided API.

**Examples**:

- Reading `~/.config/aidevops/repos.json` directly with `jq` instead of using `repos-helper.sh`
- Calling `gopass show` directly instead of `aidevops secret get`
- Parsing `gh pr list` output with `awk` instead of using `--json` + `jq`

**Exceptions**: The abstraction layer itself (must access the underlying resource); emergency debugging with `# TEMP:` documented; performance-critical paths with documented and measured overhead.

**Severity**: MINOR for read-only access; MAJOR for writes that bypass validation in the abstraction layer

---

## Severity Reference

| Level | Meaning | Merge gate |
|-------|---------|------------|
| CRITICAL | Must fix before merge — security, data loss, or auth risk | Block merge |
| MAJOR | Should fix — correctness, reliability, or maintainability impact | Request changes |
| MINOR | Could fix — readability or consistency improvement | Comment only |
| NITPICK | Optional polish — style preference with no functional impact | Inline suggestion |

## Related

- `tools/code-review/auditing.md` — audit services and workflows
- `tools/build-agent/agent-review.md` — agent review checklist
- `tools/code-review/code-standards.md` — quality rules (ShellCheck, markdownlint)
- `prompts/build.txt` — framework-wide quality rules
