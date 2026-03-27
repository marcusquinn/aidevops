#!/usr/bin/env bash
# =============================================================================
# Unified Runtime Config Generator
# =============================================================================
# Single entry point for generating agent, command, and MCP configurations
# for all installed AI coding assistant runtimes.
#
# Replaces:
#   - generate-opencode-agents.sh   (924 lines)
#   - generate-claude-agents.sh     (879 lines)
#   - generate-opencode-commands.sh (1,439 lines)
#   - generate-claude-commands.sh   (860 lines)
#
# Architecture:
#   Phase 1: Load shared content definitions (agents, commands, MCPs)
#   Phase 2: For each installed runtime, generate config using adapters
#   Phase 3: Verify output integrity
#
# Dependencies:
#   - runtime-registry.sh (t1665.1) — runtime detection and properties
#   - mcp-config-adapter.sh (t1665.2) — MCP config transforms
#   - prompt-injection-adapter.sh (t1665.3) — system prompt deployment
#
# Usage:
#   generate-runtime-config.sh [subcommand] [options]
#
# Subcommands:
#   all              Generate everything for all installed runtimes (default)
#   agents           Generate agent configs only
#   commands         Generate slash commands only
#   mcp              Register MCP servers only
#   prompts          Deploy system prompts only
#   --verify-parity  Compare output with old generators (regression test)
#   --runtime <id>   Generate for a specific runtime only
#   --dry-run        Show what would be generated without writing
#
# Part of t1665 (Runtime abstraction layer), subtask t1665.4.
# Bash 3.2 compatible.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# Source shared constants for print_info/print_warning/print_success/print_error
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# Source runtime registry for detection and property lookups
# shellcheck source=runtime-registry.sh
source "${SCRIPT_DIR}/runtime-registry.sh"

# Source MCP config adapter (library mode)
# shellcheck source=mcp-config-adapter.sh
source "${SCRIPT_DIR}/mcp-config-adapter.sh"

# Source prompt injection adapter (library mode)
# shellcheck source=prompt-injection-adapter.sh
source "${SCRIPT_DIR}/prompt-injection-adapter.sh"

# =============================================================================
# Constants
# =============================================================================

AGENTS_DIR="${HOME}/.aidevops/agents"

# =============================================================================
# Shared MCP Definitions — defined once, consumed by all runtimes
# =============================================================================
# Universal JSON format: {"command":"...","args":[...],"env":{...}}
# These are registered via mcp-config-adapter.sh for each runtime.

# MCP loading policy categories
# Eager: start at runtime launch (used by all main agents)
# Lazy: start on-demand via subagents (default)

# Helper: get the package runner (bun x or npx)
_get_pkg_runner() {
	local bun_path
	bun_path=$(command -v bun 2>/dev/null || echo "")
	if [[ -n "$bun_path" ]]; then
		echo "bun"
	else
		echo "npx"
	fi
	return 0
}

# =============================================================================
# Phase 1: Shared Content — Agent Definitions
# =============================================================================
# Agent auto-discovery from ~/.aidevops/agents/*.md is handled by the Python
# code in _generate_agents_opencode() and _generate_agents_claude() since it
# requires frontmatter parsing, JSON manipulation, and complex data structures
# that are better suited to Python than bash 3.2.
#
# The Python code is shared via a heredoc function that both runtimes call
# with runtime-specific parameters.

