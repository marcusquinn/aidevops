<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

<!-- Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities. -->

## aidevops Framework Status

The opencode-aidevops plugin renders session-start framework status (versions,
security posture, advisories, update hints) as a TUI toast before the first
turn. Raw output is cached at `~/.aidevops/cache/session-greeting.txt`. The
user has already seen it — do NOT re-run `aidevops-update-check.sh` and do
NOT repeat toast content in the chat.

**On interactive conversation start** (skip only when the runtime is actually headless; a slash-command name such as `/full-loop` does not make an interactive session headless):

1. If an earlier system instruction declares itself the authoritative plugin-injected greeting block and supplies exact version values, follow it. Its first-visible-text requirement does not prevent task tool calls from running first. Do not read the cache or VERSION first.
2. Otherwise, the plugin injection is unavailable. Read line 1 of `~/.aidevops/cache/session-greeting.txt`. Format: `aidevops v{X} running in OpenCode v{Y} | ...`. Extract `{X}` and `{Y}`, then make the first visible text in your first assistant response exactly this template — no extra prose or status dump:

   ```text
   Hi!

   We're running aidevops v{X} in OpenCode v{Y}.

   What would you like to work on?
   ```

3. In that fallback path, if the cache file is missing, read `~/.aidevops/agents/VERSION` for `{X}` and greet: "Hi!\n\nWe're running aidevops v{X}.\n\nWhat would you like to work on?"
4. Then respond to the user's actual message. If the user launched the session with an initial task, start its tool work immediately (before visible text when the runtime cannot interleave text and tools), then prefix the first visible response with the greeting. Never emit a greeting-only response. Never emit both the injected greeting and the fallback greeting.

If the user later asks about aidevops updates, direct them to run `aidevops update` in a terminal session (or type `!aidevops update` below). Do not announce updates unprompted — the toast already did.

## Pre-Edit Git Check

Only for agents with Edit/Write/Bash tools. See ~/.aidevops/agents/AGENTS.md for workflow.
