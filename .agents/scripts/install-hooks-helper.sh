#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2059
#
# install-hooks-helper.sh
# Installs Claude Code PreToolUse hooks to block destructive git/filesystem commands
#
# Usage:
#   install-hooks-helper.sh install   # Install hooks (default)
#   install-hooks-helper.sh uninstall # Remove hooks
#   install-hooks-helper.sh status    # Check installation status
#   install-hooks-helper.sh test      # Run hook self-test
#
# Installs to:
#   ~/.aidevops/hooks/git_safety_guard.py  (hook script)
#   ~/.claude/settings.json                (hook configuration)
#
set -euo pipefail

# Colors — sourced from shared-constants.sh (Pattern A, t2053.3)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

HOOKS_DIR="$HOME/.aidevops/hooks"
HOOK_SCRIPT="$HOOKS_DIR/git_safety_guard.py"
POST_HOOK_SCRIPT="$HOOKS_DIR/mcp_task_post_hook.py"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
HOOK_COMMAND="\$HOME/.aidevops/hooks/git_safety_guard.py"
POST_HOOK_COMMAND="\$HOME/.aidevops/hooks/mcp_task_post_hook.py"

# gh-wrapper-guard pre-push hook (t2113)
GH_WRAPPER_GUARD_MARKER="# aidevops-gh-wrapper-guard"
GH_WRAPPER_GUARD_DEPLOYED="$HOME/.aidevops/agents/hooks/gh-wrapper-guard-pre-push.sh"

print_info() { printf "${BLUE}[INFO]${NC} %s\n" "$1"; }
print_success() { printf "${GREEN}[OK]${NC} %s\n" "$1"; }
print_warning() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; }
print_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

# Find the source hook script (repo .agents/hooks/ or deployed ~/.aidevops/agents/hooks/)
find_source_hook() {
	local hook_name="${1:-git_safety_guard.py}"
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local repo_hook="$script_dir/../hooks/$hook_name"
	local deployed_hook="$HOME/.aidevops/agents/hooks/$hook_name"

	if [[ -f "$repo_hook" ]]; then
		echo "$repo_hook"
		return 0
	elif [[ -f "$deployed_hook" ]]; then
		echo "$deployed_hook"
		return 0
	else
		print_error "Source hook '$hook_name' not found in repo or deployed agents"
		return 1
	fi
}

# --- gh-wrapper-guard pre-push hook (t2113) ---

_find_gh_wrapper_guard_hook() {
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local repo_hook="$script_dir/../hooks/gh-wrapper-guard-pre-push.sh"
	if [[ -f "$repo_hook" ]]; then
		echo "$repo_hook"
		return 0
	fi
	if [[ -f "$GH_WRAPPER_GUARD_DEPLOYED" ]]; then
		echo "$GH_WRAPPER_GUARD_DEPLOYED"
		return 0
	fi
	return 1
}

