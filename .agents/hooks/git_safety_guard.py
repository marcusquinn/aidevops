#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
Git/filesystem safety guard for Claude Code (PreToolUse hook).

Blocks destructive commands that can lose uncommitted work or delete files.
Also enforces the main-branch file allowlist (t1712): Edit and Write tool calls
targeting non-allowlisted paths on main/master are blocked.

This hook runs before Bash/Edit/Write tool calls execute and can deny dangerous operations.

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
import os
import re
import subprocess
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


# =============================================================================
# Main-branch file allowlist (t1712)
# =============================================================================
# Paths writable on main/master without a linked worktree.
# Checked as exact match or prefix match (normalised, no leading ./).
MAIN_BRANCH_ALLOWLIST = [
    "README.md",
    "TODO.md",
    "todo/",  # prefix: todo/** subtree
]


def _get_current_branch(cwd: str) -> str:
    """Return the current git branch name, or empty string on failure."""
    try:
        result = subprocess.run(
            ["git", "branch", "--show-current"],
            capture_output=True,
            text=True,
            cwd=cwd,
            timeout=5,
        )
        return result.stdout.strip()
    except Exception:
        return ""


def _is_linked_worktree(cwd: str) -> bool:
    """Return True if cwd is inside a linked worktree (not the main worktree)."""
    try:
        git_dir = subprocess.run(
            ["git", "rev-parse", "--git-dir"],
            capture_output=True,
            text=True,
            cwd=cwd,
            timeout=5,
        ).stdout.strip()
        git_common_dir = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            capture_output=True,
            text=True,
            cwd=cwd,
            timeout=5,
        ).stdout.strip()
        # In a linked worktree, git-dir != git-common-dir
        return git_dir != git_common_dir and git_dir != ".git"
    except Exception:
        return False


def _get_repo_root(cwd: str) -> str:
    """Return the absolute path of the git repository root, or empty string on failure."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            cwd=cwd,
            timeout=5,
        )
        return result.stdout.strip()
    except Exception:
        return ""


def _is_main_allowlisted(file_path: str, repo_root: str) -> bool:
    """Return True if file_path is in the main-branch write allowlist.

    file_path may be absolute or repo-relative.
    repo_root must be an absolute path (from git rev-parse --show-toplevel).
    Rejects path traversal: any path that escapes repo_root is denied.
    """
    if not repo_root:
        return False

    # Resolve to absolute path
    if os.path.isabs(file_path):
        abs_path = os.path.normpath(file_path)
    else:
        abs_path = os.path.normpath(os.path.join(repo_root, file_path))

    # Reject traversal: path must be inside repo_root
    norm_root = os.path.normpath(repo_root)
    try:
        common = os.path.commonpath([abs_path, norm_root])
    except ValueError:
        return False  # Different drives (Windows) or other error
    if common != norm_root:
        return False  # Escapes repo root

    # Compute repo-relative path (no leading separator)
    rel_path = os.path.relpath(abs_path, norm_root)

    # Reject any remaining traversal (e.g. relpath produced "..")
    if rel_path.startswith(".."):
        return False

    for allowed in MAIN_BRANCH_ALLOWLIST:
        if allowed.endswith("/"):
            # Prefix match (subtree): rel_path == "todo" or starts with "todo/"
            prefix = allowed.rstrip("/")
            if rel_path == prefix or rel_path.startswith(allowed):
                return True
        else:
            # Exact match
            if rel_path == allowed:
                return True
    return False


def _check_main_branch_allowlist(file_path: str) -> "dict | None":
    """Check if an Edit/Write to file_path is allowed on the current branch.

    Returns a deny dict if the write should be blocked, None if allowed.
    """
    if not file_path:
        return None

    # Always use cwd for git commands — avoids failures for new (not-yet-created) files
    cwd = os.getcwd()

    # Resolve repo root from cwd (reliable even for new files)
    repo_root = _get_repo_root(cwd)
    if not repo_root:
        return None  # Not in a git repo — allow

    branch = _get_current_branch(repo_root)
    if branch not in ("main", "master"):
        return None  # Not on a protected branch — allow

    # On main/master: check if this is a linked worktree (allowed) or main worktree (restricted)
    if _is_linked_worktree(repo_root):
        return None  # Linked worktrees are always allowed

    # Main worktree on main/master: enforce allowlist
    if _is_main_allowlisted(file_path, repo_root):
        return None  # Allowlisted path — allow

    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                f"BLOCKED by git_safety_guard.py (aidevops t1712)\n\n"
                f"Reason: '{file_path}' is not in the main-branch write allowlist.\n\n"
                f"Allowlisted paths (writable on main without a worktree): "
                f"README.md, TODO.md, todo/**\n\n"
                f"All other edits must be made in a linked worktree:\n"
                f"  wt switch -c feature/your-task-name\n\n"
                f"This enforces the canonical-repo-on-main policy (t1712)."
            ),
        }
    }


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
    """Check stdin for destructive Bash commands and enforce main-branch allowlist."""
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    tool_name = input_data.get("tool_name", "")
    tool_input = input_data.get("tool_input") or {}

    # ==========================================================================
    # Edit / Write tool: enforce main-branch file allowlist (t1712)
    # ==========================================================================
    if tool_name in ("Edit", "Write"):
        file_path = tool_input.get("filePath", "")
        deny = _check_main_branch_allowlist(file_path)
        if deny:
            print(json.dumps(deny))
        sys.exit(0)

    # ==========================================================================
    # Bash tool: block destructive commands
    # ==========================================================================
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
