# t2736: trim OpenCode first-response greeting to concise one-line

## Session Origin

Interactive follow-up to t2724/t2728/t2730/t2731. User asked: stop the model from running `aidevops-update-check.sh` and dumping the output into chat at session start. The plugin already renders the full framework status as a TUI toast — the chat greeting should be a one-liner.

## What

Rewrite the OpenCode-runtime `AGENTS.md` heredoc inside the canonical runtime-config generator so that OpenCode sessions produce the exact greeting:

```text
Hi!

We're running aidevops v{X} in OpenCode v{Y}.

What would you like to work on?
```

No bash tool call at session start. No toast-content duplication in chat.

## Why

Current live `~/.config/opencode/AGENTS.md:1-12` instructs the model to `Run bash ~/.aidevops/agents/scripts/aidevops-update-check.sh --interactive`, then implicitly dumps the 8+ line output (security advisories, contribution counts, update hints, etc.) into the chat. This is redundant with the toast the `opencode-aidevops` plugin renders at `session-start` and wastes user attention plus tokens on every session start.

t2730 targeted the deprecated `generate-opencode-agents.sh` fallback, not the canonical generator — so the fix never landed in live output. This PR targets the correct file.

## How

### Files to modify

- EDIT: `.agents/scripts/generate-runtime-config.sh:132-147` — replace the `AGENTSEOF` heredoc body inside `_generate_agents_opencode()`.

### Reference pattern

- The cache file `~/.aidevops/cache/session-greeting.txt` line 1 is always `aidevops v{X} running in OpenCode v{Y} | {repo}/{branch}` — populated by the opencode-aidevops plugin at session start. Line 1 is the cheapest source for both versions in a single `Read` call.
- The plugin's `greeting.mjs` already renders the full framework status (versions, runtime, security posture, advisories, update hints) as a TUI toast — see t2731 / PR #20447 for the un-filtered variant.
- Fallback: `~/.aidevops/agents/VERSION` holds just the aidevops version if the cache is missing.

### Proposed heredoc replacement

```markdown
Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities.

**Runtime**: You are running in OpenCode. Global config: `~/.config/opencode/opencode.json`.

## aidevops Framework Status

The opencode-aidevops plugin renders session-start framework status (versions,
security posture, advisories, update hints) as a TUI toast before your first
turn. Raw output is cached at `~/.aidevops/cache/session-greeting.txt`. The
user has already seen it — do NOT re-run `aidevops-update-check.sh` and do
NOT repeat toast content in the chat.

**On interactive conversation start** (skip for headless sessions like `/pulse`, `/full-loop`):

1. Read line 1 of `~/.aidevops/cache/session-greeting.txt`. Format: `aidevops v{X} running in OpenCode v{Y} | ...`. Extract `{X}` and `{Y}`.
2. Greet with exactly:

       Hi!

       We're running aidevops v{X} in OpenCode v{Y}.

       What would you like to work on?

3. If the cache file is missing, read `~/.aidevops/agents/VERSION` for `{X}` and greet: "Hi!\n\nWe're running aidevops v{X}.\n\nWhat would you like to work on?"
4. Then respond to the user's actual message.

If the user asks about aidevops updates, direct them to run `aidevops update` in a terminal session (or `!aidevops update` in chat). Do not announce updates unprompted — the toast already did.

## Pre-Edit Git Check

Only for agents with Edit/Write/Bash tools. See ~/.aidevops/agents/AGENTS.md for workflow.
```

### Verification

1. Edit the heredoc in `generate-runtime-config.sh`.
2. Run `~/.aidevops/agents/scripts/generate-runtime-config.sh agents --runtime opencode` to regenerate.
3. `diff` the resulting `~/.config/opencode/AGENTS.md` against the proposed content.
4. Manual user verification: start a new OpenCode session, confirm greeting is exactly the one-liner and no bash tool call fires.

### Files Scope

- `.agents/scripts/generate-runtime-config.sh`
- `todo/tasks/t2736-brief.md`

## Acceptance Criteria

- [ ] `.agents/scripts/generate-runtime-config.sh` heredoc produces the concise greeting template
- [ ] Regenerated `~/.config/opencode/AGENTS.md` contains: (a) runtime-identity line, (b) explicit "do NOT re-run aidevops-update-check.sh" directive, (c) concise greeting template with `{X}` and `{Y}` placeholders sourced from cache file line 1
- [ ] Regenerated file does NOT contain the string `Run bash ~/.aidevops/agents/scripts/aidevops-update-check.sh`
- [ ] Manual next-session check: the model greets with exactly the one-line format and makes no bash tool call at session start

## Tier

`tier:standard` — single-file heredoc replacement with narrative verification. Sonnet-class.

## Context

- Parent arc: t2724 → t2725 → t2727 → t2728 → t2730 (deprecated-script edit, ineffective) → t2731 (toast fix) → **t2736 (this)**.
- Canonical generator identified: `.agents/scripts/generate-runtime-config.sh`. The deprecated `generate-opencode-agents.sh` (line 5: `# DEPRECATED: Use generate-runtime-config.sh instead (t1665.4)`) is the fallback-only path my earlier t2730 edit targeted.
- Related memory: `mem_20260422051733_5ab9dcc8` — AGENTS.md is model-visible, toast is user-visible; don't confuse them.