install_gh_wrapper_guard_hook() {
	# Only install if we're in a git repo
	local common_dir
	common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || {
		print_warning "Not in a git repo — skipping gh-wrapper-guard pre-push hook"
		return 0
	}

	local hook_path="${common_dir}/hooks/pre-push"
	mkdir -p "$(dirname "$hook_path")"

	local source_hook
	if ! source_hook=$(_find_gh_wrapper_guard_hook); then
		print_warning "gh-wrapper-guard-pre-push.sh not found — skipping"
		return 0
	fi

	if [[ -f "$hook_path" ]]; then
		if grep -q "$GH_WRAPPER_GUARD_MARKER" "$hook_path" 2>/dev/null; then
			print_info "gh-wrapper-guard already in pre-push hook — updating"
		elif grep -q "aidevops" "$hook_path" 2>/dev/null; then
			# Existing aidevops hook (e.g. privacy-guard) — chain ours in
			if ! grep -q "gh-wrapper-guard" "$hook_path" 2>/dev/null; then
				# Append our guard call before the final exec/exit
				# shellcheck disable=SC2016 # single quotes intentional — template content
				{
					printf '\n%s\n' "$GH_WRAPPER_GUARD_MARKER"
					printf '# gh-wrapper-guard: blocks raw gh issue/pr create calls\n'
					printf '_ghwg_hook=""\n'
					printf 'if git_dir=$(git rev-parse --show-toplevel 2>/dev/null); then\n'
					printf '  _ghwg_hook="${git_dir}/.agents/hooks/gh-wrapper-guard-pre-push.sh"\n'
					printf 'fi\n'
					printf 'if [[ -n "$_ghwg_hook" && -f "$_ghwg_hook" ]]; then\n'
					printf '  "$_ghwg_hook" "$@" || exit $?\n'
					printf 'elif [[ -f "%s" ]]; then\n' "$GH_WRAPPER_GUARD_DEPLOYED"
					printf '  "%s" "$@" || exit $?\n' "$GH_WRAPPER_GUARD_DEPLOYED"
					printf 'fi\n'
				} >>"$hook_path"
				print_success "chained gh-wrapper-guard into existing pre-push hook"
			fi
			return 0
		else
			print_warning "existing non-aidevops pre-push hook — cannot auto-install gh-wrapper-guard"
			print_warning "  manually add: $source_hook \"\$@\" || exit \$?"
			return 0
		fi
	fi

	# No existing hook — only install if no privacy-guard installer would manage it
	# Write a standalone dispatcher if no hook exists at all
	if [[ ! -f "$hook_path" ]]; then
		cat >"$hook_path" <<HOOKEOF
#!/usr/bin/env bash
$GH_WRAPPER_GUARD_MARKER
# Managed by install-hooks-helper.sh — do not edit.
# Dispatcher for gh-wrapper-guard pre-push hook.
# Bypass with --no-verify or GH_WRAPPER_GUARD_DISABLE=1.

set -u

_ghwg_hook=""
if git_dir=\$(git rev-parse --show-toplevel 2>/dev/null); then
	_ghwg_hook="\${git_dir}/.agents/hooks/gh-wrapper-guard-pre-push.sh"
fi
_ghwg_deployed="$GH_WRAPPER_GUARD_DEPLOYED"

if [[ -n "\$_ghwg_hook" && -f "\$_ghwg_hook" ]]; then
	"\$_ghwg_hook" "\$@" || exit \$?
elif [[ -f "\$_ghwg_deployed" ]]; then
	"\$_ghwg_deployed" "\$@" || exit \$?
else
	printf '[gh-wrapper-guard][WARN] hook not found — allowing push\n' >&2
fi
HOOKEOF
		chmod +x "$hook_path"
		print_success "installed gh-wrapper-guard pre-push hook at $hook_path"
	fi
	return 0
}

install_hook() {
	print_info "Installing Claude Code safety hooks..."

	# Check Python is available
	if ! command -v python3 &>/dev/null; then
		print_error "Python 3 is required but not found"
		return 1
	fi

	# Find source hook
	local source_hook
	source_hook=$(find_source_hook) || return 1
	local source_post_hook
	source_post_hook=$(find_source_hook "mcp_task_post_hook.py") || return 1

	# Create hooks directory
	mkdir -p "$HOOKS_DIR"

	# Copy hook script
	cp "$source_hook" "$HOOK_SCRIPT"
	chmod +x "$HOOK_SCRIPT"
	print_success "Installed $HOOK_SCRIPT"
	cp "$source_post_hook" "$POST_HOOK_SCRIPT"
	chmod +x "$POST_HOOK_SCRIPT"
	print_success "Installed $POST_HOOK_SCRIPT"

	# Configure Claude Code settings.json
	configure_claude_settings || return 1

	# Run self-test
	test_hook || return 1

	echo ""
	print_success "Safety hooks installed successfully"
	echo ""
	echo "Blocked commands:"
	echo "  git checkout -- <files>    git restore <files>"
	echo "  git reset --hard           git clean -f"
	echo "  git push --force / -f      git branch -D"
	echo "  rm -rf (non-temp paths)    git stash drop/clear"
	echo ""
	print_warning "Restart Claude Code for the hook to take effect"

	# Also install the gh-wrapper-guard pre-push hook (t2113)
	install_gh_wrapper_guard_hook

	return 0
}

