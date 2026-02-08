#!/usr/bin/env python3
"""
Git/filesystem safety guard for Claude Code (PreToolUse hook).

Blocks destructive commands that can lose uncommitted work or delete files.
This hook runs before Bash commands execute and can deny dangerous operations.

Installed by: aidevops setup (setup.sh) or install-hooks-helper.sh
Location: ~/.aidevops/hooks/git_safety_guard.py
Configured in: ~/.claude/settings.json (hooks.PreToolUse)

Based on: github.com/Dicklesworthstone/misc_coding_agent_tips_and_scripts
Adapted for aidevops framework (https://aidevops.sh)

Exit behavior:
  - Exit 0 with JSON {"hookSpecificOutput": {"permissionDecision": "deny", ...}} = block
  - Exit 0 with no output = allow
"""
import json
import re
import sys

# Destructive patterns to block - tuple of (regex, reason)
DESTRUCTIVE_PATTERNS = [
    # Git commands that discard uncommitted changes
    (
        r"git\s+checkout\s+--\s+",
        "git checkout -- discards uncommitted changes permanently. "
        "Use 'git stash' first.",
    ),
    (
        r"git\s+checkout\s+(?!-b\b)(?!--orphan\b)[^\s]+\s+--\s+",
        "git checkout <ref> -- <path> overwrites working tree. "
        "Use 'git stash' first.",
    ),
    (
        r"git\s+restore\s+(?!--staged\b)(?!-S\b)",
        "git restore discards uncommitted changes. "
        "Use 'git stash' or 'git diff' first.",
    ),
    (
        r"git\s+restore\s+.*(?:--worktree|-W\b)",
        "git restore --worktree/-W discards uncommitted changes permanently.",
    ),
    # Git reset variants
    (
        r"git\s+reset\s+--hard",
        "git reset --hard destroys uncommitted changes. Use 'git stash' first.",
    ),
    (
        r"git\s+reset\s+--merge",
        "git reset --merge can lose uncommitted changes.",
    ),
    # Git clean
    (
        r"git\s+clean\s+-[a-z]*f",
        "git clean -f removes untracked files permanently. "
        "Review with 'git clean -n' first.",
    ),
    # Force push operations
    # (?![-a-z]) ensures we only block bare --force, not --force-with-lease
    (
        r"git\s+push\s+.*--force(?![-a-z])",
        "Force push can destroy remote history. "
        "Use --force-with-lease if necessary.",
    ),
    (
        r"git\s+push\s+.*-f\b",
        "Force push (-f) can destroy remote history. "
        "Use --force-with-lease if necessary.",
    ),
    (
        r"git\s+branch\s+-D\b",
        "git branch -D force-deletes without merge check. Use -d for safety.",
    ),
    # Destructive filesystem commands
    # Specific root/home pattern MUST come before generic pattern
    (
        r"rm\s+-[a-zA-Z]*[rR][a-zA-Z]*f[a-zA-Z]*\s+[/~]"
        r"|rm\s+-[a-zA-Z]*f[a-zA-Z]*[rR][a-zA-Z]*\s+[/~]",
        "rm -rf on root or home paths is EXTREMELY DANGEROUS. "
        "Ask the user to run it manually if truly needed.",
    ),
    (
        r"rm\s+-[a-zA-Z]*[rR][a-zA-Z]*f"
        r"|rm\s+-[a-zA-Z]*f[a-zA-Z]*[rR]",
        "rm -rf is destructive and requires human approval. "
        "Explain what you want to delete and ask the user to run it manually.",
    ),
    # Catch rm with separate -r and -f flags (e.g., rm -r -f, rm -f -r)
    (
        r"rm\s+(-[a-zA-Z]+\s+)*-[rR]\s+(-[a-zA-Z]+\s+)*-f"
        r"|rm\s+(-[a-zA-Z]+\s+)*-f\s+(-[a-zA-Z]+\s+)*-[rR]",
        "rm with separate -r -f flags is destructive and requires human approval.",
    ),
    # Catch rm with long options (--recursive, --force)
    (
        r"rm\s+.*--recursive.*--force|rm\s+.*--force.*--recursive",
        "rm --recursive --force is destructive and requires human approval.",
    ),
    # Git stash drop/clear
    (
        r"git\s+stash\s+drop",
        "git stash drop permanently deletes stashed changes. "
        "List stashes first.",
    ),
    (
        r"git\s+stash\s+clear",
        "git stash clear permanently deletes ALL stashed changes.",
    ),
]

