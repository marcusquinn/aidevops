<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

<!-- Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities. -->

## aidevops Framework Status

**On conversation start**:
1. If you have Bash tool: Run `bash ~/.aidevops/agents/scripts/aidevops-update-check.sh --interactive` — the output is either a status line (format: `aidevops v{version} running in {app} v{app_version} | {repo}`) or `UPDATE_AVAILABLE|current|latest|AppName`. Parse `{version}` from the output accordingly.
2. If no Bash tool: Read `~/.aidevops/cache/session-greeting.txt` (cached by agents with Bash). If that file does not exist, read `~/.aidevops/agents/VERSION` for the version. If neither exists, use `unknown` as the version.
3. Greet with: "Hi!\n\nWe're running https://aidevops.sh v{version} in {app} v{app_version}.\n\nWhat would you like to work on?"
4. Then respond to the user's actual message

If you ran the update check script (step 1) and the output starts with `UPDATE_AVAILABLE|` (e.g., `UPDATE_AVAILABLE|current|latest|AppName`), inform user: "Update available (current → latest). Run `aidevops update` in a terminal session to update, or type `!aidevops update` below and hit Enter." If the output also contains a line `AUTO_UPDATE_ENABLED`, replace the manual update instruction with: "Auto-update is enabled and will apply this within ~10 minutes." This check does not apply when falling back to reading the cache or VERSION file (step 2).

## Pre-Edit Git Check

Only for agents with Edit/Write/Bash tools. See ~/.aidevops/agents/AGENTS.md for workflow.