configure_claude_settings() {
	mkdir -p "$(dirname "$CLAUDE_SETTINGS")"

	if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
		# Create new settings with hook
		python3 -c "
import json, sys, os, tempfile
settings = {
    'hooks': {
        'PreToolUse': [
            {
                'matcher': 'Bash',
                'hooks': [
                    {
                        'type': 'command',
                        'command': '$HOOK_COMMAND'
                    }
                ]
            }
        ],
        'PostToolUse': [
            {
                'matcher': 'Task',
                'hooks': [
                    {
                        'type': 'command',
                        'command': '$POST_HOOK_COMMAND'
                    }
                ]
            }
        ]
    }
}
path = '$CLAUDE_SETTINGS'
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
    f.flush()
    os.fsync(f.fileno())
os.rename(tmp, path)
" || {
			print_error "Failed to create settings.json"
			return 1
		}
		print_success "Created $CLAUDE_SETTINGS with hook configuration"
		return 0
	fi

	# Check if hook is already configured
	if python3 -c "
import json, sys
with open('$CLAUDE_SETTINGS') as f:
    d = json.load(f)
hooks = d.get('hooks', {})
has_pre = False
for h in hooks.get('PreToolUse', []):
    for sub in h.get('hooks', []):
        if 'git_safety_guard' in sub.get('command', ''):
            has_pre = True

has_post = False
for h in hooks.get('PostToolUse', []):
    for sub in h.get('hooks', []):
        if 'mcp_task_post_hook' in sub.get('command', ''):
            has_post = True

if has_pre and has_post:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
		print_info "Hook already configured in $CLAUDE_SETTINGS"
		return 0
	fi

	# Merge hook into existing settings
	python3 -c "
import json, sys, os, tempfile

with open('$CLAUDE_SETTINGS') as f:
    settings = json.load(f)

if 'hooks' not in settings:
    settings['hooks'] = {}

def has_hook(entries, needle):
    for entry in entries:
        for sub in entry.get('hooks', []):
            if needle in sub.get('command', ''):
                return True
    return False

hook_entry = {
    'matcher': 'Bash',
    'hooks': [
        {
            'type': 'command',
            'command': '$HOOK_COMMAND'
        }
    ]
}

post_hook_entry = {
    'matcher': 'Task',
    'hooks': [
        {
            'type': 'command',
            'command': '$POST_HOOK_COMMAND'
        }
    ]
}

if 'PreToolUse' not in settings['hooks']:
    settings['hooks']['PreToolUse'] = [hook_entry]
elif not has_hook(settings['hooks']['PreToolUse'], 'git_safety_guard'):
    settings['hooks']['PreToolUse'].append(hook_entry)

if 'PostToolUse' not in settings['hooks']:
    settings['hooks']['PostToolUse'] = [post_hook_entry]
elif not has_hook(settings['hooks']['PostToolUse'], 'mcp_task_post_hook'):
    settings['hooks']['PostToolUse'].append(post_hook_entry)

path = '$CLAUDE_SETTINGS'
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
    f.flush()
    os.fsync(f.fileno())
os.rename(tmp, path)
" || {
		print_error "Failed to update settings.json"
		return 1
	}
	print_success "Updated $CLAUDE_SETTINGS with hook configuration"
	return 0
}

