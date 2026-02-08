#!/usr/bin/env bash
# shellcheck disable=SC2059
set -euo pipefail

# install-hooks.sh - Install Claude Code safety hooks
#
# Deploys git_safety_guard.py as a PreToolUse hook that blocks
# destructive git and filesystem commands before they execute.
#
# Usage:
#   install-hooks.sh                    # Install globally (~/.claude/)
#   install-hooks.sh --project          # Install in current project (.claude/)
#   install-hooks.sh --uninstall        # Remove global hook
#   install-hooks.sh --test             # Run hook self-test
#   install-hooks.sh --help             # Show this help
#
# Part of: aidevops framework (https://aidevops.sh)
# Task: t009 - Claude Code Destructive Command Hooks

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SOURCE="${SCRIPT_DIR}/../hooks/git_safety_guard.py"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_help() {
    local script_name
    script_name="$(basename "$0")"
    printf "Usage: %s [OPTIONS]\n\n" "${script_name}"
    printf "Install Claude Code safety hooks to block destructive commands.\n\n"
    printf "Options:\n"
    printf "  --project     Install in current project (.claude/) instead of globally\n"
    printf "  --uninstall   Remove the safety hook\n"
    printf "  --test        Run hook self-test without installing\n"
    printf "  --help        Show this help\n\n"
    printf "Default: Install globally to ~/.claude/ (protects all projects)\n\n"
    printf "Blocked commands:\n"
    printf "  git checkout -- <files>    git restore <files>\n"
    printf "  git reset --hard           git clean -f\n"
    printf "  git push --force / -f      git branch -D\n"
    printf "  rm -rf (non-temp paths)    git stash drop/clear\n"
    return 0
}

check_python() {
    if ! command -v python3 >/dev/null 2>&1; then
        printf "${RED}Error: python3 is required but not found.${NC}\n" >&2
        printf "Install Python 3: https://www.python.org/downloads/\n" >&2
        return 1
    fi
    return 0
}

check_hook_source() {
    if [[ ! -f "${HOOK_SOURCE}" ]]; then
        printf "${RED}Error: Hook source not found at %s${NC}\n" "${HOOK_SOURCE}" >&2
        printf "Run 'aidevops update' to restore framework files.\n" >&2
        return 1
    fi
    return 0
}