# Generate the shared Python agent discovery code.
# This is the single source of truth for agent definitions, tool assignments,
# model tiers, and MCP loading policy.
# Arguments:
#   $1 - runtime_id (opencode, claude-code)
#   $2 - output format (opencode-json, claude-settings)
_run_agent_discovery_python() {
	local runtime_id="$1"
	local output_format="$2"

	python3 - "$runtime_id" "$output_format" <<'PYEOF'
import json
import os
import glob
import sys

runtime_id = sys.argv[1]
output_format = sys.argv[2]

agents_dir = os.path.expanduser("~/.aidevops/agents")

# =============================================================================
# SHARED CONTENT — Agent definitions (single source of truth)
# =============================================================================

# Agent display name mappings (filename -> display name)
DISPLAY_NAMES = {
    "build-plus": "Build+",
    "seo": "SEO",
    "social-media": "Social-Media",
}

# Agent ordering (agents listed here appear first in this order, rest alphabetical)
AGENT_ORDER = ["Build+", "Automate"]

# Files to skip (not primary agents - includes demoted agents)
SKIP_PRIMARY_AGENTS = {"plan-plus.md", "aidevops.md", "browser-extension-dev.md", "mobile-app-dev.md"}

# Special tool configurations per agent (by display name)
# These are MCP tools that specific agents need access to
AGENT_TOOLS = {
    "Build+": {
        "write": True, "edit": True, "bash": True, "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True, "todoread": True, "todowrite": True,
        "openapi-search_*": True
    },
    "Onboarding": {
        "write": True, "edit": True, "bash": True,
        "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True
    },
    "Accounts": {
        "write": True, "edit": True, "bash": True,
        "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True, "quickfile_*": True
    },
    "Social-Media": {
        "write": True, "edit": True, "bash": True,
        "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True
    },
    "SEO": {
        "write": True, "read": True, "bash": True, "webfetch": True,
        "gsc_*": True, "ahrefs_*": True, "dataforseo_*": True
    },
    "WordPress": {
        "write": True, "edit": True, "bash": True,
        "read": True, "glob": True, "grep": True,
        "localwp_*": True
    },
    "Content": {
        "write": True, "edit": True, "read": True, "webfetch": True
    },
    "Research": {
        "read": True, "webfetch": True, "bash": True,
        "openapi-search_*": True
    },
    "Automate": {
        "bash": True, "read": True, "glob": True, "grep": True,
        "task": True, "todoread": True, "todowrite": True
    },
}

# Default tools for agents not in AGENT_TOOLS
DEFAULT_TOOLS = {
    "write": True, "edit": True, "bash": True, "read": True, "glob": True, "grep": True,
    "webfetch": True, "task": True
}

# Temperature settings (by display name, default 0.2)
AGENT_TEMPS = {
    "Build+": 0.2,
    "Automate": 0.1,
    "Accounts": 0.1,
    "Legal": 0.1,
    "Content": 0.3,
    "Marketing": 0.3,
    "Research": 0.3,
}

# Custom system prompt path
DEFAULT_PROMPT = "~/.aidevops/agents/prompts/build.txt"

# Agents that should NOT use the custom prompt (empty by default)
SKIP_CUSTOM_PROMPT = set()

# Model routing tiers
MODEL_TIERS = {
    "haiku": "anthropic/claude-haiku-4-5",
    "sonnet": "anthropic/claude-sonnet-4-6",
    "opus": "anthropic/claude-opus-4-6",
    "flash": "google/gemini-3-flash-preview",
    "pro": "google/gemini-3-pro-preview",
}

# Default model tier per agent (overridden by frontmatter 'model:' field)
AGENT_MODEL_TIERS = {}

# Files to skip (not primary agents)
SKIP_FILES = {"AGENTS.md", "README.md", "SKILL-SCAN-RESULTS.md"} | SKIP_PRIMARY_AGENTS

# MCP loading policy
EAGER_MCPS = set()
LAZY_MCPS = {
    'MCP_DOCKER', 'ahrefs', 'amazon-order-history', 'augment-context-engine',
    'chrome-devtools', 'claude-code-mcp', 'context7', 'dataforseo', 'gh_grep',
    'google-analytics-mcp', 'grep_app', 'gsc', 'ios-simulator', 'localwp',
    'macos-automator', 'openapi-search', 'outscraper', 'playwriter', 'quickfile',
    'sentry', 'shadcn', 'socket', 'websearch',
}

# =============================================================================
# SHARED FUNCTIONS
# =============================================================================

def parse_frontmatter(filepath):
    """Parse YAML frontmatter from markdown file.

    Minimal parser — no PyYAML dependency. Supports:
      - Simple key: value pairs (unquoted, single-line)
      - Dash-prefixed list items (single level)
    Does NOT support: quoted values containing colons, multi-line blocks,
    or nested mappings. Agent frontmatter must stay within these constraints.
    """
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
        if not content.startswith('---'):
            return {}
        end_idx = content.find('---', 3)
        if end_idx == -1:
            return {}
        frontmatter = content[3:end_idx].strip()
        result = {}
        lines = frontmatter.split('\n')
        current_key = None
        current_list = []
        for line in lines:
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                continue
            if stripped.startswith('- ') and current_key:
                current_list.append(stripped[2:].strip())
            elif ':' in stripped and not stripped.startswith('-'):
                if current_key and current_list:
                    result[current_key] = current_list
                    current_list = []
                key, value = stripped.split(':', 1)
                current_key = key.strip()
                value = value.strip()
                if value:
                    result[current_key] = value
                    current_key = None
        if current_key and current_list:
            result[current_key] = current_list
        return result
    except (IOError, OSError, UnicodeDecodeError) as e:
        print(f"Warning: Failed to parse frontmatter for {filepath}: {e}", file=sys.stderr)
        return {}

def filename_to_display(filename):
    """Convert filename to display name."""
    name = filename.replace(".md", "")
    if name in DISPLAY_NAMES:
        return DISPLAY_NAMES[name]
    return "-".join(word.capitalize() for word in name.split("-"))

def get_agent_config(display_name, filename, subagents=None, model_tier=None):
    """Generate agent configuration."""
    tools = AGENT_TOOLS.get(display_name, DEFAULT_TOOLS.copy())
    temp = AGENT_TEMPS.get(display_name, 0.2)
    config = {
        "description": f"Read ~/.aidevops/agents/{filename}",
        "mode": "primary",
        "temperature": temp,
        "permission": {},
        "tools": tools
    }
    if display_name not in SKIP_CUSTOM_PROMPT:
        prompt_file = os.path.expanduser(DEFAULT_PROMPT)
        if os.path.exists(prompt_file):
            config["prompt"] = "{file:" + DEFAULT_PROMPT + "}"
    effective_tier = model_tier or AGENT_MODEL_TIERS.get(display_name)
    if effective_tier and effective_tier in MODEL_TIERS:
        config["model"] = MODEL_TIERS[effective_tier]
    config["permission"] = {"external_directory": "allow"}
    if subagents and isinstance(subagents, list) and len(subagents) > 0:
        task_perms = {"*": "deny"}
        for subagent in subagents:
            task_perms[subagent] = "allow"
        config["permission"]["task"] = task_perms
    return config

# =============================================================================
# DISCOVER PRIMARY AGENTS
# =============================================================================

primary_agents = {}
discovered = []
subagent_filtered_count = 0

for filepath in glob.glob(os.path.join(agents_dir, "*.md")):
    filename = os.path.basename(filepath)
    if filename in SKIP_FILES:
        continue
    display_name = filename_to_display(filename)
    frontmatter = parse_frontmatter(filepath)
    subagents = frontmatter.get('subagents', None)
    model_tier = frontmatter.get('model', None)
    if not isinstance(subagents, (list, type(None))):
        subagents = None
    if subagents:
        subagent_filtered_count += 1
    primary_agents[display_name] = get_agent_config(display_name, filename, subagents, model_tier)
    discovered.append(display_name)

# Sort agents: ordered ones first, then alphabetical
def sort_key(name):
    if name in AGENT_ORDER:
        return (0, AGENT_ORDER.index(name))
    return (1, name.lower())

sorted_agents = dict(sorted(primary_agents.items(), key=lambda x: sort_key(x[0])))

# =============================================================================
# OUTPUT — Runtime-specific
# =============================================================================

if output_format == "opencode-json":
    # OpenCode: write agent config to opencode.json
    import shutil
    import platform

    config_path = os.path.expanduser("~/.config/opencode/opencode.json")
    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            config = json.load(f)
    except FileNotFoundError:
        config = {"$schema": "https://opencode.ai/config.json"}
    except (OSError, json.JSONDecodeError) as e:
        print(f"Error: Failed to load {config_path}: {e}", file=sys.stderr)
        sys.exit(1)

    # Disable default and demoted agents
    sorted_agents["build"] = {"disable": True}
    sorted_agents["plan"] = {"disable": True}
    sorted_agents["Plan+"] = {"disable": True}
    sorted_agents["AI-DevOps"] = {"disable": True}
    sorted_agents["Browser-Extension-Dev"] = {"disable": True}
    sorted_agents["Mobile-App-Dev"] = {"disable": True}

    config['agent'] = sorted_agents
    config['default_agent'] = "Build+"

    # Instructions — merge into existing list to preserve user-added entries
    instructions_path = os.path.expanduser("~/.aidevops/agents/AGENTS.md")
    if os.path.exists(instructions_path):
        existing = config.get('instructions', [])
        if not isinstance(existing, list):
            existing = [existing] if existing else []
        if instructions_path not in existing:
            existing.append(instructions_path)
        config['instructions'] = existing

    # Provider options — prompt caching
    if 'provider' not in config:
        config['provider'] = {}
    if 'anthropic' not in config['provider']:
        config['provider']['anthropic'] = {}
    if 'options' not in config['provider']['anthropic']:
        config['provider']['anthropic']['options'] = {}
    config['provider']['anthropic']['options']['setCacheKey'] = True

    # MCP loading policy
    if 'mcp' not in config:
        config['mcp'] = {}
    if 'tools' not in config:
        config['tools'] = {}

    bun_path = shutil.which('bun')
    npx_path = shutil.which('npx')
    pkg_runner = f"{bun_path} x" if bun_path else (npx_path or "npx")

    # Apply loading policy to existing MCPs
    for mcp_name in list(config.get('mcp', {}).keys()):
        mcp_cfg = config['mcp'].get(mcp_name, {})
        if not isinstance(mcp_cfg, dict):
            continue
        if mcp_name in EAGER_MCPS:
            mcp_cfg['enabled'] = True
        elif mcp_name in LAZY_MCPS:
            mcp_cfg['enabled'] = False

    # Remove deprecated MCPs
    if 'osgrep' in config.get('mcp', {}):
        del config['mcp']['osgrep']
    if 'osgrep_*' in config.get('tools', {}):
        del config['tools']['osgrep_*']

    # Playwriter MCP
    if 'playwriter' not in config['mcp']:
        runner = "bun" if bun_path else "npx"
        config['mcp']['playwriter'] = {
            "type": "local",
            "command": [runner, "x" if runner == "bun" else "", "playwriter@latest"] if runner == "bun" else [runner, "playwriter@latest"],
            "enabled": True
        }
        # Fix: ensure clean command array
        config['mcp']['playwriter']['command'] = [x for x in config['mcp']['playwriter']['command'] if x]
    config['tools']['playwriter_*'] = True

    # Outscraper MCP
    if 'outscraper' not in config['mcp']:
        config['mcp']['outscraper'] = {
            "type": "local",
            "command": ["/bin/bash", "-c", "OUTSCRAPER_API_KEY=$OUTSCRAPER_API_KEY uv tool run outscraper-mcp-server"],
            "enabled": False
        }
    if 'outscraper_*' not in config['tools']:
        config['tools']['outscraper_*'] = False

    # DataForSEO MCP
    if 'dataforseo' not in config['mcp']:
        config['mcp']['dataforseo'] = {
            "type": "local",
            "command": ["/bin/bash", "-c", f"source ~/.config/aidevops/credentials.sh && DATAFORSEO_USERNAME=$DATAFORSEO_USERNAME DATAFORSEO_PASSWORD=$DATAFORSEO_PASSWORD {pkg_runner} dataforseo-mcp-server"],
            "enabled": False
        }
    if 'dataforseo_*' not in config['tools']:
        config['tools']['dataforseo_*'] = False

    # shadcn MCP
    if 'shadcn' not in config['mcp']:
        config['mcp']['shadcn'] = {
            "type": "local",
            "command": ["npx", "shadcn@latest", "mcp"],
            "enabled": False
        }
    if 'shadcn_*' not in config['tools']:
        config['tools']['shadcn_*'] = False

    # Claude Code MCP (always overwrite to ensure correct fork)
    config['mcp']['claude-code-mcp'] = {
        "type": "local",
        "command": ["npx", "-y", "github:marcusquinn/claude-code-mcp"],
        "enabled": False
    }
    config['tools']['claude-code-mcp_*'] = False

    # macOS-only MCPs
    if platform.system() == 'Darwin':
        if 'macos-automator' not in config['mcp']:
            config['mcp']['macos-automator'] = {
                "type": "local",
                "command": ["npx", "-y", "@steipete/macos-automator-mcp@0.2.0"],
                "enabled": False
            }
        if 'macos-automator_*' not in config['tools']:
            config['tools']['macos-automator_*'] = False

        if 'ios-simulator' not in config['mcp']:
            config['mcp']['ios-simulator'] = {
                "type": "local",
                "command": ["npx", "-y", "ios-simulator-mcp"],
                "enabled": False
            }
        if 'ios-simulator_*' not in config['tools']:
            config['tools']['ios-simulator_*'] = False

    # OpenAPI Search MCP
    if 'openapi-search' not in config['mcp']:
        config['mcp']['openapi-search'] = {
            "type": "remote",
            "url": "https://openapi-mcp.openapisearch.com/mcp",
            "enabled": False
        }
    if 'openapi-search_*' not in config['tools']:
        config['tools']['openapi-search_*'] = False

    # Disable OmO tool patterns globally
    for tool_pattern in ['grep_app_*', 'websearch_*', 'gh_grep_*']:
        if config['tools'].get(tool_pattern) is not False:
            config['tools'][tool_pattern] = False

    with open(config_path, 'w', encoding='utf-8') as f:
        json.dump(config, f, indent=2)

    print(f"  Updated {len(primary_agents)} primary agents in opencode.json")
    if subagent_filtered_count > 0:
        print(f"  Subagent filtering: {subagent_filtered_count} agents have permission.task rules")
    prompt_count = sum(1 for name, cfg in sorted_agents.items() if "prompt" in cfg)
    if prompt_count > 0:
        print(f"  Custom system prompts: {prompt_count} agents use prompts/build.txt")

elif output_format == "claude-settings":
    # Claude Code: update settings.json (hooks, permissions)
    settings_path = os.path.expanduser("~/.claude/settings.json")
    try:
        with open(settings_path, 'r') as f:
            settings = json.load(f)
    except (json.JSONDecodeError, FileNotFoundError):
        settings = {}

    changed = False

    # Safety hooks: PreToolUse for Bash
    hook_command = "$HOME/.aidevops/hooks/git_safety_guard.py"
    hook_entry = {"type": "command", "command": hook_command}
    bash_matcher = {"matcher": "Bash", "hooks": [hook_entry]}

    if "hooks" not in settings:
        settings["hooks"] = {}
    if "PreToolUse" not in settings["hooks"]:
        settings["hooks"]["PreToolUse"] = []

    has_bash_hook = False
    for rule in settings["hooks"]["PreToolUse"]:
        if rule.get("matcher") == "Bash":
            existing_commands = [h.get("command", "") for h in rule.get("hooks", [])]
            if hook_command not in existing_commands:
                rule.setdefault("hooks", []).append(hook_entry)
                changed = True
            has_bash_hook = True
            break
    if not has_bash_hook:
        settings["hooks"]["PreToolUse"].append(bash_matcher)
        changed = True

    # Tool permissions
    permissions = settings.setdefault("permissions", {})

    allow_rules = [
        "Read(~/.aidevops/**)", "Bash(~/.aidevops/agents/scripts/*)",
        "Bash(git status)", "Bash(git status *)", "Bash(git log *)",
        "Bash(git diff *)", "Bash(git diff)", "Bash(git branch *)",
        "Bash(git branch)", "Bash(git show *)", "Bash(git rev-parse *)",
        "Bash(git ls-files *)", "Bash(git ls-files)", "Bash(git remote -v)",
        "Bash(git stash list)", "Bash(git tag *)", "Bash(git tag)",
        "Bash(git add *)", "Bash(git add .)", "Bash(git commit *)",
        "Bash(git checkout -b *)", "Bash(git switch -c *)", "Bash(git switch *)",
        "Bash(git push *)", "Bash(git push)", "Bash(git pull *)", "Bash(git pull)",
        "Bash(git fetch *)", "Bash(git fetch)", "Bash(git merge *)",
        "Bash(git rebase *)", "Bash(git stash *)", "Bash(git worktree *)",
        "Bash(git branch -d *)", "Bash(git push --force-with-lease *)",
        "Bash(git push --force-if-includes *)",
        "Bash(gh pr *)", "Bash(gh issue *)", "Bash(gh run *)", "Bash(gh api *)",
        "Bash(gh repo *)", "Bash(gh auth status *)", "Bash(gh auth status)",
        "Bash(npm run *)", "Bash(npm test *)", "Bash(npm test)",
        "Bash(npm install *)", "Bash(npm install)", "Bash(npm ci)",
        "Bash(npx *)", "Bash(bun *)", "Bash(pnpm *)", "Bash(yarn *)",
        "Bash(node *)", "Bash(python3 *)", "Bash(python *)", "Bash(pip *)",
        "Bash(fd *)", "Bash(rg *)", "Bash(find *)", "Bash(grep *)",
        "Bash(wc *)", "Bash(ls *)", "Bash(ls)", "Bash(tree *)",
        "Bash(shellcheck *)", "Bash(eslint *)", "Bash(prettier *)", "Bash(tsc *)",
        "Bash(which *)", "Bash(command -v *)", "Bash(uname *)", "Bash(date *)",
        "Bash(pwd)", "Bash(whoami)", "Bash(cat *)", "Bash(head *)", "Bash(tail *)",
        "Bash(sort *)", "Bash(uniq *)", "Bash(cut *)", "Bash(awk *)", "Bash(sed *)",
        "Bash(jq *)", "Bash(basename *)", "Bash(dirname *)", "Bash(realpath *)",
        "Bash(readlink *)", "Bash(stat *)", "Bash(file *)", "Bash(diff *)",
        "Bash(mkdir *)", "Bash(touch *)", "Bash(cp *)", "Bash(mv *)",
        "Bash(chmod *)", "Bash(echo *)", "Bash(printf *)", "Bash(test *)",
        "Bash([ *)", "Bash(claude *)",
    ]

    deny_rules = [
        "Read(./.env)", "Read(./.env.*)", "Read(./secrets/**)",
        "Read(./**/credentials.json)", "Read(./**/.env)", "Read(./**/.env.*)",
        "Read(~/.config/aidevops/credentials.sh)",
        "Bash(git push --force *)", "Bash(git push -f *)",
        "Bash(git reset --hard *)", "Bash(git reset --hard)",
        "Bash(git clean -f *)", "Bash(git clean -f)",
        "Bash(git checkout -- *)", "Bash(git branch -D *)",
        "Bash(rm -rf /)", "Bash(rm -rf /*)", "Bash(rm -rf ~)",
        "Bash(rm -rf ~/*)", "Bash(sudo *)", "Bash(chmod 777 *)",
        "Bash(gopass show *)", "Bash(pass show *)", "Bash(op read *)",
        "Bash(cat ~/.config/aidevops/credentials.sh)",
    ]

    ask_rules = [
        "Bash(rm -rf *)", "Bash(rm -r *)",
        "Bash(curl *)", "Bash(wget *)",
        "Bash(docker *)", "Bash(docker-compose *)", "Bash(orbctl *)",
    ]

    def merge_rules(existing, new_rules):
        added = False
        for rule in new_rules:
            if rule not in existing:
                existing.append(rule)
                added = True
        return added

    # Clean up expanded-path rules from prior versions
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

    if "$schema" not in settings:
        settings["$schema"] = "https://json.schemastore.org/claude-code-settings.json"
        changed = True

    if changed:
        os.makedirs(os.path.dirname(settings_path), exist_ok=True)
        with open(settings_path, 'w') as f:
            json.dump(settings, f, indent=2)
            f.write('\n')
        print(f"  Updated {settings_path}")
    else:
        print(f"  {settings_path} (no changes needed)")

    # Output agent count for the caller
    print(f"  Discovered {len(primary_agents)} primary agents")

else:
    print(f"Unknown output format: {output_format}", file=sys.stderr)
    sys.exit(1)
PYEOF
	return $?
}