uninstall_hook() {
	print_info "Removing Claude Code safety hooks..."

	# Remove hook script
	if [[ -f "$HOOK_SCRIPT" ]]; then
		rm "$HOOK_SCRIPT"
		print_success "Removed $HOOK_SCRIPT"
	else
		print_info "Hook script not found (already removed)"
	fi
	if [[ -f "$POST_HOOK_SCRIPT" ]]; then
		rm "$POST_HOOK_SCRIPT"
		print_success "Removed $POST_HOOK_SCRIPT"
	else
		print_info "Post hook script not found (already removed)"
	fi

	# Remove from Claude settings
	if [[ -f "$CLAUDE_SETTINGS" ]]; then
		python3 -c "
import json, os, tempfile

with open('$CLAUDE_SETTINGS') as f:
    settings = json.load(f)

hooks = settings.get('hooks', {}).get('PreToolUse', [])
filtered = []
for h in hooks:
    sub_hooks = h.get('hooks', [])
    sub_filtered = [s for s in sub_hooks if 'git_safety_guard' not in s.get('command', '')]
    if sub_filtered:
        h['hooks'] = sub_filtered
        filtered.append(h)

if filtered:
    settings['hooks']['PreToolUse'] = filtered
elif 'PreToolUse' in settings.get('hooks', {}):
    del settings['hooks']['PreToolUse']

post_hooks = settings.get('hooks', {}).get('PostToolUse', [])
post_filtered = []
for h in post_hooks:
    sub_hooks = h.get('hooks', [])
    sub_filtered = [s for s in sub_hooks if 'mcp_task_post_hook' not in s.get('command', '')]
    if sub_filtered:
        h['hooks'] = sub_filtered
        post_filtered.append(h)

if post_filtered:
    settings['hooks']['PostToolUse'] = post_filtered
elif 'PostToolUse' in settings.get('hooks', {}):
    del settings['hooks']['PostToolUse']

if 'hooks' in settings and not settings['hooks']:
    del settings['hooks']

path = '$CLAUDE_SETTINGS'
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
    f.flush()
    os.fsync(f.fileno())
os.rename(tmp, path)
" 2>/dev/null && print_success "Removed hook from $CLAUDE_SETTINGS"
	fi

	# Clean up empty hooks directory
	if [[ -d "$HOOKS_DIR" ]] && [[ -z "$(ls -A "$HOOKS_DIR" 2>/dev/null)" ]]; then
		rmdir "$HOOKS_DIR"
		print_info "Removed empty hooks directory"
	fi

	print_success "Safety hooks uninstalled"
	print_warning "Restart Claude Code for changes to take effect"
	return 0
}

check_status() {
	local all_ok=true

	echo "Claude Code Safety Hooks Status"
	echo "================================"

	# Check hook script
	if [[ -f "$HOOK_SCRIPT" ]]; then
		print_success "Hook script: $HOOK_SCRIPT"
		if [[ -x "$HOOK_SCRIPT" ]]; then
			print_success "  Executable: yes"
		else
			print_warning "  Executable: no (run: chmod +x $HOOK_SCRIPT)"
			all_ok=false
		fi
	else
		print_error "Hook script: not installed"
		all_ok=false
	fi

	# Check Python
	if command -v python3 &>/dev/null; then
		print_success "Python 3: $(python3 --version 2>&1)"
	else
		print_error "Python 3: not found"
		all_ok=false
	fi

	# Check Claude settings
	if [[ -f "$CLAUDE_SETTINGS" ]]; then
		if python3 -c "
import json, sys
with open('$CLAUDE_SETTINGS') as f:
    d = json.load(f)
hooks = d.get('hooks', {}).get('PreToolUse', [])
for h in hooks:
    for sub in h.get('hooks', []):
        if 'git_safety_guard' in sub.get('command', ''):
            sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
			print_success "Claude settings: hook configured"
		else
			print_warning "Claude settings: exists but hook not configured"
			all_ok=false
		fi
	else
		print_error "Claude settings: $CLAUDE_SETTINGS not found"
		all_ok=false
	fi

	# Check gh-wrapper-guard pre-push hook (t2113)
	echo ""
	echo "GH Wrapper Guard (pre-push)"
	echo "----------------------------"
	local common_dir
	if common_dir=$(git rev-parse --git-common-dir 2>/dev/null); then
		local hook_path="${common_dir}/hooks/pre-push"
		if [[ -f "$hook_path" ]] && grep -q "$GH_WRAPPER_GUARD_MARKER" "$hook_path" 2>/dev/null; then
			print_success "gh-wrapper-guard: installed in pre-push hook"
		elif [[ -f "$hook_path" ]] && grep -q "gh-wrapper-guard" "$hook_path" 2>/dev/null; then
			print_success "gh-wrapper-guard: chained in pre-push hook"
		else
			print_warning "gh-wrapper-guard: not installed (run: install-hooks-helper.sh install)"
		fi
	else
		print_info "gh-wrapper-guard: not in a git repo — skipped"
	fi

	echo ""
	if [[ "$all_ok" == "true" ]]; then
		print_success "All checks passed - safety hooks are active"
	else
		print_warning "Some checks failed - run: install-hooks-helper.sh install"
	fi
	return 0
}

