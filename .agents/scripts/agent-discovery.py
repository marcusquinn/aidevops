import json
import os
import glob
import sys

# Add lib directory to path for shared utilities
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'lib'))
from discovery_utils import atomic_json_write, parse_frontmatter

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
SKIP_FILES = {"AGENTS.md", "README.md", "configs/SKILL-SCAN-RESULTS.md"} | SKIP_PRIMARY_AGENTS

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
# AGENT CONFIGURATION HELPERS
# =============================================================================

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

def _apply_mcp_loading_policy(config):
    """Apply EAGER/LAZY loading policy to existing MCPs in config."""
    for mcp_name in list(config.get('mcp', {}).keys()):
        mcp_cfg = config['mcp'].get(mcp_name, {})
        if not isinstance(mcp_cfg, dict):
            continue
        if mcp_name in EAGER_MCPS:
            mcp_cfg['enabled'] = True
        elif mcp_name in LAZY_MCPS:
            mcp_cfg['enabled'] = False


def _remove_deprecated_mcps(config):
    """Remove deprecated MCP entries from config."""
    if 'osgrep' in config.get('mcp', {}):
        del config['mcp']['osgrep']
    if 'osgrep_*' in config.get('tools', {}):
        del config['tools']['osgrep_*']


def _register_standard_mcps(config, bun_path, pkg_runner):
    """Register standard MCP servers if not already present."""
    import platform

    # Playwriter MCP
    if 'playwriter' not in config['mcp']:
        runner = "bun" if bun_path else "npx"
        command = [runner, "x", "playwriter@latest"] if runner == "bun" else [runner, "playwriter@latest"]
        config['mcp']['playwriter'] = {"type": "local", "command": command, "enabled": True}
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
        config['mcp']['shadcn'] = {"type": "local", "command": ["npx", "shadcn@latest", "mcp"], "enabled": False}
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
        _register_macos_mcps(config)

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


def _register_macos_mcps(config):
    """Register macOS-only MCP servers."""
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


def _update_opencode_agents(config, sorted_agents_local, primary_agents_local):
    """Update agent config in opencode.json, guarding against empty discovery."""
    if not primary_agents_local:
        print("  WARNING: No primary agents discovered — skipping agent config update", file=sys.stderr)
        print("  (agents directory may be empty or deploy incomplete)", file=sys.stderr)
        return
    sorted_agents_local["build"] = {"disable": True}
    sorted_agents_local["plan"] = {"disable": True}
    sorted_agents_local["Plan+"] = {"disable": True}
    sorted_agents_local["AI-DevOps"] = {"disable": True}
    sorted_agents_local["Browser-Extension-Dev"] = {"disable": True}
    sorted_agents_local["Mobile-App-Dev"] = {"disable": True}
    config['agent'] = sorted_agents_local
    config['default_agent'] = "Build+"


def _merge_instructions(config):
    """Merge aidevops AGENTS.md into instructions list, preserving user entries."""
    instructions_path = os.path.expanduser("~/.aidevops/agents/AGENTS.md")
    if not os.path.exists(instructions_path):
        return
    existing = config.get('instructions', [])
    if not isinstance(existing, list):
        existing = [existing] if existing else []
    if instructions_path not in existing:
        existing.append(instructions_path)
    config['instructions'] = existing


def _ensure_plugin_registered(config):
    """Ensure the aidevops plugin is registered in opencode config."""
    aidevops_plugin_url = "file://" + os.path.expanduser(
        "~/.aidevops/agents/plugins/opencode-aidevops/index.mjs"
    )
    plugin_list = config.get('plugin', [])
    if not isinstance(plugin_list, list):
        plugin_list = [plugin_list] if plugin_list else []
    if aidevops_plugin_url not in plugin_list:
        plugin_list.append(aidevops_plugin_url)
        print(f"  Re-registered aidevops plugin (was missing from config)", file=sys.stderr)
    config['plugin'] = plugin_list


def _enable_prompt_caching(config):
    """Enable Anthropic prompt caching in provider config."""
    config.setdefault('provider', {}).setdefault('anthropic', {}).setdefault('options', {})
    config['provider']['anthropic']['options']['setCacheKey'] = True