# =============================================================================
# Phase 2a: Agent Generation — Per-Runtime Adapters
# =============================================================================

_generate_agents_opencode() {
	print_info "Generating OpenCode agent configuration..."

	local opencode_config_dir="$HOME/.config/opencode"
	local opencode_agent_dir="$opencode_config_dir/agent"
	local opencode_config="$opencode_config_dir/opencode.json"

	mkdir -p "$opencode_agent_dir"

	# Deploy AGENTS.md with version check
	cat >"$opencode_config_dir/AGENTS.md" <<'AGENTSEOF'
Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities.

## aidevops Framework Status

**On interactive conversation start** (skip this section entirely for headless/command sessions like `/pulse`, `/full-loop`, etc.):
1. If you have Bash tool: Run `bash ~/.aidevops/agents/scripts/aidevops-update-check.sh --interactive`
2. If no Bash tool: Read `~/.aidevops/cache/session-greeting.txt` (cached by agents with Bash) and greet with: "Hi!\n\n{content of file}.\n\nWhat would you like to work on?". If the file doesn't exist, read `~/.aidevops/agents/VERSION` to get the `{version}` and greet with: "Hi!\n\nWe're running https://aidevops.sh v{version}.\n\nWhat would you like to work on?"
3. Then respond to the user's actual message

If you ran the update check script (step 1) and the output starts with `UPDATE_AVAILABLE|` (e.g., `UPDATE_AVAILABLE|2.41.1|2.41.2|OpenCode`), inform user: "Update available (current → latest). Run `aidevops update` in a terminal session to update, or type `!aidevops update` below and hit Enter." This check does not apply when falling back to reading the cache or VERSION file (step 2).

## Pre-Edit Git Check

Only for agents with Edit/Write/Bash tools. See ~/.aidevops/agents/AGENTS.md for workflow.
AGENTSEOF
	print_success "Updated AGENTS.md with version check"

	# Remove legacy agent files
	local legacy_files=(
		"Accounts.md" "Accounting.md" "accounting.md" "AI-DevOps.md" "Build+.md" "Content.md"
		"Health.md" "Legal.md" "Marketing.md" "Research.md" "Sales.md" "SEO.md" "WordPress.md"
		"Plan+.md" "Build-Agent.md" "Build-MCP.md" "build-agent.md" "build-mcp.md"
		"plan-plus.md" "aidevops.md" "Browser-Extension-Dev.md" "Mobile-App-Dev.md" "AGENTS.md"
	)
	local f
	for f in "${legacy_files[@]}"; do
		rm -f "$opencode_agent_dir/$f"
	done

	# Remove loop-state files incorrectly created as agents
	for f in ralph-loop.local.md quality-loop.local.md full-loop.local.md loop-state.md re-anchor.md postflight-loop.md; do
		rm -f "$opencode_agent_dir/$f"
	done

	# Create minimal config if missing
	if [[ ! -f "$opencode_config" ]]; then
		print_warning "$opencode_config not found. Creating minimal config."
		# shellcheck disable=SC2016
		echo '{"$schema": "https://opencode.ai/config.json"}' >"$opencode_config"
	fi

	# Run shared Python agent discovery for OpenCode
	_run_agent_discovery_python "opencode" "opencode-json"

	print_success "Primary agents configured in opencode.json"

	# Generate subagent markdown files
	_generate_subagents_opencode "$opencode_agent_dir"

	# Sync MCP tool index
	local mcp_index_helper="$AGENTS_DIR/scripts/mcp-index-helper.sh"
	if [[ -x "$mcp_index_helper" ]]; then
		if "$mcp_index_helper" sync 2>/dev/null; then
			print_success "MCP tool index updated"
		else
			print_warning "MCP index sync skipped (non-critical)"
		fi
	fi

	return 0
}