test_hook() {
	print_info "Running hook self-test..."

	local test_script="$HOOK_SCRIPT"
	if [[ ! -f "$test_script" ]]; then
		# Fall back to source
		test_script=$(find_source_hook) || return 1
	fi

	local pass=0
	local fail=0

	# Test blocked commands
	local -a blocked_cmds=(
		"git checkout -- test.txt"
		"git reset --hard"
		"git clean -f"
		"git push --force origin main"
		"git push -f origin main"
		"git branch -D old-branch"
		"rm -rf /some/path"
		"git stash drop"
		"git stash clear"
		"/usr/bin/git reset --hard"
		"git restore file.txt"
	)

	for cmd in "${blocked_cmds[@]}"; do
		local result
		result=$(echo "{\"tool_name\": \"Bash\", \"tool_input\": {\"command\": \"$cmd\"}}" | python3 "$test_script" 2>/dev/null)
		if echo "$result" | grep -q "permissionDecision.*deny" 2>/dev/null; then
			pass=$((pass + 1))
		else
			print_error "  FAIL: should block: $cmd"
			fail=$((fail + 1))
		fi
	done

	# Test allowed commands
	local -a allowed_cmds=(
		"git status"
		"git checkout -b new-branch"
		"git restore --staged file.txt"
		"git clean -fn"
		"git clean --dry-run"
		"rm -rf /tmp/test-dir"
		"git push --force-with-lease"
		"git branch -d old-branch"
		"ls -la"
	)

	for cmd in "${allowed_cmds[@]}"; do
		local result
		result=$(echo "{\"tool_name\": \"Bash\", \"tool_input\": {\"command\": \"$cmd\"}}" | python3 "$test_script" 2>/dev/null)
		if [[ -z "$result" ]]; then
			pass=$((pass + 1))
		else
			print_error "  FAIL: should allow: $cmd"
			fail=$((fail + 1))
		fi
	done

	if [[ "$fail" -eq 0 ]]; then
		print_success "All $pass tests passed"
		return 0
	else
		print_error "$fail tests failed, $pass passed"
		return 1
	fi
}

show_help() {
	echo "install-hooks-helper.sh - Claude Code destructive command protection"
	echo ""
	echo "Usage: install-hooks-helper.sh [command]"
	echo ""
	echo "Commands:"
	echo "  install     Install safety hooks (default)"
	echo "  uninstall   Remove safety hooks"
	echo "  status      Check installation status"
	echo "  test        Run hook self-test"
	echo "  help        Show this help"
	echo ""
	echo "Installs to:"
	echo "  ~/.aidevops/hooks/git_safety_guard.py"
	echo "  ~/.claude/settings.json (PreToolUse hook config)"
	echo "  .git/hooks/pre-push (gh-wrapper-guard, t2113)"
	return 0
}

# Main
case "${1:-install}" in
install) install_hook ;;
uninstall) uninstall_hook ;;
status) check_status ;;
test) test_hook ;;
help | --help | -h) show_help ;;
*)
	print_error "Unknown command: $1"
	show_help
	exit 1
	;;
esac
