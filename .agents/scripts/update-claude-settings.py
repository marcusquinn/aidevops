#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Update Claude Code settings.json
# =============================================================================
# Manages ~/.claude/settings.json:
#   - Safety hooks (PreToolUse — git safety guard)
#   - Tool permissions (allow/deny/ask rules per Claude Code syntax)
#   - Preserves user customizations (model, etc.)
#
# Merge strategy: read existing, deep-merge new entries, never remove
# user-added rules. Uses Python for JSON manipulation (always available).
#
# Extracted from generate-claude-agents.sh to reduce script complexity.
# Called by: generate-claude-agents.sh (Phase 3)
# =============================================================================

import json
import os
import sys

settings_path = os.path.expanduser("~/.claude/settings.json")

try:
    with open(settings_path, 'r') as f:
        settings = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    settings = {}

changed = False

# --- Safety hooks: PreToolUse for Bash ---
# Ensures the git safety guard hook is always present
hook_command = "$HOME/.aidevops/hooks/git_safety_guard.py"
hook_entry = {
    "type": "command",
    "command": hook_command
}
bash_matcher = {
    "matcher": "Bash",
    "hooks": [hook_entry]
}

if "hooks" not in settings:
    settings["hooks"] = {}
if "PreToolUse" not in settings["hooks"]:
    settings["hooks"]["PreToolUse"] = []

# Check if Bash matcher with our hook already exists
has_bash_hook = False
for rule in settings["hooks"]["PreToolUse"]:
    if rule.get("matcher") == "Bash":
        # Ensure our hook is in the hooks list
        existing_commands = [h.get("command", "") for h in rule.get("hooks", [])]
        if hook_command not in existing_commands:
            rule.setdefault("hooks", []).append(hook_entry)
            changed = True
        has_bash_hook = True
        break

if not has_bash_hook:
    settings["hooks"]["PreToolUse"].append(bash_matcher)
    changed = True

# --- Tool permissions (allow / deny / ask) ---
# Claude Code permission rule syntax: Tool or Tool(specifier)
# Rules evaluated: deny first, then ask, then allow. First match wins.
# Merge strategy: add our rules if not already present, never remove user rules.
#
# Design rationale:
#   allow  — safe read-only commands, aidevops scripts, common dev tools
#   deny   — secrets, credentials, destructive ops (defense-in-depth with hooks)
#   ask    — powerful but legitimate operations that benefit from confirmation
#
# Reference: https://docs.anthropic.com/en/docs/claude-code/settings

permissions = settings.setdefault("permissions", {})

# ---- ALLOW rules ----
# Safe operations that should never prompt the user
allow_rules = [
    # --- aidevops framework access ---
    "Read(~/.aidevops/**)",
    "Bash(~/.aidevops/agents/scripts/*)",

    # --- Read-only git commands ---
    "Bash(git status)",
    "Bash(git status *)",
    "Bash(git log *)",
    "Bash(git diff *)",
    "Bash(git diff)",
    "Bash(git branch *)",
    "Bash(git branch)",
    "Bash(git show *)",
    "Bash(git rev-parse *)",
    "Bash(git ls-files *)",
    "Bash(git ls-files)",
    "Bash(git remote -v)",
    "Bash(git stash list)",
    "Bash(git tag *)",
    "Bash(git tag)",

    # --- Safe git write operations ---
    "Bash(git add *)",
    "Bash(git add .)",
    "Bash(git commit *)",
    "Bash(git checkout -b *)",
    "Bash(git switch -c *)",
    "Bash(git switch *)",
    "Bash(git push *)",
    "Bash(git push)",
    "Bash(git pull *)",
    "Bash(git pull)",
    "Bash(git fetch *)",
    "Bash(git fetch)",
    "Bash(git merge *)",
    "Bash(git rebase *)",
    "Bash(git stash *)",
    "Bash(git worktree *)",
    "Bash(git branch -d *)",
    "Bash(git push --force-with-lease *)",
    "Bash(git push --force-if-includes *)",

    # --- GitHub CLI (read + PR operations) ---
    "Bash(gh pr *)",
    "Bash(gh issue *)",
    "Bash(gh run *)",
    "Bash(gh api *)",
    "Bash(gh repo *)",
    "Bash(gh auth status *)",
    "Bash(gh auth status)",

    # --- Common dev tools ---
    "Bash(npm run *)",
    "Bash(npm test *)",
    "Bash(npm test)",
    "Bash(npm install *)",
    "Bash(npm install)",
    "Bash(npm ci)",
    "Bash(npx *)",
    "Bash(bun *)",
    "Bash(pnpm *)",
    "Bash(yarn *)",
    "Bash(node *)",
    "Bash(python3 *)",
    "Bash(python *)",
    "Bash(pip *)",

    # --- File discovery and search ---
    "Bash(fd *)",
    "Bash(rg *)",
    "Bash(find *)",
    "Bash(grep *)",
    "Bash(wc *)",
    "Bash(ls *)",
    "Bash(ls)",
    "Bash(tree *)",

    # --- Quality tools ---
    "Bash(shellcheck *)",
    "Bash(eslint *)",
    "Bash(prettier *)",
    "Bash(tsc *)",

    # --- Common system utilities ---
    "Bash(which *)",
    "Bash(command -v *)",
    "Bash(uname *)",
    "Bash(date *)",
    "Bash(pwd)",
    "Bash(whoami)",
    "Bash(cat *)",
    "Bash(head *)",
    "Bash(tail *)",
    "Bash(sort *)",
    "Bash(uniq *)",
    "Bash(cut *)",
    "Bash(awk *)",
    "Bash(sed *)",
    "Bash(jq *)",
    "Bash(basename *)",
    "Bash(dirname *)",
    "Bash(realpath *)",
    "Bash(readlink *)",
    "Bash(stat *)",
    "Bash(file *)",
    "Bash(diff *)",
    "Bash(mkdir *)",
    "Bash(touch *)",
    "Bash(cp *)",
    "Bash(mv *)",
    "Bash(chmod *)",
    "Bash(echo *)",
    "Bash(printf *)",
    "Bash(test *)",
    "Bash([ *)",

    # --- Claude CLI (for sub-agent dispatch) ---
    "Bash(claude *)",
]