# Patterns that are safe even if they match above (allowlist)
SAFE_PATTERNS = [
    r"git\s+checkout\s+-b\s+",  # Creating new branch
    r"git\s+checkout\s+--orphan\s+",  # Creating orphan branch
    # Unstaging is safe, BUT NOT if --worktree/-W is also present
    r"git\s+restore\s+--staged\s+(?!.*--worktree)(?!.*-W\b)",
    r"git\s+restore\s+-S\s+(?!.*--worktree)(?!.*-W\b)",
    r"git\s+clean\s+-[a-z]*n[a-z]*",  # Dry run (-n, -fn, -nf, etc.)
    r"git\s+clean\s+--dry-run",  # Dry run (long form)
    # Allow rm -rf on temp directories (ephemeral by design)
    r"rm\s+-[a-zA-Z]*[rR][a-zA-Z]*f[a-zA-Z]*\s+/tmp/",
    r"rm\s+-[a-zA-Z]*f[a-zA-Z]*[rR][a-zA-Z]*\s+/tmp/",
    r"rm\s+-[a-zA-Z]*[rR][a-zA-Z]*f[a-zA-Z]*\s+/var/tmp/",
    r"rm\s+-[a-zA-Z]*f[a-zA-Z]*[rR][a-zA-Z]*\s+/var/tmp/",
    r"rm\s+-[a-zA-Z]*[rR][a-zA-Z]*f[a-zA-Z]*\s+\$TMPDIR/",
    r"rm\s+-[a-zA-Z]*f[a-zA-Z]*[rR][a-zA-Z]*\s+\$TMPDIR/",
    r"rm\s+-[a-zA-Z]*[rR][a-zA-Z]*f[a-zA-Z]*\s+\$\{TMPDIR",
    r"rm\s+-[a-zA-Z]*f[a-zA-Z]*[rR][a-zA-Z]*\s+\$\{TMPDIR",
    r'rm\s+-[a-zA-Z]*[rR][a-zA-Z]*f[a-zA-Z]*\s+"\$TMPDIR/',
    r'rm\s+-[a-zA-Z]*f[a-zA-Z]*[rR][a-zA-Z]*\s+"\$TMPDIR/',
    r'rm\s+-[a-zA-Z]*[rR][a-zA-Z]*f[a-zA-Z]*\s+"\$\{TMPDIR',
    r'rm\s+-[a-zA-Z]*f[a-zA-Z]*[rR][a-zA-Z]*\s+"\$\{TMPDIR',
    # Separate flags on temp directories
    r"rm\s+(-[a-zA-Z]+\s+)*-[rR]\s+(-[a-zA-Z]+\s+)*-f\s+/tmp/",
    r"rm\s+(-[a-zA-Z]+\s+)*-f\s+(-[a-zA-Z]+\s+)*-[rR]\s+/tmp/",
    r"rm\s+(-[a-zA-Z]+\s+)*-[rR]\s+(-[a-zA-Z]+\s+)*-f\s+/var/tmp/",
    r"rm\s+(-[a-zA-Z]+\s+)*-f\s+(-[a-zA-Z]+\s+)*-[rR]\s+/var/tmp/",
    r"rm\s+.*--recursive.*--force\s+/tmp/",
    r"rm\s+.*--force.*--recursive\s+/tmp/",
    r"rm\s+.*--recursive.*--force\s+/var/tmp/",
    r"rm\s+.*--force.*--recursive\s+/var/tmp/",
]


def _normalize_absolute_paths(cmd):
    """Normalize absolute paths to rm/git for consistent pattern matching.

    Converts /bin/rm, /usr/bin/rm, /usr/local/bin/rm, etc. to just 'rm'.
    Converts /usr/bin/git, /usr/local/bin/git, etc. to just 'git'.

    Only normalizes at the START of the command string to avoid
    corrupting paths that appear as arguments.
    """
    if not cmd:
        return cmd

    result = cmd
    result = re.sub(r"^/(?:\S*/)*s?bin/rm(?=\s|$)", "rm", result)
    result = re.sub(r"^/(?:\S*/)*s?bin/git(?=\s|$)", "git", result)
    return result


def main():
    """Check stdin for destructive Bash commands and block them."""
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    tool_name = input_data.get("tool_name", "")
    tool_input = input_data.get("tool_input") or {}
    command = tool_input.get("command", "")

    if tool_name != "Bash" or not isinstance(command, str) or not command:
        sys.exit(0)

    original_command = command
    command = _normalize_absolute_paths(command)

    # Check safe patterns first (allowlist)
    for pattern in SAFE_PATTERNS:
        if re.search(pattern, command):
            sys.exit(0)

    # Check destructive patterns
    for pattern, reason in DESTRUCTIVE_PATTERNS:
        if re.search(pattern, command):
            output = {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": (
                        f"BLOCKED by git_safety_guard.py (aidevops)\n\n"
                        f"Reason: {reason}\n\n"
                        f"Command: {original_command}\n\n"
                        f"If this operation is truly needed, ask the user "
                        f"for explicit permission and have them run the "
                        f"command manually."
                    ),
                }
            }
            print(json.dumps(output))
            sys.exit(0)

    # Allow all other commands
    sys.exit(0)


if __name__ == "__main__":
    main()
