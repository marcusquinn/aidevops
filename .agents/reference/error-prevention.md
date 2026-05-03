# Error Prevention

This reference preserves the institutional memory behind high-recurring model/tool
failure patterns. Keep the short universal invariants in `.agents/AGENTS.md`; use
this file for the statistics, examples, and remediation detail that justify them.

## Top Recurring Patterns

### 1. WebFetch failures

Observed failure rate: **46.8%**. Of those failures, **94% were guessed URLs**.

- Never guess or construct URLs for webfetch. Only fetch URLs from user messages,
  tool output, or files.
- GitHub content: prefer `gh api repos/{owner}/{repo}/contents/{path}` instead
  of raw `raw.githubusercontent.com` URLs.
- GitHub PRs/issues: use `gh pr view`, `gh issue view`, or `gh api`; do not use
  webfetch for GitHub issue/PR inspection.
- Library docs: use Context7 MCP instead of webfetching documentation sites.
- 404/403 means the URL was likely guessed or not accessible. Do not retry the
  same guessed URL; switch to `gh api`, Context7, or ask for a user-provided URL
  when interactive.

### 2. Markdown formatter assumptions

The markdown formatter supports these actions: `format`, `fix`, `lint`, `check`,
`advanced`, and `cleanup`. This was fixed in t1345; avoid inventing unsupported
subcommands when wiring docs or checks.

### 3. `read:file_not_found`

Observed count: **376** failures.

- Verify files exist before `Read` using tracked-file discovery (`git ls-files`) or
  untracked-file discovery (`fd`).
- Worktree paths differ from canonical repo paths; resolve paths against the
  actual repo root for the current session.
- `AGENTS.md` paths are relative to their containing repo or deployed agents
  directory; resolve them before reading.
- Verify files produced by earlier steps exist before reading them.

### 4. `edit:other`

Observed count: **14** failures.

- Confirm the replacement differs from the original text.
- Permission errors usually mean the file is protected; do not retry blindly.
- If multiple matches exist, use more context lines or an explicit replace-all
  operation when the change is intentionally global.

### 5. `glob:other`

Observed count: **24** failures.

- Never use Glob as primary discovery.
- For tracked files use `git ls-files '<pattern>'`.
- For untracked files use `fd`.
- For file lists by content/path use `rg --files -g '<pattern>'`.

### 6. Repo slug hallucination

- Always resolve repository slugs from `~/.config/aidevops/repos.json` `slug`
  fields. Never guess.
- If no configured slug exists, use `git -C <path> remote get-url origin` and
  derive the slug from the actual remote.
- `local_only: true` means there is no remote target; skip GitHub operations.
- When adding a new managed repo, add its slug to `repos.json` immediately.

## AI-Generated Issue Quality (GH#17832-GH#17835)

LLMs filing issues have hallucinated line numbers, fabricated "hot path" claims,
and applied template-driven "find O(n²)" sweeps without verification. Four such
issues were closed as invalid in one batch because all had wrong line references
and no measurements.

Before filing any performance or optimization issue:

- Verify cited line numbers match the actual code. A wrong line reference rejects
  the finding.
- Require actual measurements such as timing data, profiling output, or observed
  production metrics. "May cause O(n²)" is not evidence by itself.
- Check data scale and frequency. A loop over five items on a 60-second timer is
  not a performance problem without stronger evidence.
- Detect template-driven batch findings. If filing multiple performance issues
  with identical structure, validate each independently.
- Use the Performance Optimization issue template for performance reports; its
  mandatory measurement fields keep speculative findings out of the queue.
