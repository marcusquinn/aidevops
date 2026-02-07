Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities.

## aidevops Framework Status

**On conversation start**:
1. If you have Bash tool: Run `bash ~/.aidevops/agents/scripts/aidevops-update-check.sh`
2. If no Bash tool: Read `~/.aidevops/cache/session-greeting.txt` (cached by agents with Bash)
3. Parse the first line of output (format: `aidevops v{version} running in {app} v{app_version} | {repo}`). Greet with: "Hi!\n\nWe're running https://aidevops.sh v{version} in {app} v{app_version}.\n\nWhat would you like to work on?"
4. Then respond to the user's actual message

If update check output starts with `UPDATE_AVAILABLE|` (e.g., `UPDATE_AVAILABLE|current|latest|AppName`), inform user: "Update available (current → latest). Run `aidevops update` to update."

## Pre-Edit Git Check

Only for agents with Edit/Write/Bash tools. See ~/.aidevops/agents/AGENTS.md for workflow.