run_test() {
    local hook_path="${1:-${HOOK_SOURCE}}"
    local pass_count=0
    local fail_count=0

    printf "${BLUE}Testing git_safety_guard.py...${NC}\n\n"

    run_case() {
        local description="$1"
        local input_json="$2"
        local expect_blocked="$3"

        local result
        result=$(echo "${input_json}" | python3 "${hook_path}" 2>/dev/null) || true

        local is_blocked="false"
        if echo "${result}" | grep -q '"permissionDecision".*"deny"' 2>/dev/null; then
            is_blocked="true"
        fi

        if [[ "${is_blocked}" == "${expect_blocked}" ]]; then
            printf "${GREEN}PASS${NC} %s\n" "${description}"
            pass_count=$((pass_count + 1))
        else
            printf "${RED}FAIL${NC} %s (expected blocked=%s, got blocked=%s)\n" \
                "${description}" "${expect_blocked}" "${is_blocked}"
            fail_count=$((fail_count + 1))
        fi
    }

    # Should be BLOCKED
    run_case "git checkout -- file.txt" \
        '{"tool_name":"Bash","tool_input":{"command":"git checkout -- file.txt"}}' "true"
    run_case "git restore file.txt" \
        '{"tool_name":"Bash","tool_input":{"command":"git restore file.txt"}}' "true"
    run_case "git reset --hard" \
        '{"tool_name":"Bash","tool_input":{"command":"git reset --hard"}}' "true"
    run_case "git reset --hard HEAD~1" \
        '{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~1"}}' "true"
    run_case "git clean -fd" \
        '{"tool_name":"Bash","tool_input":{"command":"git clean -fd"}}' "true"
    run_case "git push --force" \
        '{"tool_name":"Bash","tool_input":{"command":"git push --force"}}' "true"
    run_case "git push -f origin main" \
        '{"tool_name":"Bash","tool_input":{"command":"git push -f origin main"}}' "true"
    run_case "git branch -D feature/old" \
        '{"tool_name":"Bash","tool_input":{"command":"git branch -D feature/old"}}' "true"
    run_case "rm -rf /home/user/project" \
        '{"tool_name":"Bash","tool_input":{"command":"rm -rf /home/user/project"}}' "true"
    run_case "rm -rf ./src" \
        '{"tool_name":"Bash","tool_input":{"command":"rm -rf ./src"}}' "true"
    run_case "git stash drop" \
        '{"tool_name":"Bash","tool_input":{"command":"git stash drop"}}' "true"
    run_case "git stash clear" \
        '{"tool_name":"Bash","tool_input":{"command":"git stash clear"}}' "true"
    run_case "/usr/bin/git reset --hard" \
        '{"tool_name":"Bash","tool_input":{"command":"/usr/bin/git reset --hard"}}' "true"
    run_case "/bin/rm -rf /home/user" \
        '{"tool_name":"Bash","tool_input":{"command":"/bin/rm -rf /home/user"}}' "true"
    run_case "git reset --merge" \
        '{"tool_name":"Bash","tool_input":{"command":"git reset --merge"}}' "true"
    run_case "git restore --worktree file.txt" \
        '{"tool_name":"Bash","tool_input":{"command":"git restore --worktree file.txt"}}' "true"
    run_case "rm -r -f ./build" \
        '{"tool_name":"Bash","tool_input":{"command":"rm -r -f ./build"}}' "true"
    run_case "rm --recursive --force ./dist" \
        '{"tool_name":"Bash","tool_input":{"command":"rm --recursive --force ./dist"}}' "true"

    # Should be ALLOWED
    run_case "git status (safe)" \
        '{"tool_name":"Bash","tool_input":{"command":"git status"}}' "false"
    run_case "git checkout -b new-branch (safe)" \
        '{"tool_name":"Bash","tool_input":{"command":"git checkout -b new-branch"}}' "false"
    run_case "git checkout --orphan gh-pages (safe)" \
        '{"tool_name":"Bash","tool_input":{"command":"git checkout --orphan gh-pages"}}' "false"
    run_case "git restore --staged file.txt (safe)" \
        '{"tool_name":"Bash","tool_input":{"command":"git restore --staged file.txt"}}' "false"
    run_case "git clean -n (safe dry run)" \
        '{"tool_name":"Bash","tool_input":{"command":"git clean -n"}}' "false"
    run_case "git clean -fn (safe dry run)" \
        '{"tool_name":"Bash","tool_input":{"command":"git clean -fn"}}' "false"
    run_case "git clean --dry-run (safe)" \
        '{"tool_name":"Bash","tool_input":{"command":"git clean --dry-run"}}' "false"
    run_case "rm -rf /tmp/test-dir (safe temp)" \
        '{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/test-dir"}}' "false"
    run_case "rm -rf /var/tmp/build (safe temp)" \
        '{"tool_name":"Bash","tool_input":{"command":"rm -rf /var/tmp/build"}}' "false"
    run_case "git push --force-with-lease (safe)" \
        '{"tool_name":"Bash","tool_input":{"command":"git push --force-with-lease"}}' "false"
    run_case "git push --force-if-includes (safe)" \
        '{"tool_name":"Bash","tool_input":{"command":"git push --force-if-includes"}}' "false"
    run_case "git branch -d feature/merged (safe)" \
        '{"tool_name":"Bash","tool_input":{"command":"git branch -d feature/merged"}}' "false"
    run_case "npm test (safe)" \
        '{"tool_name":"Bash","tool_input":{"command":"npm test"}}' "false"
    run_case "Non-Bash tool (safe)" \
        '{"tool_name":"Edit","tool_input":{"file_path":"test.txt"}}' "false"
    run_case "Empty command (safe)" \
        '{"tool_name":"Bash","tool_input":{"command":""}}' "false"
    run_case "Invalid JSON (safe)" \
        'not json at all' "false"

    printf "\n${BLUE}Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}\n" \
        "${pass_count}" "${fail_count}"

    if [[ "${fail_count}" -gt 0 ]]; then
        return 1
    fi
    return 0
}