def output_opencode_json():
    """Write agent config to opencode.json."""
    import shutil

    config_path = os.path.expanduser("~/.config/opencode/opencode.json")
    try:
        with open(config_path, 'r', encoding='utf-8') as f:
            config = json.load(f)
    except FileNotFoundError:
        config = {"$schema": "https://opencode.ai/config.json"}
    except (OSError, json.JSONDecodeError) as e:
        print(f"Error: Failed to load {config_path}: {e}", file=sys.stderr)
        sys.exit(1)

    _update_opencode_agents(config, sorted_agents, primary_agents)
    _merge_instructions(config)
    _ensure_plugin_registered(config)
    _enable_prompt_caching(config)

    config.setdefault('mcp', {})
    config.setdefault('tools', {})

    bun_path = shutil.which('bun')
    npx_path = shutil.which('npx')
    pkg_runner = f"{bun_path} x" if bun_path else (npx_path or "npx")

    _apply_mcp_loading_policy(config)
    _remove_deprecated_mcps(config)
    _register_standard_mcps(config, bun_path, pkg_runner)

    atomic_json_write(config_path, config)

    print(f"  Updated {len(primary_agents)} primary agents in opencode.json")
    if subagent_filtered_count > 0:
        print(f"  Subagent filtering: {subagent_filtered_count} agents have permission.task rules")
    prompt_count = sum(1 for name, cfg in sorted_agents.items() if "prompt" in cfg)
    if prompt_count > 0:
        print(f"  Custom system prompts: {prompt_count} agents use prompts/build.txt")


def _build_hook_entry():
    """Return the git safety hook entry dict."""
    return {"type": "command", "command": "$HOME/.aidevops/hooks/git_safety_guard.py"}


def _ensure_bash_hook(settings):
    """Ensure the git safety PreToolUse hook is registered for Bash. Returns changed flag."""
    hook_command = "$HOME/.aidevops/hooks/git_safety_guard.py"
    hook_entry = _build_hook_entry()
    bash_matcher = {"matcher": "Bash", "hooks": [hook_entry]}

    settings.setdefault("hooks", {}).setdefault("PreToolUse", [])

    for rule in settings["hooks"]["PreToolUse"]:
        if rule.get("matcher") == "Bash":
            existing_commands = [h.get("command", "") for h in rule.get("hooks", [])]
            if hook_command not in existing_commands:
                rule.setdefault("hooks", []).append(hook_entry)
                return True
            return False
    settings["hooks"]["PreToolUse"].append(bash_matcher)
    return True


def _build_permission_rules():
    """Return (allow_rules, deny_rules, ask_rules) for Claude Code settings."""
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
    return allow_rules, deny_rules, ask_rules


def _merge_rules(existing, new_rules):
    """Append new_rules not already in existing. Returns True if any added."""
    added = False
    for rule in new_rules:
        if rule not in existing:
            existing.append(rule)
            added = True
    return added


def _clean_expanded_path_rules(permissions):
    """Remove expanded-path allow rules from prior versions. Returns changed flag."""
    home = os.path.expanduser("~")
    existing_allow = permissions.get("allow", [])
    cleaned = [r for r in existing_allow if not (r.startswith(home + "/") and "(" not in r)]
    if len(cleaned) != len(existing_allow):
        permissions["allow"] = cleaned
        return True
    return False


def output_claude_settings():
    """Update ~/.claude/settings.json with hooks and permissions."""
    settings_path = os.path.expanduser("~/.claude/settings.json")
    try:
        with open(settings_path, 'r') as f:
            settings = json.load(f)
    except (json.JSONDecodeError, FileNotFoundError):
        settings = {}

    changed = _ensure_bash_hook(settings)

    permissions = settings.setdefault("permissions", {})
    if _clean_expanded_path_rules(permissions):
        changed = True

    allow_rules, deny_rules, ask_rules = _build_permission_rules()
    allow_list = permissions.setdefault("allow", [])
    deny_list = permissions.setdefault("deny", [])
    ask_list = permissions.setdefault("ask", [])

    if _merge_rules(allow_list, allow_rules):
        changed = True
    if _merge_rules(deny_list, deny_rules):
        changed = True
    if _merge_rules(ask_list, ask_rules):
        changed = True

    settings["permissions"] = permissions

    if "$schema" not in settings:
        settings["$schema"] = "https://json.schemastore.org/claude-code-settings.json"
        changed = True

    if changed:
        os.makedirs(os.path.dirname(settings_path), exist_ok=True)
        atomic_json_write(settings_path, settings, trailing_newline=True)
        print(f"  Updated {settings_path}")
    else:
        print(f"  {settings_path} (no changes needed)")

    print(f"  Discovered {len(primary_agents)} primary agents")


if output_format == "opencode-json":
    output_opencode_json()
elif output_format == "claude-settings":
    output_claude_settings()
else:
    print(f"Unknown output format: {output_format}", file=sys.stderr)
    sys.exit(1)
