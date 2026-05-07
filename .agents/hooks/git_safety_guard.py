#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
Git/filesystem safety guard for Claude Code (PreToolUse hook).

Blocks destructive commands that can lose uncommitted work or delete files.
Also enforces the canonical-workspace protection rule (t1712/t1990):
  - Edit/Write on the default branch: only allowlisted paths permitted
    (README.md, TODO.md, todo/**) without a linked worktree.
  - Edit/Write on any non-default branch in the canonical workspace: always
    denied unless inside a linked worktree. Default branch is auto-detected
    from origin/HEAD (with fallbacks to init.defaultBranch then "main") so
    repos using develop/trunk/etc. are covered equally.

This hook runs before Bash/Edit/Write tool calls execute and can deny dangerous operations.
It is registered under BOTH the 'Bash' AND 'Edit|Write' PreToolUse matchers so that
the Edit/Write protection branch is reachable (see GH#21814).

Installed by: aidevops setup (setup.sh) or install-hooks-helper.sh
Location: ~/.aidevops/hooks/git_safety_guard.py
Configured in: ~/.claude/settings.json (hooks.PreToolUse)

Based on: github.com/Dicklesworthstone/misc_coding_agent_tips_and_scripts
Adapted for aidevops framework (https://aidevops.sh)

Exit behavior:
  - Exit 0 with JSON {"hookSpecificOutput": {"permissionDecision": "deny", ...}} = block
  - Exit 0 with no output = allow

Environment overrides:
  AIDEVOPS_SKIP_CANONICAL_GUARD=1  — bypass the off-default-branch canonical guard
                                     (use sparingly; document reason at call site)
"""
import json
import os
import re
import shlex
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
    # Branch creation is only safe inside linked worktrees. The canonical
    # workspace branch-switch guard runs before this allowlist and denies these
    # commands there; linked worktrees skip that guard and keep these safe.
    r"git\s+checkout\s+-b\s+",  # Creating new branch in linked worktree
    r"git\s+checkout\s+--orphan\s+",  # Creating orphan branch in linked worktree
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
    # Validation: invalid inputs
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
        is_valid = common == norm_root
    except ValueError:
        # Different drives (Windows) or other error
        is_valid = False
    
    if not is_valid:
        return False

    # Compute repo-relative path and validate no traversal
    rel_path = os.path.relpath(abs_path, norm_root)
    if rel_path.startswith(".."):
        return False  # Contains traversal

    # Check against allowlist
    for allowed in MAIN_BRANCH_ALLOWLIST:
        if allowed.endswith("/"):
            # Prefix match (subtree): rel_path == "todo" or starts with "todo/"
            prefix = allowed.rstrip("/")
            if rel_path == prefix or rel_path.startswith(allowed):
                break
        elif rel_path == allowed:
            # Exact match
            break
    else:
        return False
    
    return True


def _get_default_branch(repo_root: str) -> str:
    """Return the default branch name for the repo at repo_root.

    Detection order (first success wins):
    1. git symbolic-ref --short refs/remotes/origin/HEAD  (strips "origin/" prefix)
    2. git config --get init.defaultBranch
    3. literal "main"

    Each step is fail-soft — exceptions and non-zero exits fall through to the next.
    Result is NOT cached between invocations (the hook runs once per tool call).
    """
    # 1. Try origin/HEAD
    try:
        result = subprocess.run(
            ["git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
            capture_output=True,
            text=True,
            cwd=repo_root,
            timeout=5,
        )
        if result.returncode == 0:
            ref = result.stdout.strip()
            # Strip "origin/" prefix that git symbolic-ref adds
            if ref.startswith("origin/"):
                ref = ref[len("origin/"):]
            if ref:
                return ref
    except Exception:
        pass

    # 2. Try git config init.defaultBranch
    try:
        result = subprocess.run(
            ["git", "config", "--get", "init.defaultBranch"],
            capture_output=True,
            text=True,
            cwd=repo_root,
            timeout=5,
        )
        if result.returncode == 0:
            branch = result.stdout.strip()
            if branch:
                return branch
    except Exception:
        pass

    # 3. Hard fallback
    return "main"


def _build_canonical_off_default_deny(
    file_path: str, branch: str, default_branch: str
) -> dict:
    """Return a deny dict for writes to the canonical workspace on a non-default branch.

    This enforces the t1990 rule: ALL work goes through a linked worktree.
    The canonical repo directory must stay on the default branch.
    """
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                f"BLOCKED by git_safety_guard.py (aidevops t1990)\n\n"
                f"Reason: Canonical workspace is on '{branch}' "
                f"(default branch is '{default_branch}').\n\n"
                f"Per t1990, ALL work goes through a linked worktree. "
                f"The canonical repo directory must stay on '{default_branch}'.\n\n"
                f"Options:\n"
                f"  (a) Use a linked worktree for this work:\n"
                f"        wt switch -c feature/your-task-name\n\n"
                f"  (b) Reset canonical to the default branch:\n"
                f"        git switch {default_branch}\n\n"
                f"  (c) Override for this operation (RARE — document reason):\n"
                f"        AIDEVOPS_SKIP_CANONICAL_GUARD=1 <your-command>"
            ),
        }
    }


TAKES_BRANCH_ARG = {
    "-b",
    "-B",
    "-c",
    "-C",
    "--create",
    "--force-create",
    "--orphan",
}
OPTION_WITH_VALUE = {"-t", "--track", "--conflict", "--pathspec-from-file"}


def _extract_text_from_content(content) -> str:
    """Return plain text from common runtime transcript content shapes."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for item in content:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                text = item.get("text") or item.get("content") or ""
                if isinstance(text, str):
                    parts.append(text)
        return "\n".join(parts)
    if isinstance(content, dict):
        text = content.get("text") or content.get("content") or ""
        if isinstance(text, str):
            return text
    return ""


def _extract_user_text_from_record(record: dict) -> str:
    """Return user message text from a Claude/OpenCode-style transcript record."""
    if not isinstance(record, dict):
        return ""

    if record.get("role") == "user":
        return _extract_text_from_content(record.get("content"))

    message = record.get("message")
    if isinstance(message, dict) and message.get("role") == "user":
        return _extract_text_from_content(message.get("content"))

    if record.get("type") == "user":
        return _extract_text_from_content(record.get("content"))

    return ""


def _latest_user_message_from_transcript(transcript_path: str) -> str:
    """Return the latest user message from a JSONL transcript path."""
    if not transcript_path:
        return ""
    latest = ""
    try:
        with open(transcript_path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                text = _extract_user_text_from_record(record)
                if text:
                    latest = text
    except OSError:
        return ""
    return latest


def _current_user_message(input_data: dict) -> str:
    """Return the live current-turn user message when the runtime provides it."""
    for key in (
        "aidevops_current_user_message",
        "current_user_message",
        "current_user_turn",
        "user_message",
    ):
        value = input_data.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    transcript_path = input_data.get("transcript_path") or input_data.get("transcriptPath")
    if isinstance(transcript_path, str):
        return _latest_user_message_from_transcript(transcript_path)
    return ""


def _branch_target_is_current_turn_authorized(target: str, user_message: str) -> bool:
    """Return True when the live user explicitly requested this branch switch."""
    if not target or not user_message:
        return False
    quoted = re.escape(target)
    patterns = [
        rf"\bgit\s+(?:switch|checkout)\s+{quoted}\b",
        rf"\b(?:switch|checkout)\s+(?:to\s+)?(?:the\s+)?(?:branch\s+)?{quoted}\b",
        rf"\bchange\s+(?:back\s+)?(?:to\s+)?(?:the\s+)?(?:branch\s+)?{quoted}\b",
        rf"\brestore\s+(?:the\s+)?canonical(?:\s+repo(?:sitory)?)?\s+(?:back\s+)?to\s+{quoted}\b",
    ]
    return any(re.search(pattern, user_message, re.IGNORECASE) for pattern in patterns)


def _split_git_switch_command(command: str) -> tuple[str, list[str]]:
    """Return the git switch/checkout subcommand and args, or empty values."""
    subcommand = ""
    args: list[str] = []
    try:
        tokens = shlex.split(command)
    except ValueError:
        tokens = []
    if len(tokens) >= 3 and tokens[0] == "git" and tokens[1] in ("switch", "checkout"):
        subcommand = tokens[1]
        args = tokens[2:]
    return subcommand, args


def _scan_git_switch_args(subcommand: str, args: list[str]) -> tuple[str, bool]:
    """Return the first branch-like target and whether the command creates it."""
    target = ""
    creates_branch = False
    index = 0
    while index < len(args) and not target:
        arg = args[index]
        if arg in TAKES_BRANCH_ARG:
            if index + 1 < len(args):
                target = args[index + 1]
                creates_branch = True
        elif arg in OPTION_WITH_VALUE:
            index += 2
            continue
        elif arg.startswith("-"):
            index += 1
            continue
        elif subcommand == "checkout" and any(ch in arg for ch in ("/", ".")):
            # Likely a file/path checkout, not a branch switch.
            target = ""
        else:
            target = arg
        index += 1
    return target, creates_branch


def _extract_git_switch_target(command: str) -> tuple[str, bool]:
    """Return the target branch and creation flag for git switch/checkout."""
    subcommand, args = _split_git_switch_command(command)
    target = ""
    creates_branch = False
    if subcommand and "--" not in args:
        target, creates_branch = _scan_git_switch_args(subcommand, args)
    return target, creates_branch


def _canonical_branch_switch_deny(target: str, default_branch: str) -> dict:
    """Return a deny payload for canonical workspace branch switches."""
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                "BLOCKED by git_safety_guard.py (aidevops t1990)\n\n"
                f"Reason: Canonical workspace cannot switch to or create branch '{target}'.\n\n"
                "Per t1990, the canonical repo directory must stay on the default branch. "
                "Create or use a linked worktree under the configured workspace root instead:\n"
                f"  wt switch -c {target}\n\n"
                f"To restore canonical state, run: git switch {default_branch}"
            ),
        }
    }


def _canonical_branch_switch_user_request_deny(target: str, default_branch: str) -> dict:
    """Return a deny payload when the live user did not request the branch switch."""
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                "BLOCKED by git_safety_guard.py (aidevops t3573)\n\n"
                f"Reason: Canonical workspace branch switch to '{target}' was not "
                "explicitly requested by the live user in the current turn.\n\n"
                "Use a linked worktree for feature work instead:\n"
                f"  wt switch -c {target}\n\n"
                "Canonical restoration is allowed only when the current user turn "
                f"explicitly asks for this exact branch, for example: git switch {default_branch}"
            ),
        }
    }


def _check_canonical_branch_switch_command(
    command: str, current_user_message: str
) -> "dict | None":
    """Deny unrequested git switch/checkout commands in the canonical checkout."""
    cwd = os.getcwd()
    repo_root = _get_repo_root(cwd)
    target = ""
    creates_branch = False
    if repo_root and not _is_linked_worktree(repo_root):
        target, creates_branch = _extract_git_switch_target(command)
    default_branch = _get_default_branch(repo_root) if target else ""
    if not target or target == "-":
        return None
    if creates_branch or target not in (default_branch, "main", "master"):
        return _canonical_branch_switch_deny(target, default_branch)
    if not _branch_target_is_current_turn_authorized(target, current_user_message):
        return _canonical_branch_switch_user_request_deny(target, default_branch)
    return None


def _check_main_branch_allowlist(file_path: str) -> "dict | None":
    """Check if an Edit/Write to file_path is allowed on the current branch.

    Enforces two related rules:
      t1712 — On the default branch: only allowlisted paths may be written
               without a linked worktree (README.md, TODO.md, todo/**).
      t1990 — Off the default branch in the canonical workspace: all writes
               are denied unless inside a linked worktree.

    Returns a deny dict if the write should be blocked, None if allowed.
    """
    # Early exit: invalid inputs
    if not file_path:
        return None

    # Always use cwd for git commands — avoids failures for new (not-yet-created) files
    cwd = os.getcwd()

    # Resolve repo root from cwd (reliable even for new files)
    repo_root = _get_repo_root(cwd)
    if not repo_root:
        return None  # Not in a git repo — allow

    branch = _get_current_branch(repo_root)
    if not branch:
        return None  # Cannot determine branch — allow

    # Linked worktrees are always allowed, regardless of branch
    if _is_linked_worktree(repo_root):
        return None

    # Explicit escape valve (use sparingly — document reason at call site)
    if os.environ.get("AIDEVOPS_SKIP_CANONICAL_GUARD"):
        return None

    # Detect default branch dynamically (replaces hardcoded "main"/"master" check)
    default_branch = _get_default_branch(repo_root)

    if branch == default_branch:
        # On the default branch: allowlist governs
        if _is_main_allowlisted(file_path, repo_root):
            return None  # Allowlisted path — allow

        # Deny: non-allowlisted path on default branch in canonical workspace
        return {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": (
                    f"BLOCKED by git_safety_guard.py (aidevops t1712)\n\n"
                    f"Reason: '{file_path}' is not in the default-branch write allowlist.\n\n"
                    f"Allowlisted paths (writable on '{default_branch}' without a worktree): "
                    f"README.md, TODO.md, todo/**\n\n"
                    f"All other edits must be made in a linked worktree:\n"
                    f"  wt switch -c feature/your-task-name\n\n"
                    f"This enforces the canonical-repo-on-{default_branch} policy (t1712)."
                ),
            }
        }
    else:
        # Off the default branch in the canonical workspace: always deny
        # (workers operate in their own linked worktrees; an off-default canonical
        # means a prior session left the canonical in a dirty state)
        return _build_canonical_off_default_deny(file_path, branch, default_branch)


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

    current_user_message = _current_user_message(input_data)
    branch_switch_deny = _check_canonical_branch_switch_command(
        command, current_user_message
    )
    if branch_switch_deny:
        print(json.dumps(branch_switch_deny))
        sys.exit(0)

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