# Determine additional MCP tools for a subagent based on its name.
# Arguments: $1 - subagent name (basename without .md)
# Outputs: extra tool lines to stdout (empty if none)
_get_subagent_extra_tools() {
	local name="$1"

	case "$name" in
	outscraper)
		printf '%s\n' '  outscraper_*: true' '  webfetch: true'
		;;
	mainwp | localwp)
		printf '%s\n' '  localwp_*: true'
		;;
	quickfile)
		printf '%s\n' '  quickfile_*: true'
		;;
	google-search-console)
		printf '%s\n' '  gsc_*: true'
		;;
	dataforseo)
		printf '%s\n' '  dataforseo_*: true' '  webfetch: true'
		;;
	claude-code)
		printf '%s\n' '  claude-code-mcp_*: true'
		;;
	openapi-search)
		printf '%s\n' '  openapi-search_*: true' '  webfetch: true'
		;;
	aidevops)
		printf '%s\n' '  openapi-search_*: true'
		;;
	playwriter)
		printf '%s\n' '  playwriter_*: true'
		;;
	shadcn)
		printf '%s\n' '  shadcn_*: true' '  write: true' '  edit: true'
		;;
	macos-automator | mac)
		if [[ "$(uname -s)" == "Darwin" ]]; then
			printf '%s\n' '  macos-automator_*: true' '  webfetch: true'
		fi
		;;
	ios-simulator-mcp)
		if [[ "$(uname -s)" == "Darwin" ]]; then
			printf '%s\n' '  ios-simulator_*: true'
		fi
		;;
	*) ;;
	esac
	return 0
}

