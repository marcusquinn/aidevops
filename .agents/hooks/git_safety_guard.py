#!/usr/bin/env python3
"""
Git/filesystem safety guard for Claude Code (PreToolUse hook).

Blocks destructive commands that can lose uncommitted work or delete files.
Also enforces the main-branch file allowlist: only README.md, TODO.md, and
todo/** are writable on main/master without a linked worktree (t1712).

This hook runs before Bash/Edit/Write tool calls and can deny dangerous operations.

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


# =============================================================================
# Main-Branch File Allowlist (t1712)
# =============================================================================
# Allowlisted paths that may be written on main/master without a linked worktree.
# All other file writes on main/master are blocked.
#
# Allowlist:
#   README.md   — top-level readme
#   TODO.md     — top-level task list
#   todo/       — planning directory (all files under it)
_MAIN_BRANCH_ALLOWLIST = ("README.md", "TODO.md")
_MAIN_BRANCH_ALLOWLIST_PREFIXES = ("todo/", "todo")


def _get_git_branch(cwd=None):
    """Return the current git branch name, or None if not in a git repo."""
    try:
        result = subprocess.run(
            ["git", "branch", "--show-current"],
            capture_output=True,
            text=True,
            cwd=cwd,
            timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip() or None
    except (OSError, subprocess.TimeoutExpired):
        pass
    return None


def _get_git_root(cwd=None):
    """Return the absolute path of the git repo root, or None."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            cwd=cwd,
            timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip() or None
    except (OSError, subprocess.TimeoutExpired):
        pass
    return None


def _is_linked_worktree(cwd=None):
    """Return True if the current directory is a linked worktree (not the main worktree)."""
    try:
        git_dir = subprocess.run(
            ["git", "rev-parse", "--git-dir"],
            capture_output=True,
            text=True,
            cwd=cwd,
            timeout=5,
        )
        git_common_dir = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            capture_output=True,
            text=True,
            cwd=cwd,
            timeout=5,
        )
        if git_dir.returncode == 0 and git_common_dir.returncode == 0:
            gd = git_dir.stdout.strip()
            gcd = git_common_dir.stdout.strip()
            # In a linked worktree, git-dir != git-common-dir
            # In the main worktree, git-dir == git-common-dir (or git-dir == ".git")
            return gd != gcd and gd != ".git"
    except (OSError, subprocess.TimeoutExpired):
        pass
    return False


def _normalize_file_path(file_path, repo_root=None):
    """Normalise a file path to a repo-relative path for allowlist matching."""
    if not file_path:
        return ""
    # Strip leading ./
    rel = file_path.lstrip("./") if file_path.startswith("./") else file_path
    # Strip absolute repo root prefix
    if repo_root and rel.startswith(repo_root + "/"):
        rel = rel[len(repo_root) + 1:]
    elif repo_root and rel == repo_root:
        rel = ""
    return rel


def _is_allowlisted_main_path(file_path, repo_root=None):
    """Return True if file_path is in the main-branch write allowlist.

    Allowlisted: README.md, TODO.md, todo/ (and all files under it).
    """
    rel = _normalize_file_path(file_path, repo_root)
    if rel in _MAIN_BRANCH_ALLOWLIST:
        return True
    for prefix in _MAIN_BRANCH_ALLOWLIST_PREFIXES:
        if rel == prefix or rel.startswith(prefix + "/") or rel.startswith(prefix):
            return True
    return False


def _check_main_branch_allowlist(file_path, cwd=None):
    """Block Edit/Write to non-allowlisted paths on main/master.

    Returns a denial reason string if the write should be blocked, or None to allow.
    """
    if not file_path:
        return None

    branch = _get_git_branch(cwd=cwd)
    if branch not in ("main", "master"):
        return None  # Not on a protected branch — allow

    # Linked worktrees are always allowed (they're on a feature branch by design,
    # but even if somehow on main, the worktree isolation is the primary guard)
    if _is_linked_worktree(cwd=cwd):
        return None

    repo_root = _get_git_root(cwd=cwd)
    if _is_allowlisted_main_path(file_path, repo_root=repo_root):
        return None  # Allowlisted — allow

    return (
        f"Path '{file_path}' is not in the main-branch write allowlist.\n\n"
        "Only README.md, TODO.md, and todo/** are writable on main/master "
        "without a linked worktree.\n\n"
        "Create a linked worktree for this task:\n"
        "  wt switch -c feature/<description>\n"
        "  # or: ~/.aidevops/agents/scripts/worktree-helper.sh add feature/<description>"
    )


def _deny(reason, original_input=None):
    """Return a deny JSON response."""
    context = ""
    if original_input:
        context = f"\n\nInput: {original_input}"
    output = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                f"BLOCKED by git_safety_guard.py (aidevops)\n\n"
                f"Reason: {reason}{context}\n\n"
                f"If this operation is truly needed, ask the user "
                f"for explicit permission and have them run the "
                f"command manually."
            ),
        }
    }
    return output


def main():
    """Check stdin for destructive Bash commands and block them.

    Also enforces the main-branch file allowlist for Edit/Write tool calls.
    """
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    tool_name = input_data.get("tool_name", "")
    tool_input = input_data.get("tool_input") or {}

    # Resolve cwd from tool context if available (Claude Code passes session cwd)
    cwd = input_data.get("cwd") or os.getcwd()

    # -------------------------------------------------------------------------
    # Main-branch file allowlist check (t1712)
    # Applies to Edit and Write tool calls on main/master.
    # -------------------------------------------------------------------------
    if tool_name in ("Edit", "Write"):
        file_path = tool_input.get("filePath", "")
        denial_reason = _check_main_branch_allowlist(file_path, cwd=cwd)
        if denial_reason:
            print(json.dumps(_deny(denial_reason, original_input=file_path)))
            sys.exit(0)
        # Allowlisted or not on main — fall through to allow
        sys.exit(0)

    # -------------------------------------------------------------------------
    # Destructive Bash command check
    # -------------------------------------------------------------------------
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
            print(json.dumps(_deny(reason, original_input=original_command)))
            sys.exit(0)

    # Allow all other commands
    sys.exit(0)


if __name__ == "__main__":
    main()
