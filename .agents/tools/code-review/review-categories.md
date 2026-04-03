---
description: Structured code review issue categories with examples, exceptions, and severity levels
mode: reference
---

# Code Review Categories

<!-- AI-CONTEXT-START -->

**Purpose**: Structured reference for code review agents. Each category has a kebab-case ID, description, examples, exceptions, and severity guide.

**Severity scale**: CRITICAL (must fix before merge) | MAJOR (should fix) | MINOR (could fix) | NITPICK (optional polish)

**Usage**: Reference this doc when performing reviews via `auditing.md` or `agent-review.md`. Apply categories consistently across all reviews.

<!-- AI-CONTEXT-END -->

## commit-message-mismatch

The commit message describes changes that don't match the actual diff, or omits significant changes entirely.

**Examples**:

- Commit says `fix: typo in README` but diff includes logic changes to a helper script
- Commit says `chore: update config` but adds a new feature flag with branching logic
- Headless worker commit message references a task ID that doesn't match the PR

**Exceptions**:

- Minor incidental fixes (whitespace, obvious typo) alongside a larger change — acceptable if the primary change is accurately described
- Auto-generated commits from tools (e.g., `version-manager.sh`) where the format is deterministic

**Severity**: MAJOR — misleading history makes bisect and audit unreliable

---

## instruction-file-disobeyed

Code or agent output violates an explicit rule in `AGENTS.md`, `build.txt`, or a referenced workflow doc.

**Examples**:

- Editing files on `main` without a worktree when `pre-edit-check.sh` would have blocked it
- Using `$1` directly in a shell function body instead of assigning to a local variable
- Missing `return 0`/`return 1` at the end of a shell function
- Committing a `.env` file or credentials file
- Using `Glob` as primary file discovery instead of `git ls-files`

**Exceptions**:

- Documented deviations with explicit rationale (e.g., `# SONAR:` comments for acceptable security hotspots)
- Emergency hotfixes with `--skip-preflight` explicitly invoked and documented

**Severity**: CRITICAL for security rules; MAJOR for workflow rules; MINOR for style rules

---

## user-request-artifacts

Code or comments describe past actions ("Fixed bug where...", "Added support for...") instead of describing current behavior. These are artifacts of the development process, not documentation.

**Examples**:

- `# Fixed the race condition in the polling loop` (should describe what the code does, not what was fixed)
- `# Added null check here because it was crashing` (should be `# Guard against null config — crashes on cold start`)
- PR description written as a changelog of what was done rather than what the code now does

**Exceptions**:

- `CHANGELOG.md` entries — these are intentionally past-tense
- Git commit messages — past-tense is conventional (`fix:`, `feat:`)
- Inline `# TODO:` or `# FIXME:` markers referencing known issues

**Severity**: MINOR — reduces long-term readability; MAJOR if it obscures security-relevant behavior

---

## fails-silently

Operations that can fail do so without logging, alerting, or returning a non-zero exit code. The caller has no way to detect the failure.

**Examples**:

- `curl "$URL" > /tmp/output` with no `|| { print_error "Download failed"; return 1; }`
- `jq '.key' file.json` without checking if `file.json` exists
- `gh pr create ...` in a script with no exit code check
- A function that catches an error with `2>/dev/null` and continues as if it succeeded

**Exceptions**:

- Intentional best-effort operations explicitly documented as non-critical (e.g., optional telemetry pings)
- `grep` returning exit 1 when no match found — expected behavior, not a failure

**Severity**: MAJOR for operations affecting state (writes, deploys, API calls); MINOR for read-only operations

---

## documentation-implementation-mismatch

The documentation (agent docs, README, inline comments) describes behavior that differs from the actual implementation.

**Examples**:

- `auditing.md` says "run `code-audit-helper.sh audit`" but the script's `audit` command was renamed to `run-audit`
- README shows a config key that no longer exists in the schema
- An agent doc lists a tool as available that was removed from the agent's frontmatter

**Exceptions**:

- Aspirational docs (marked `TODO:` or `planned:`) that describe future behavior
- Version-specific docs where the version is clearly indicated

**Severity**: MAJOR — agents and users following stale docs will fail silently or produce wrong output

---

## incomplete-integration

New code or a new feature doesn't follow the established patterns of the surrounding codebase, creating inconsistency that will require future cleanup.

**Examples**:

- A new helper script that doesn't use `print_info`/`print_error` from the shared library when all other scripts do
- A new agent that doesn't include the standard YAML frontmatter (`description`, `mode`, `tools`)
- A new workflow that bypasses `pre-edit-check.sh` when all other workflows call it
- Adding a new config key without updating the `.json.txt` template

**Exceptions**:

- Intentional divergence from a pattern that is itself being deprecated (document the reason)
- Experimental/draft agents in `draft/` that haven't been promoted yet