# Write a single subagent markdown stub file.
# Arguments: $1 - source .md file path
# Requires: AGENTS_DIR and agent_dir to be set (exported for xargs usage)
# Outputs: "1" to stdout on success (for counting)
_write_subagent_stub() {
	local f="$1"
	local name
	name=$(basename "$f" .md)
	[[ "$name" == "AGENTS" || "$name" == "README" ]] && return 0

	local rel_path="${f#"$AGENTS_DIR"/}"

	# Extract description from source file frontmatter
	local src_desc
	src_desc=$(sed -n '/^---$/,/^---$/{ /^description:/{s/^description: *//p; q} }' "$f" 2>/dev/null)
	if [[ -z "$src_desc" ]]; then
		src_desc="Read ~/.aidevops/agents/${rel_path}"
	fi

	local extra_tools
	extra_tools=$(_get_subagent_extra_tools "$name")

	{
		printf '%s\n' \
			"---" \
			"description: ${src_desc}" \
			"mode: subagent" \
			"temperature: 0.2" \
			"permission:" \
			"  external_directory: allow" \
			"tools:" \
			"  read: true" \
			"  bash: true"
		[[ -n "$extra_tools" ]] && printf '%s\n' "$extra_tools"
		printf '%s\n' \
			"---" \
			"" \
			"**MANDATORY**: Your first action MUST be to read ~/.aidevops/agents/${rel_path} and follow ALL rules within it."
	} >"$agent_dir/$name.md"
	echo 1
	return 0
}

# Remove previously generated subagent files (those with "mode: subagent" frontmatter).
# Arguments: $1 - agent output directory
_clean_generated_subagents() {
	local agent_dir="$1"
	find "$agent_dir" -name "*.md" -type f -exec grep -l "^mode: subagent" {} + 2>/dev/null | while IFS= read -r f; do rm -f "$f"; done
	return 0
}

# Generate subagent markdown stubs for OpenCode
_generate_subagents_opencode() {
	local agent_dir="$1"

	print_info "Generating subagent markdown files..."

	_clean_generated_subagents "$agent_dir"

	export -f _get_subagent_extra_tools 2>/dev/null || true
	export -f _write_subagent_stub 2>/dev/null || true
	export AGENTS_DIR
	export agent_dir

	local _ncpu
	_ncpu=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
	local _parallel_jobs=$((_ncpu > 4 ? _ncpu : 4))
	local subagent_count
	subagent_count=$(find "$AGENTS_DIR" -mindepth 2 -name "*.md" -type f -not -path "*/loop-state/*" -not -name "*-skill.md" -print0 |
		xargs -0 -P "$_parallel_jobs" -I {} bash -c '_write_subagent_stub "$@"' _ {} |
		awk '{sum+=$1} END {print sum+0}')

	print_success "Generated $subagent_count subagent files"
	return 0
}

_generate_agents_claude() {
	print_info "Generating Claude Code agent configuration..."

	local claude_settings="$HOME/.claude/settings.json"

	# Ensure directory exists
	mkdir -p "$(dirname "$claude_settings")"

	# Create minimal settings if missing
	if [[ ! -f "$claude_settings" ]]; then
		echo '{}' >"$claude_settings"
		chmod 600 "$claude_settings"
		print_success "Created $claude_settings"
	fi

	# Run shared Python agent discovery for Claude Code
	_run_agent_discovery_python "claude-code" "claude-settings"

	print_success "Claude Code settings updated"
	return 0
}

