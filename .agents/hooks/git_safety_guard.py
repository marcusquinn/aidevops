#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Claude Code adapter for shared command policy and write safety.

Shell-command decisions are delegated to command-policy-helper.py. This hook
also enforces the canonical-workspace Edit/Write rule (t1712/t1990):
  - Edit/Write on the default branch: only allowlisted paths permitted
    (README.md, TODO.md, todo/**) without a linked worktree.
  - Edit/Write on any non-default branch in the canonical workspace: always
    denied unless inside a linked worktree. Default branch is auto-detected
    from origin/HEAD (with fallbacks to init.defaultBranch then "main") so
    repos using develop/trunk/etc. are covered equally.

This hook runs before Bash/Edit/Write tool calls execute.
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

"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

GIT_BINARY = os.environ.get("AIDEVOPS_REAL_GIT", "")
if not GIT_BINARY:
    GIT_BINARY = (
        "/usr/bin/git"
        if os.path.isfile("/usr/bin/git")
        else (shutil.which("git") or "git")
    )

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
            [GIT_BINARY, "branch", "--show-current"],
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
            [GIT_BINARY, "rev-parse", "--git-dir"],
            capture_output=True,
            text=True,
            cwd=cwd,
            timeout=5,
        ).stdout.strip()
        git_common_dir = subprocess.run(
            [GIT_BINARY, "rev-parse", "--git-common-dir"],
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
            [GIT_BINARY, "rev-parse", "--show-toplevel"],
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
            [GIT_BINARY, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
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
            [GIT_BINARY, "config", "--get", "init.defaultBranch"],
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
                f"  (b) Restore canonical state through the audited recovery helper "
                f"when appropriate."
            ),
        }
    }


def _check_command_policy(command: str) -> "dict | None":
    """Return a Claude deny payload unless the shared safety floor allows."""
    candidates = [
        os.environ.get("AIDEVOPS_COMMAND_POLICY_HELPER", ""),
        str(Path(__file__).resolve().parent.parent / "scripts" / "command-policy-helper.py"),
        str(Path.home() / ".aidevops" / "agents" / "scripts" / "command-policy-helper.py"),
    ]
    helper = next((path for path in candidates if path and os.path.isfile(path)), "")
    decision = "forbid"
    rule_id = "policy.helper-unavailable"
    reason = "required command safety policy helper is unavailable"
    if helper:
        try:
            result = subprocess.run(
                [
                    sys.executable,
                    helper,
                    "check-command",
                    "--cwd",
                    os.getcwd(),
                    "--command",
                    command,
                ],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            rule_id = "policy.helper-error"
            reason = f"command safety policy failed closed: {exc}"
        else:
            try:
                payload = json.loads(result.stdout)
            except (json.JSONDecodeError, TypeError):
                payload = {}
            decision = payload.get("decision", "forbid")
            rule_id = payload.get("rule_id", "policy.invalid-response")
            reason = payload.get(
                "reason", "command safety policy returned an invalid response"
            )
            if result.returncode == 0 and decision == "allow":
                return None
    return {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                f"BLOCKED by shared command policy ({decision}, {rule_id})\n\n"
                f"Reason: {reason}"
            ),
        }
    }


def _check_main_branch_allowlist(file_path: str) -> "dict | None":
    """Check if an Edit/Write to file_path is allowed on the current branch.

    Enforces two related rules:
      t1712 — On the default branch: only allowlisted paths may be written
               without a linked worktree (README.md, TODO.md, todo/**).
      t1990 — Off the default branch in the canonical workspace: all writes
               are denied unless inside a linked worktree.

    Returns a deny dict if the write should be blocked, None if allowed.
    """
    # Always use cwd for git commands — avoids failures for new (not-yet-created) files
    cwd = os.getcwd()

    # Resolve repo root from cwd (reliable even for new files)
    repo_root = _get_repo_root(cwd) if file_path else ""
    branch = _get_current_branch(repo_root) if repo_root else ""
    if not file_path or not repo_root or not branch:
        return None  # Invalid path, not in git, or cannot determine branch — allow

    # Linked worktrees are the only writable branch context.
    if _is_linked_worktree(repo_root):
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


def main():
    """Delegate Bash policy and enforce the Edit/Write worktree allowlist."""
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

    command = tool_input.get("command", "")
    if tool_name != "Bash" or not isinstance(command, str) or not command:
        sys.exit(0)
    deny = _check_command_policy(command)
    if deny:
        print(json.dumps(deny))
    sys.exit(0)


if __name__ == "__main__":
    main()