**Severity**: MINOR for style inconsistency; MAJOR if it breaks a contract (e.g., missing frontmatter that causes agent routing to fail)

---

## repetitive-code

The same logic appears in multiple places without abstraction, making future changes require multiple edits.

**Examples**:

- The same `curl` + `jq` pattern for API calls repeated across 3 helper scripts instead of a shared function
- Identical error-handling boilerplate in every function instead of a shared `handle_error` utility
- The same markdown table structure copy-pasted across multiple agent docs instead of a reference

**Exceptions**:

- Two-instance duplication where abstraction would add more complexity than it removes
- Scripts that are intentionally self-contained (e.g., one-shot installers) where shared dependencies would be a liability

**Severity**: MINOR for 2 instances; MAJOR for 3+ instances of identical logic

---

## poor-naming

Variable, function, file, or parameter names that are ambiguous, misleading, or inconsistent with the surrounding codebase conventions.

**Examples**:

- `tmp` as a variable name when `temp_file_path` would be unambiguous
- A function named `process_data` that specifically validates API tokens
- A file named `helper.sh` in a directory of specifically-named helpers (`gh-helper.sh`, `gopass-helper.sh`)
- Inconsistent casing: `myVar` in a codebase that uses `my_var` throughout

**Exceptions**:

- Loop variables (`i`, `f`, `line`) in short, obvious loops
- Conventional names (`stdin`, `stdout`, `err`) in their conventional contexts
- Names inherited from external APIs or config schemas that can't be changed

**Severity**: NITPICK for single-use locals; MINOR for function names; MAJOR for exported/public API names

---

## logic-error

The code contains incorrect logic: wrong conditionals, inverted boolean checks, off-by-one errors, or incorrect operator usage.

**Examples**:

- `if [[ $count -lt 0 ]]` when the intent is "if no items found" (should be `-eq 0`)
- `&&` used where `||` is needed in an error-handling chain
- A loop that processes `${array[@]:1}` (skipping first element) when all elements should be processed
- Comparing a string with `-eq` instead of `=`

**Exceptions**:

- Intentional guard conditions that look inverted but are correct (add a comment explaining the intent)

**Severity**: CRITICAL if it affects security, data integrity, or auth; MAJOR otherwise

---

## runtime-error-risk

Code that will likely fail at runtime due to missing guards, unquoted variables, or assumptions about environment state.

**Examples**:

- `rm -rf "$DIR/"` where `$DIR` could be empty (becomes `rm -rf /`)
- Unquoted `$VARIABLE` in a context where it could contain spaces or glob characters
- Accessing `$2` without checking that at least 2 arguments were provided
- `source "$CONFIG_FILE"` without checking that the file exists first

**Exceptions**:

- Variables that are guaranteed non-empty by prior validation in the same function
- `set -euo pipefail` at script top — reduces but doesn't eliminate the need for guards

**Severity**: CRITICAL for destructive operations (rm, overwrite, deploy); MAJOR for read operations

---

## security-violation

Code that exposes credentials, bypasses security controls, or introduces a vulnerability.

**Examples**:

- Hardcoded API key or password in a script or config file
- `echo "$SECRET"` in a log statement that will appear in CI output
- Passing a secret as a command-line argument (visible in `ps` output)
- Fetching and executing a script from an unverified URL without inspection
- Committing a `.env` file or `credentials.json`

**Exceptions**:

- Placeholder values clearly marked as examples (e.g., `YOUR_API_KEY_HERE`)
- `# SONAR:` annotated patterns that are intentional and documented (see `code-standards.md`)

**Severity**: CRITICAL — no exceptions for actual credential exposure

---

## missing-error-handling

Operations that can fail have no error handler, leaving the caller in an undefined state.

**Examples**:

- `git push` in a script with no check for push failure (e.g., rejected due to non-fast-forward)
- A function that calls an external API but has no handler for HTTP 4xx/5xx responses
- `mkdir -p "$DIR"` without checking that the directory was actually created
- A pipeline where a middle stage failure is masked by the final stage's exit code

**Exceptions**:

- `set -e` scripts where any failure will abort — acceptable if the abort behavior is correct
- Explicitly documented best-effort operations

**Severity**: MAJOR for operations that affect persistent state; MINOR for read-only operations

---

## abstraction-violation

Code bypasses an established abstraction layer, accessing internals directly instead of using the provided API.

**Examples**:

- Reading `~/.config/aidevops/repos.json` directly with `jq` instead of using `repos-helper.sh`
- Calling `gopass show` directly instead of `aidevops secret get`
- Parsing `gh pr list` output with `awk` instead of using `--json` + `jq`
- Directly editing a config file that has a helper script for safe mutation

**Exceptions**:

- The abstraction layer itself (the helper script) — it must access the underlying resource
- Emergency debugging where the helper is broken and the fix is in progress (document with `# TEMP:`)
- Performance-critical paths where the abstraction overhead is documented and measured

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