install_hook() {
    local install_dir="$1"
    local hook_path_var="$2"

    check_python || return 1
    check_hook_source || return 1

    mkdir -p "${install_dir}/hooks"

    cp "${HOOK_SOURCE}" "${install_dir}/hooks/git_safety_guard.py"
    chmod +x "${install_dir}/hooks/git_safety_guard.py"
    printf "${GREEN}+${NC} Deployed %s/hooks/git_safety_guard.py\n" "${install_dir}"

    local settings_file="${install_dir}/settings.json"
    local hook_entry
    hook_entry=$(cat <<HOOK_JSON
{
  "matcher": "Bash",
  "hooks": [
    {
      "type": "command",
      "command": "${hook_path_var}"
    }
  ]
}
HOOK_JSON
)

    if [[ -f "${settings_file}" ]]; then
        if python3 -c "
import json, sys
with open('${settings_file}') as f:
    d = json.load(f)
hooks = d.get('hooks', {})
pre = hooks.get('PreToolUse', [])
for entry in pre:
    for h in entry.get('hooks', []):
        if 'git_safety_guard' in h.get('command', ''):
            sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
            printf "${YELLOW}!${NC} Hook already configured in %s\n" "${settings_file}"
            return 0
        fi

        python3 -c "
import json
with open('${settings_file}') as f:
    settings = json.load(f)
if 'hooks' not in settings:
    settings['hooks'] = {}
if 'PreToolUse' not in settings['hooks']:
    settings['hooks']['PreToolUse'] = []
settings['hooks']['PreToolUse'].append(json.loads('''${hook_entry}'''))
with open('${settings_file}', 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
"
        printf "${GREEN}+${NC} Updated %s with hook configuration\n" "${settings_file}"
    else
        python3 -c "
import json
settings = {
    'hooks': {
        'PreToolUse': [json.loads('''${hook_entry}''')]
    }
}
with open('${settings_file}', 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
"
        printf "${GREEN}+${NC} Created %s\n" "${settings_file}"
    fi

    printf "\n${GREEN}Safety hook installed!${NC}\n"
    printf "Blocked: git checkout --, git reset --hard, git push --force, rm -rf, etc.\n"
    printf "${YELLOW}Restart Claude Code for the hook to take effect.${NC}\n"

    printf "\nRunning self-test...\n"
    run_test "${install_dir}/hooks/git_safety_guard.py" || true

    return 0
}

uninstall_hook() {
    local install_dir="${HOME}/.claude"

    if [[ -f "${install_dir}/hooks/git_safety_guard.py" ]]; then
        rm -f "${install_dir}/hooks/git_safety_guard.py"
        printf "${GREEN}+${NC} Removed %s/hooks/git_safety_guard.py\n" "${install_dir}"
    else
        printf "${YELLOW}!${NC} No hook found at %s/hooks/git_safety_guard.py\n" "${install_dir}"
    fi

    local settings_file="${install_dir}/settings.json"
    if [[ -f "${settings_file}" ]]; then
        if python3 -c "
import json
with open('${settings_file}') as f:
    settings = json.load(f)
hooks = settings.get('hooks', {})
pre = hooks.get('PreToolUse', [])
new_pre = []
for entry in pre:
    keep = True
    for h in entry.get('hooks', []):
        if 'git_safety_guard' in h.get('command', ''):
            keep = False
    if keep:
        new_pre.append(entry)
if len(new_pre) != len(pre):
    settings['hooks']['PreToolUse'] = new_pre
    if not new_pre:
        del settings['hooks']['PreToolUse']
    if not settings['hooks']:
        del settings['hooks']
    with open('${settings_file}', 'w') as f:
        json.dump(settings, f, indent=2)
        f.write('\n')
    print('removed')
" 2>/dev/null | grep -q "removed"; then
            printf "${GREEN}+${NC} Removed hook from %s\n" "${settings_file}"
        fi
    fi

    printf "\n${GREEN}Safety hook uninstalled.${NC}\n"
    printf "${YELLOW}Restart Claude Code for changes to take effect.${NC}\n"
    return 0
}

main() {
    local mode="global"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --project)
                mode="project"
                shift
                ;;
            --uninstall)
                mode="uninstall"
                shift
                ;;
            --test)
                mode="test"
                shift
                ;;
            --help|-h)
                print_help
                return 0
                ;;
            *)
                printf "${RED}Unknown option: %s${NC}\n" "$1" >&2
                print_help >&2
                return 1
                ;;
        esac
    done

    case "${mode}" in
        global)
            printf "${BLUE}Installing safety hook globally (~/.claude/)...${NC}\n\n"
            install_hook "${HOME}/.claude" \
                "\$HOME/.claude/hooks/git_safety_guard.py"
            ;;
        project)
            printf "${BLUE}Installing safety hook for current project (.claude/)...${NC}\n\n"
            install_hook ".claude" \
                "\$CLAUDE_PROJECT_DIR/.claude/hooks/git_safety_guard.py"
            ;;
        uninstall)
            uninstall_hook
            ;;
        test)
            check_python || return 1
            check_hook_source || return 1
            run_test "${HOOK_SOURCE}"
            ;;
    esac
}

main "$@"