# ---- DENY rules ----
# Block access to secrets and destructive operations (defense-in-depth)
deny_rules = [
    # --- Secrets and credentials ---
    "Read(./.env)",
    "Read(./.env.*)",
    "Read(./secrets/**)",
    "Read(./**/credentials.json)",
    "Read(./**/.env)",
    "Read(./**/.env.*)",
    "Read(~/.config/aidevops/credentials.sh)",

    # --- Destructive git (also blocked by PreToolUse hook) ---
    "Bash(git push --force *)",
    "Bash(git push -f *)",
    "Bash(git reset --hard *)",
    "Bash(git reset --hard)",
    "Bash(git clean -f *)",
    "Bash(git clean -f)",
    "Bash(git checkout -- *)",
    "Bash(git branch -D *)",

    # --- Dangerous system commands ---
    "Bash(rm -rf /)",
    "Bash(rm -rf /*)",
    "Bash(rm -rf ~)",
    "Bash(rm -rf ~/*)",
    "Bash(sudo *)",
    "Bash(chmod 777 *)",

    # --- Secret exposure prevention ---
    "Bash(gopass show *)",
    "Bash(pass show *)",
    "Bash(op read *)",
    "Bash(cat ~/.config/aidevops/credentials.sh)",
]

# ---- ASK rules ----
# Powerful operations that benefit from user confirmation
ask_rules = [
    # --- Potentially destructive file operations ---
    "Bash(rm -rf *)",
    "Bash(rm -r *)",

    # --- Network operations ---
    "Bash(curl *)",
    "Bash(wget *)",

    # --- Docker/container operations ---
    "Bash(docker *)",
    "Bash(docker-compose *)",
    "Bash(orbctl *)",
]


# Merge function: add rules not already present, preserve user additions
def merge_rules(existing, new_rules):
    """Add new_rules to existing list if not already present. Returns True if changed."""
    added = False
    for rule in new_rules:
        if rule not in existing:
            existing.append(rule)
            added = True
    return added


# Also clean up any expanded-path rules from prior versions.
# These are bare paths that will be replaced by the new Tool(specifier) syntax.
home = os.path.expanduser("~")
existing_allow = permissions.get("allow", [])
original_len = len(existing_allow)
cleaned_allow = [
    rule for rule in existing_allow
    if not (rule.startswith(home + "/") and "(" not in rule)
]

if len(cleaned_allow) != original_len:
    permissions["allow"] = cleaned_allow
    changed = True

allow_list = permissions.setdefault("allow", [])
deny_list = permissions.setdefault("deny", [])
ask_list = permissions.setdefault("ask", [])

if merge_rules(allow_list, allow_rules):
    changed = True
if merge_rules(deny_list, deny_rules):
    changed = True
if merge_rules(ask_list, ask_rules):
    changed = True

settings["permissions"] = permissions

# --- JSON Schema reference for editor autocomplete ---
if "$schema" not in settings:
    settings["$schema"] = "https://json.schemastore.org/claude-code-settings.json"
    changed = True

# Write back if changed
if changed:
    with open(settings_path, 'w') as f:
        json.dump(settings, f, indent=2)
        f.write('\n')
    print(f"  \033[0;32m+\033[0m Updated {settings_path}")
else:
    print(f"  \033[0;34m=\033[0m {settings_path} (no changes needed)")