# =============================================================================
# Phase 2b: Command Generation — Per-Runtime Adapters
# =============================================================================

# Shared command definitions — the body content is defined once here.
# Each runtime adapter writes these to its command directory with the
# appropriate frontmatter format.

# Helper: write a command file for OpenCode format
_write_opencode_command() {
	local cmd_dir="$1"
	local name="$2"
	local description="$3"
	local agent="$4"
	local subtask="$5"
	local body="$6"

	{
		echo "---"
		echo "description: ${description}"
		[[ -n "$agent" ]] && echo "agent: ${agent}"
		[[ "$subtask" == "true" ]] && echo "subtask: true"
		echo "---"
		echo ""
		echo "$body"
	} >"${cmd_dir}/${name}.md"
	return 0
}

# Helper: write a command file for Claude Code format
_write_claude_command() {
	local cmd_dir="$1"
	local name="$2"
	local description="$3"
	# Claude Code doesn't use agent/subtask fields
	local body="$4"

	cat >"${cmd_dir}/${name}.md" <<EOF
---
description: $description
---

$body
EOF
	return 0
}

# Generate all shared commands for a given runtime
# Arguments: $1=runtime_id
_generate_commands_for_runtime() {
	local runtime_id="$1"
	local cmd_dir
	cmd_dir=$(rt_command_dir "$runtime_id") || cmd_dir=""

	if [[ -z "$cmd_dir" ]]; then
		print_info "No command directory for $runtime_id — skipping commands"
		return 0
	fi

	mkdir -p "$cmd_dir"

	local command_count=0
	local display_name
	display_name=$(rt_display_name "$runtime_id") || display_name="$runtime_id"

	print_info "Generating $display_name commands..."

	# Auto-discover commands from scripts/commands/*.md
	local commands_src_dir="$HOME/.aidevops/agents/scripts/commands"

	if [[ -d "$commands_src_dir" ]]; then
		local cmd_file
		for cmd_file in "$commands_src_dir"/*.md; do
			[[ -f "$cmd_file" ]] || continue

			local cmd_name
			cmd_name=$(basename "$cmd_file" .md)

			# Skip non-commands
			[[ "$cmd_name" == "SKILL" ]] && continue

			case "$runtime_id" in
			opencode)
				# Copy as-is (OpenCode format already)
				cp "$cmd_file" "${cmd_dir}/${cmd_name}.md"
				;;
			claude-code)
				# Strip OpenCode-specific frontmatter fields (agent, subtask, mode)
				sed -E '/^---$/,/^---$/{/^(agent|subtask|mode):/d;}' "$cmd_file" \
					>"${cmd_dir}/${cmd_name}.md"
				;;
			*)
				# Generic: copy as-is
				cp "$cmd_file" "${cmd_dir}/${cmd_name}.md"
				;;
			esac

			command_count=$((command_count + 1))
		done
	fi

	# Generate hardcoded commands that aren't in scripts/commands/
	# These are runtime-specific commands that have inline body content
	_generate_hardcoded_commands "$runtime_id" "$cmd_dir"
	local hc_count=$?
	command_count=$((command_count + hc_count))

	print_success "$display_name: $command_count commands in $cmd_dir"
	return 0
}

# Write a hardcoded command if not already present from auto-discovery.
# Writes using the appropriate format for the given runtime.
# Arguments:
#   $1 - runtime_id
#   $2 - cmd_dir
#   $3 - command name
#   $4 - description
#   $5 - body content
# Returns: 0 if written, 1 if skipped (already exists)
_maybe_write_hardcoded_command() {
	local runtime_id="$1"
	local cmd_dir="$2"
	local name="$3"
	local description="$4"
	local body="$5"

	# Skip if already exists from auto-discovery
	[[ -f "${cmd_dir}/${name}.md" ]] && return 1

	case "$runtime_id" in
	opencode)
		_write_opencode_command "$cmd_dir" "$name" "$description" "Build+" "true" "$body"
		;;
	*)
		_write_claude_command "$cmd_dir" "$name" "$description" "$body"
		;;
	esac
	return 0
}

# Generate quality/review hardcoded commands (agent-review, preflight, postflight).
# Arguments: $1 - runtime_id, $2 - cmd_dir
# Returns: count of generated commands via exit code
_generate_hardcoded_quality_commands() {
	local runtime_id="$1"
	local cmd_dir="$2"
	local count=0

	# --- Agent Review ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "agent-review" \
		"Systematic review and improvement of agent instructions" \
		'Read ~/.aidevops/agents/tools/build-agent/agent-review.md and follow its instructions.

Review the agent file(s) specified: $ARGUMENTS

If no specific file is provided, review the agents used in this session and propose improvements based on:
1. Any corrections the user made
2. Any commands or paths that failed
3. Instruction count (target <50 for main, <100 for subagents)
4. Universal applicability (>80% of tasks)
5. Duplicate detection across agents

Follow the improvement proposal format from the agent-review instructions.'; then
		count=$((count + 1))
	fi

	# --- Preflight ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "preflight" \
		"Run quality checks before version bump and release" \
		'Read ~/.aidevops/agents/workflows/preflight.md and follow its instructions.

Run preflight checks for: $ARGUMENTS

This includes:
1. Code quality checks (ShellCheck, SonarCloud, secrets scan)
2. Markdown formatting validation
3. Version consistency verification
4. Git status check (clean working tree)'; then
		count=$((count + 1))
	fi

	# --- Postflight ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "postflight" \
		"Check code audit feedback on latest push (branch or PR)" \
		'Check code audit tool feedback on the latest push.

Target: $ARGUMENTS

**Auto-detection:**
1. If on a feature branch with open PR -> check that PR'\''s feedback
2. If on a feature branch without PR -> check branch CI status
3. If on main -> check latest commit'\''s CI/audit status

**Checks performed:**
1. GitHub Actions workflow status (pass/fail/pending)
2. CodeRabbit comments and suggestions
3. Codacy analysis results
4. SonarCloud quality gate status

Report findings and recommend next actions (fix issues, merge, etc.)'; then
		count=$((count + 1))
	fi

	return "$count"
}

# Generate lifecycle hardcoded commands (release, onboarding, setup-aidevops).
# Arguments: $1 - runtime_id, $2 - cmd_dir
# Returns: count of generated commands via exit code
_generate_hardcoded_lifecycle_commands() {
	local runtime_id="$1"
	local cmd_dir="$2"
	local count=0

	# --- Release ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "release" \
		"Full release workflow with version bump, tag, and GitHub release" \
		'Execute a release for the current repository.

Release type: $ARGUMENTS (valid: major, minor, patch)

**Steps:**
1. Run `git log v$(cat VERSION 2>/dev/null || echo "0.0.0")..HEAD --oneline` to see commits since last release
2. If no release type provided, determine it from commits
3. Run the single release command:
   ```bash
   .agents/scripts/version-manager.sh release [type] --skip-preflight --force
   ```
4. Report the result with the GitHub release URL'; then
		count=$((count + 1))
	fi

	# --- Onboarding ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "onboarding" \
		"Interactive onboarding wizard - discover services, configure integrations" \
		'Read ${AIDEVOPS_HOME:-$HOME/.aidevops}/agents/onboarding.md and follow its Welcome Flow instructions to guide the user through setup. Do NOT repeat these instructions — go straight to the Welcome Flow conversation.

Arguments: $ARGUMENTS'; then
		count=$((count + 1))
	fi

	# --- Setup ---
	# shellcheck disable=SC2016
	if _maybe_write_hardcoded_command "$runtime_id" "$cmd_dir" "setup-aidevops" \
		"Deploy latest aidevops agent changes locally" \
		'Run the aidevops setup script to deploy the latest changes.

```bash
AIDEVOPS_REPO="${AIDEVOPS_REPO:-$(jq -r ".initialized_repos[]?.path | select(test(\"/aidevops$\"))" ~/.config/aidevops/repos.json 2>/dev/null | head -n 1)}"
if [[ -z "$AIDEVOPS_REPO" ]]; then
  AIDEVOPS_REPO="$HOME/Git/aidevops"
fi
[[ -f "$AIDEVOPS_REPO/setup.sh" ]] || {
  echo "Unable to find setup.sh. Set AIDEVOPS_REPO to your aidevops clone path." >&2
  exit 1
}
cd "$AIDEVOPS_REPO" && ./setup.sh || exit
```

This deploys agents, updates commands, regenerates configs.
Arguments: $ARGUMENTS'; then
		count=$((count + 1))
	fi

	return "$count"
}

# Generate hardcoded commands not in scripts/commands/
# Returns the count of generated commands via exit code (max 255)
_generate_hardcoded_commands() {
	local runtime_id="$1"
	local cmd_dir="$2"
	local count=0

	_generate_hardcoded_quality_commands "$runtime_id" "$cmd_dir"
	count=$((count + $?))

	_generate_hardcoded_lifecycle_commands "$runtime_id" "$cmd_dir"
	count=$((count + $?))

	return "$count"
}

# =============================================================================
# Phase 2c: MCP Registration — Per-Runtime
# =============================================================================

_generate_mcp_for_runtime() {
	local runtime_id="$1"
	local display_name
	display_name=$(rt_display_name "$runtime_id") || display_name="$runtime_id"

	print_info "Registering MCP servers for $display_name..."

	local mcp_count=0

	# Shared MCP definitions — defined once, registered for each runtime
	# Format: register_mcp_for_runtime <runtime_id> <name> '<json>'

	# Augment Context Engine (requires auggie binary AND active auth session)
	local auggie_path
	auggie_path=$(command -v auggie 2>/dev/null || echo "")
	if [[ -n "$auggie_path" && -f "$HOME/.augment/session.json" ]]; then
		register_mcp_for_runtime "$runtime_id" "auggie-mcp" \
			"{\"command\":\"$auggie_path\",\"args\":[\"--mcp\"]}"
		mcp_count=$((mcp_count + 1))
	elif [[ -n "$auggie_path" ]]; then
		print_warning "Skipping auggie-mcp: binary found but not logged in (run: auggie login)"
	fi

	# context7 (library docs — remote endpoint, zero install)
	register_mcp_for_runtime "$runtime_id" "context7" \
		'{"url":"https://mcp.context7.com/mcp"}'
	mcp_count=$((mcp_count + 1))

	# Playwright MCP (correct package: @playwright/mcp, not @anthropic-ai/mcp-server-playwright)
	register_mcp_for_runtime "$runtime_id" "playwright" \
		'{"command":"npx","args":["-y","@playwright/mcp@latest"]}'
	mcp_count=$((mcp_count + 1))

	# shadcn UI
	register_mcp_for_runtime "$runtime_id" "shadcn" \
		'{"command":"npx","args":["shadcn@latest","mcp"]}'
	mcp_count=$((mcp_count + 1))

	# OpenAPI Search (remote, zero install)
	# Skip for OpenCode — it uses a remote URL setup in _generate_agents_opencode
	if [[ "$runtime_id" != "opencode" ]]; then
		register_mcp_for_runtime "$runtime_id" "openapi-search" \
			'{"command":"npx","args":["-y","openapi-mcp-server"]}'
		mcp_count=$((mcp_count + 1))
	fi

	# macOS Automator (macOS only)
	if [[ "$(uname -s)" == "Darwin" ]]; then
		register_mcp_for_runtime "$runtime_id" "macos-automator" \
			'{"command":"npx","args":["-y","@steipete/macos-automator-mcp@latest"]}'
		mcp_count=$((mcp_count + 1))
	fi

	# Cloudflare API (remote MCP endpoint — no local install needed)
	register_mcp_for_runtime "$runtime_id" "cloudflare-api" \
		'{"url":"https://mcp.cloudflare.com/mcp"}'
	mcp_count=$((mcp_count + 1))

	print_success "$display_name: $mcp_count MCP servers processed"
	return 0
}

# =============================================================================
# Phase 2d: System Prompt Deployment
# =============================================================================

_generate_prompts_for_runtime() {
	local runtime_id="$1"
	deploy_prompts_for_runtime "$runtime_id"
	return $?
}

# =============================================================================
# Phase 3: Verification
# =============================================================================

_verify_parity() {
	print_info "Verifying output parity with old generators..."

	local errors=0

	# Check OpenCode config exists and has agents
	local opencode_config="$HOME/.config/opencode/opencode.json"
	if [[ -f "$opencode_config" ]]; then
		local agent_count
		agent_count=$(python3 -c "
import json
with open('$opencode_config') as f:
    config = json.load(f)
agents = config.get('agent', {})
print(len([k for k, v in agents.items() if not v.get('disable', False)]))
" 2>/dev/null || echo "0")
		if [[ "$agent_count" -gt 0 ]]; then
			print_success "OpenCode: $agent_count active agents configured"
		else
			print_warning "OpenCode: no active agents found"
			errors=$((errors + 1))
		fi

		# Check instructions field
		local has_instructions
		has_instructions=$(python3 -c "
import json
with open('$opencode_config') as f:
    config = json.load(f)
print('yes' if config.get('instructions') else 'no')
" 2>/dev/null || echo "no")
		if [[ "$has_instructions" == "yes" ]]; then
			print_success "OpenCode: instructions field set"
		else
			print_warning "OpenCode: instructions field missing"
			errors=$((errors + 1))
		fi
	else
		print_warning "OpenCode config not found at $opencode_config"
	fi

	# Check Claude Code settings
	local claude_settings="$HOME/.claude/settings.json"
	if [[ -f "$claude_settings" ]]; then
		local has_hooks
		has_hooks=$(python3 -c "
import json
with open('$claude_settings') as f:
    settings = json.load(f)
hooks = settings.get('hooks', {}).get('PreToolUse', [])
print('yes' if hooks else 'no')
" 2>/dev/null || echo "no")
		if [[ "$has_hooks" == "yes" ]]; then
			print_success "Claude Code: PreToolUse hooks configured"
		else
			print_warning "Claude Code: PreToolUse hooks missing"
			errors=$((errors + 1))
		fi
	fi

	# Check command directories
	local opencode_cmd_dir
	opencode_cmd_dir=$(rt_command_dir "opencode") || opencode_cmd_dir=""
	if [[ -n "$opencode_cmd_dir" && -d "$opencode_cmd_dir" ]]; then
		local oc_cmd_count
		oc_cmd_count=$(find "$opencode_cmd_dir" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
		print_success "OpenCode: $oc_cmd_count commands in $opencode_cmd_dir"
	fi

	local claude_cmd_dir
	claude_cmd_dir=$(rt_command_dir "claude-code") || claude_cmd_dir=""
	if [[ -n "$claude_cmd_dir" && -d "$claude_cmd_dir" ]]; then
		local cc_cmd_count
		cc_cmd_count=$(find "$claude_cmd_dir" -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
		print_success "Claude Code: $cc_cmd_count commands in $claude_cmd_dir"
	fi

	if [[ $errors -gt 0 ]]; then
		print_warning "Parity check: $errors issue(s) found"
		return 1
	fi

	print_success "Parity check passed"
	return 0
}

# =============================================================================
# Main Orchestrator
# =============================================================================

_generate_for_runtime() {
	local runtime_id="$1"
	local subcommand="$2"
	local display_name
	display_name=$(rt_display_name "$runtime_id") || display_name="$runtime_id"

	print_info "Generating config for $display_name..."

	case "$subcommand" in
	all)
		# Agents
		case "$runtime_id" in
		opencode) _generate_agents_opencode ;;
		claude-code) _generate_agents_claude ;;
		*) print_info "No agent generation for $runtime_id" ;;
		esac

		# Commands
		_generate_commands_for_runtime "$runtime_id"

		# MCP — always attempt generation. The mcp-config-adapter handles
		# per-runtime support detection internally (some runtimes like aider
		# use YAML config instead of a JSON config path).
		_generate_mcp_for_runtime "$runtime_id"

		# System prompts
		_generate_prompts_for_runtime "$runtime_id"
		;;
	agents)
		case "$runtime_id" in
		opencode) _generate_agents_opencode ;;
		claude-code) _generate_agents_claude ;;
		*) print_info "No agent generation for $runtime_id" ;;
		esac
		;;
	commands)
		_generate_commands_for_runtime "$runtime_id"
		;;
	mcp)
		_generate_mcp_for_runtime "$runtime_id"
		;;
	prompts)
		_generate_prompts_for_runtime "$runtime_id"
		;;
	esac

	return 0
}

usage() {
	local script_name
	script_name="$(basename "$0")"
	cat <<EOF
Usage: ${script_name} [subcommand] [options]

Unified runtime config generator for all AI coding assistant runtimes.

Subcommands:
  all              Generate everything for all installed runtimes (default)
  agents           Generate agent configs only
  commands         Generate slash commands only
  mcp              Register MCP servers only
  prompts          Deploy system prompts only

Options:
  --runtime <id>   Generate for a specific runtime only
  --verify-parity  Compare output with old generators (regression test)
  --dry-run        Show what would be generated without writing
  --help           Show this help

Supported runtimes: opencode, claude-code, codex, cursor, droid, gemini-cli,
                    windsurf, continue, kilo, kiro, aider, amp

Examples:
  ${script_name}                          # Generate all for all installed runtimes
  ${script_name} agents                   # Generate agent configs only
  ${script_name} commands --runtime opencode  # Generate OpenCode commands only
  ${script_name} --verify-parity          # Run regression test
EOF
	return 0
}

main() {
	local subcommand="all"
	local target_runtime=""
	local verify_parity=false
	local dry_run=false

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		all | agents | commands | mcp | prompts)
			subcommand="$1"
			;;
		--runtime)
			shift
			target_runtime="${1:-}"
			if [[ -z "$target_runtime" ]]; then
				print_error "Missing runtime ID after --runtime"
				return 1
			fi
			;;
		--verify-parity)
			verify_parity=true
			;;
		--dry-run)
			dry_run=true
			;;
		--help | -h)
			usage
			return 0
			;;
		*)
			print_error "Unknown argument: $1"
			usage
			return 1
			;;
		esac
		shift
	done

	if [[ "$dry_run" == "true" ]]; then
		print_info "[DRY RUN] Would generate: $subcommand"
		if [[ -n "$target_runtime" ]]; then
			print_info "  Target runtime: $target_runtime"
		else
			print_info "  Target runtimes: all installed"
			# rt_detect_installed returns 1 when none found — guard against set -e
			if ! rt_detect_installed; then
				print_info "  (none detected)"
			fi
		fi
		return 0
	fi

	# Generate for target runtime(s)
	if [[ -n "$target_runtime" ]]; then
		# Validate runtime ID
		if ! rt_binary "$target_runtime" >/dev/null 2>&1; then
			print_error "Unknown runtime: $target_runtime"
			return 1
		fi
		_generate_for_runtime "$target_runtime" "$subcommand"
	else
		# Generate for all installed runtimes that we support config generation for
		# Currently: opencode and claude-code have full support
		local runtime_id
		while IFS= read -r runtime_id; do
			[[ -z "$runtime_id" ]] && continue
			_generate_for_runtime "$runtime_id" "$subcommand"
		done < <(rt_detect_installed)
	fi

	# Regenerate subagent index (shared between runtimes)
	local subagent_index_helper="$AGENTS_DIR/scripts/subagent-index-helper.sh"
	if [[ -x "$subagent_index_helper" ]]; then
		print_info "Regenerating subagent index..."
		if "$subagent_index_helper" generate 2>/dev/null; then
			print_success "Subagent index regenerated"
		else
			print_warning "Subagent index generation encountered issues"
		fi
	fi

	# Verify parity if requested
	if [[ "$verify_parity" == "true" ]]; then
		_verify_parity
	fi

	print_success "Runtime config generation complete"
	return 0
}

# Allow sourcing without executing main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
