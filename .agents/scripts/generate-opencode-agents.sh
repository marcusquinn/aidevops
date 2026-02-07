#!/bin/bash
# =============================================================================
# Generate OpenCode Agent Configuration
# =============================================================================
# Architecture:
#   - Primary agents: Auto-discovered from root .md files in ~/.aidevops/agents/
#   - Subagents: Auto-discovered from subfolder .md files (@mentionable)
#   - AGENTS.md: At ~/.config/opencode/AGENTS.md (global context reference)
#
# Source: ~/.aidevops/agents/
#   - Root .md files = Primary agents (auto-discovered, Tab-switchable)
#   - Subfolder .md files = Subagents (auto-discovered, @mentionable)
#
# Agent Configuration:
#   - Frontmatter in .md files can specify: mode, tools, temperature
#   - Special handling for Plan+ (read-only) and agents with specific MCP needs
#   - Default: full build permissions with common context tools
# =============================================================================

set -euo pipefail

AGENTS_DIR="$HOME/.aidevops/agents"
OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
OPENCODE_AGENT_DIR="$OPENCODE_CONFIG_DIR/agent"
OPENCODE_CONFIG="$OPENCODE_CONFIG_DIR/opencode.json"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}Generating OpenCode agent configuration...${NC}"

# Ensure directories exist
mkdir -p "$OPENCODE_AGENT_DIR"

# Always update AGENTS.md with version check (ensures updates get deployed)
cat > "$OPENCODE_CONFIG_DIR/AGENTS.md" << 'EOF'
Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities.

## aidevops Framework Status

**On conversation start**:
1. If you have Bash tool: Run `bash ~/.aidevops/agents/scripts/aidevops-update-check.sh`
2. If no Bash tool: Read `~/.aidevops/cache/session-greeting.txt` (cached by agents with Bash)
3. Greet with: "Hi!\n\nWe're running https://aidevops.sh v{version}.\n\nWhat would you like to work on?"
4. Then respond to the user's actual message

If update check output starts with `UPDATE_AVAILABLE|` (e.g., `UPDATE_AVAILABLE|current|latest`), inform user: "Update available (current → latest). Run `aidevops update` to update."

## Pre-Edit Git Check

Only for agents with Edit/Write/Bash tools. See ~/.aidevops/agents/AGENTS.md for workflow.
EOF
echo -e "  ${GREEN}✓${NC} Updated AGENTS.md with version check"

# Remove old primary agent markdown files (they're now in JSON, auto-discovered)
# This cleans up any legacy files from before auto-discovery
# Also removes demoted agents that are now subagents
# Plan+ and AI-DevOps consolidated into Build+ as of v2.50.0
for f in Accounts.md Accounting.md accounting.md AI-DevOps.md Build+.md Content.md Health.md Legal.md Marketing.md Research.md Sales.md SEO.md WordPress.md Plan+.md Build-Agent.md Build-MCP.md build-agent.md build-mcp.md plan-plus.md aidevops.md; do
    rm -f "$OPENCODE_AGENT_DIR/$f"
done

# Remove loop-state files that were incorrectly created as agents
# These are runtime state files, not agents
for f in ralph-loop.local.md quality-loop.local.md full-loop.local.md loop-state.md re-anchor.md postflight-loop.md; do
    rm -f "$OPENCODE_AGENT_DIR/$f"
done

# =============================================================================
# PRIMARY AGENTS - Defined in opencode.json for Tab order control
# =============================================================================

echo -e "${BLUE}Configuring primary agents in opencode.json...${NC}"

# Check if opencode.json exists
if [[ ! -f "$OPENCODE_CONFIG" ]]; then
    echo -e "${YELLOW}Warning: $OPENCODE_CONFIG not found. Creating minimal config.${NC}"
    # shellcheck disable=SC2016
    echo '{"$schema": "https://opencode.ai/config.json"}' > "$OPENCODE_CONFIG"
fi

# Use Python to auto-discover and configure primary agents
python3 << 'PYEOF'
import json
import os
import glob
import re

config_path = os.path.expanduser("~/.config/opencode/opencode.json")
agents_dir = os.path.expanduser("~/.aidevops/agents")

try:
    with open(config_path, 'r') as f:
        config = json.load(f)
except:
    config = {"$schema": "https://opencode.ai/config.json"}

# =============================================================================
# AUTO-DISCOVER PRIMARY AGENTS from root .md files
# =============================================================================

# Agent display name mappings (filename -> display name)
# If not in this map, derive from filename (e.g., build-agent.md -> Build-Agent)
DISPLAY_NAMES = {
    "build-plus": "Build+",
    "seo": "SEO",
    "social-media": "Social-Media",
}

# Agent ordering (agents listed here appear first in this order, rest alphabetical)
# Note: Build+ is now the single unified coding agent (Plan+ and AI-DevOps consolidated)
# Plan+ removed: planning workflow merged into Build+ with intent detection
# AI-DevOps removed: framework operations accessible via @aidevops subagent
AGENT_ORDER = ["Build+"]

# Files to skip (not primary agents - includes demoted agents)
# plan-plus.md and aidevops.md are now subagents, not primary agents
SKIP_PRIMARY_AGENTS = {"plan-plus.md", "aidevops.md"}

# Special tool configurations per agent (by display name)
# These are MCP tools that specific agents need access to
#
# MCP On-Demand Loading Strategy:
# The following MCPs are DISABLED globally to reduce context token usage:
#   - playwriter_*: ~3K tokens - enable via @playwriter subagent
#   - augment-context-engine_*: ~1K tokens - enable via @augment-context-engine subagent
#   - gh_grep_*: ~600 tokens - replaced by @github-search subagent (uses rg/bash)
#   - google-analytics-mcp_*: ~800 tokens - enable via @google-analytics subagent
#   - context7_*: ~800 tokens - enable via @context7 subagent (library docs lookup)
#
# osgrep_* remains enabled as the primary semantic search tool (local, no auth).
# Use @augment-context-engine subagent when osgrep returns insufficient results.
# Use @context7 subagent when you need up-to-date library documentation.
AGENT_TOOLS = {
    "Build+": {
        # Unified coding agent - planning, implementation, and DevOps
        # Browser automation: use @playwriter subagent (enables playwriter MCP on-demand)
        # Semantic search: osgrep primary, @augment-context-engine fallback
        # Library docs: use @context7 subagent when needed
        # GitHub search: use @github-search subagent (rg/bash, no MCP needed)
        "write": True, "edit": True, "bash": True, "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True, "todoread": True, "todowrite": True,
        "osgrep_*": True
    },
    "Onboarding": {
        "write": True, "edit": True, "bash": True, "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True,
        "osgrep_*": True
    },
    "Accounts": {
        "write": True, "edit": True, "bash": True, "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True, "quickfile_*": True,
        "osgrep_*": True
    },
    "Social-Media": {
        "write": True, "edit": True, "bash": True, "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True,
        "osgrep_*": True
    },
    "SEO": {
        "write": True, "read": True, "bash": True, "webfetch": True,
        "gsc_*": True, "ahrefs_*": True, "dataforseo_*": True,
        "osgrep_*": True
    },
    "WordPress": {
        "write": True, "edit": True, "bash": True, "read": True, "glob": True, "grep": True,
        "localwp_*": True, "osgrep_*": True
    },
    "Content": {
        "write": True, "edit": True, "read": True, "webfetch": True,
        "osgrep_*": True
    },
    "Research": {
        "read": True, "webfetch": True, "bash": True,
        "osgrep_*": True
    },
}

# Default tools for agents not in AGENT_TOOLS
#
# MCP On-Demand Loading (all disabled globally, use subagents):
# - playwriter_*: ~3K tokens - @playwriter subagent
# - augment-context-engine_*: ~1K tokens - @augment-context-engine subagent
# - gh_grep_*: ~600 tokens - @github-search subagent (uses rg/bash)
# - google-analytics-mcp_*: ~800 tokens - @google-analytics subagent
# - context7_*: ~800 tokens - @context7 subagent
# - claude-code-mcp_*: use @claude-code subagent
#
# osgrep_* remains enabled as primary semantic search (local, fast, no auth)
DEFAULT_TOOLS = {
    "write": True, "edit": True, "bash": True, "read": True, "glob": True, "grep": True,
    "webfetch": True, "task": True,
    "osgrep_*": True
}

# Temperature settings (by display name, default 0.2)
AGENT_TEMPS = {
    "Build+": 0.2,
    "Accounts": 0.1,
    "Legal": 0.1,
    "Content": 0.3,
    "Marketing": 0.3,
    "Research": 0.3,
}

# Custom system prompts
# ALL primary agents use the custom prompt by default to ensure consistent identity
# and tool preferences (e.g., "use git ls-files" instead of host tool's "use Glob")
# This prevents identity confusion when running in different host tools (OpenCode vs Claude Code)
DEFAULT_PROMPT = "~/.aidevops/agents/prompts/build.txt"

# Agents that should NOT use the custom prompt (empty by default - all agents use it)
SKIP_CUSTOM_PROMPT = set()

# Model routing tiers (from subagent YAML frontmatter 'model:' field)
# Maps tier names to actual model identifiers
# Agents declare their tier; the coordinator uses this for cost-effective routing
MODEL_TIERS = {
    "haiku": "claude-3-5-haiku-20241022",      # Triage, routing, simple tasks
    "sonnet": "claude-sonnet-4-20250514",      # Code, review, implementation
    "opus": "claude-opus-4-20250514",          # Architecture, complex reasoning
    "flash": "gemini-2.5-flash",               # Fast, cheap, large context
    "pro": "gemini-2.5-pro",                   # Capable, large context
}

# Default model tier per agent (overridden by frontmatter 'model:' field)
# Empty by default - agents use whatever model the user has authenticated with.
# Uncomment entries to pin specific agents to specific models if needed.
AGENT_MODEL_TIERS = {
    # "Build+": "sonnet",
    # "Research": "flash",
    # "Content": "sonnet",

}

# Files to skip (not primary agents)
# Includes SKIP_PRIMARY_AGENTS (demoted agents that are now subagents)
# SKILL-SCAN-RESULTS.md is a generated report, not an agent
SKIP_FILES = {"AGENTS.md", "README.md", "SKILL-SCAN-RESULTS.md"} | SKIP_PRIMARY_AGENTS

def parse_frontmatter(filepath):
    """Parse YAML frontmatter from markdown file."""
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Check for frontmatter
        if not content.startswith('---'):
            return {}
        
        # Find end of frontmatter
        end_idx = content.find('---', 3)
        if end_idx == -1:
            return {}
        
        frontmatter = content[3:end_idx].strip()
        
        # Simple YAML parsing for subagents list
        result = {}
        lines = frontmatter.split('\n')
        current_key = None
        current_list = []
        
        for line in lines:
            stripped = line.strip()
            # Ignore comments and empty lines
            if not stripped or stripped.startswith('#'):
                continue
            
            if stripped.startswith('- ') and current_key:
                # List item
                current_list.append(stripped[2:].strip())
            elif ':' in stripped and not stripped.startswith('-'):
                # Save previous list if any
                if current_key and current_list:
                    result[current_key] = current_list
                    current_list = []
                
                # New key
                key, value = stripped.split(':', 1)
                current_key = key.strip()
                value = value.strip()
                if value:
                    result[current_key] = value
                    current_key = None
        
        # Save final list
        if current_key and current_list:
            result[current_key] = current_list
        
        return result
    except (IOError, OSError, UnicodeDecodeError) as e:
        import sys
        print(f"Warning: Failed to parse frontmatter for {filepath}: {e}", file=sys.stderr)
        return {}

def filename_to_display(filename):
    """Convert filename to display name."""
    name = filename.replace(".md", "")
    if name in DISPLAY_NAMES:
        return DISPLAY_NAMES[name]
    # Convert kebab-case to Title-Case
    return "-".join(word.capitalize() for word in name.split("-"))

def get_agent_config(display_name, filename, subagents=None, model_tier=None):
    """Generate agent configuration.
    
    Args:
        display_name: Agent display name
        filename: Agent markdown filename
        subagents: Optional list of allowed subagent names (from frontmatter)
        model_tier: Optional model tier from frontmatter (haiku/sonnet/opus/flash/pro)
    """
    tools = AGENT_TOOLS.get(display_name, DEFAULT_TOOLS.copy())
    temp = AGENT_TEMPS.get(display_name, 0.2)
    
    config = {
        "description": f"Read ~/.aidevops/agents/{filename}",
        "mode": "primary",
        "temperature": temp,
        "permission": {},
        "tools": tools
    }
    
    # Add custom system prompt for ALL primary agents (ensures consistent identity)
    # This replaces the host tool's default system prompt, preventing identity confusion
    # when running in different tools (OpenCode vs Claude Code) and enforcing tool preferences
    if display_name not in SKIP_CUSTOM_PROMPT:
        prompt_file = os.path.expanduser(DEFAULT_PROMPT)
        if os.path.exists(prompt_file):
            config["prompt"] = "{file:" + DEFAULT_PROMPT + "}"
    
    # Add model routing (from frontmatter or defaults)
    # Resolves tier name to actual model identifier
    effective_tier = model_tier or AGENT_MODEL_TIERS.get(display_name)
    if effective_tier and effective_tier in MODEL_TIERS:
        config["model"] = MODEL_TIERS[effective_tier]
    
    # All primary agents get external_directory permission
    # (Plan+ special permissions removed - it's now a subagent)
    config["permission"] = {"external_directory": "allow"}
    
    # Add subagent filtering via permission.task if subagents specified
    # This generates deny-all + allow-specific rules
    if subagents and isinstance(subagents, list) and len(subagents) > 0:
        task_perms = {"*": "deny"}
        for subagent in subagents:
            task_perms[subagent] = "allow"
        config["permission"]["task"] = task_perms
        print(f"    {display_name}: filtered to {len(subagents)} subagents")
    
    return config

# Discover all root-level .md files
primary_agents = {}
discovered = []
subagent_filtered_count = 0

for filepath in glob.glob(os.path.join(agents_dir, "*.md")):
    filename = os.path.basename(filepath)
    if filename in SKIP_FILES:
        continue
    
    display_name = filename_to_display(filename)
    
    # Parse frontmatter for subagents list and model tier
    frontmatter = parse_frontmatter(filepath)
    subagents = frontmatter.get('subagents', None)
    model_tier = frontmatter.get('model', None)
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
# DISABLE DEFAULT BUILD/PLAN AGENTS AND DEMOTED AGENTS
# Build+ is now the unified coding agent (Plan+ and AI-DevOps consolidated)
# =============================================================================

sorted_agents["build"] = {"disable": True}
sorted_agents["plan"] = {"disable": True}
# Disable Plan+ and AI-DevOps as primary agents (now subagents)
sorted_agents["Plan+"] = {"disable": True}
sorted_agents["AI-DevOps"] = {"disable": True}
print("  Disabled default 'build' and 'plan' agents")
print("  Disabled 'Plan+' and 'AI-DevOps' (consolidated into Build+, available as @subagents)")

config['agent'] = sorted_agents

# Set Build+ as the default agent (first in Tab cycle, auto-selected on startup)
config['default_agent'] = "Build+"
print("  Set Build+ as default agent")

# =============================================================================
# INSTRUCTIONS - Auto-load aidevops AGENTS.md for full framework context
# =============================================================================
# OpenCode's 'instructions' config auto-includes files in every session.
# This ensures the full aidevops framework docs are available without
# relying on the LLM to follow "read this file" instructions.
# See: https://opencode.ai/docs/rules/#using-opencodejson
instructions_path = os.path.expanduser("~/.aidevops/agents/AGENTS.md")
if os.path.exists(instructions_path):
    config['instructions'] = [instructions_path]
    print("  Added instructions: ~/.aidevops/agents/AGENTS.md (auto-loaded every session)")
else:
    print("  Warning: ~/.aidevops/agents/AGENTS.md not found - run setup.sh first")

print(f"  Auto-discovered {len(sorted_agents)} primary agents from {agents_dir}")
print(f"  Order: {', '.join(list(sorted_agents.keys())[:5])}...")
if subagent_filtered_count > 0:
    print(f"  Subagent filtering: {subagent_filtered_count} agents have permission.task rules")

# Count agents with custom prompts (all agents except those in SKIP_CUSTOM_PROMPT)
prompt_count = sum(1 for name, cfg in sorted_agents.items() if "prompt" in cfg)
if prompt_count > 0:
    print(f"  Custom system prompts: {prompt_count} agents use prompts/build.txt")

# Count agents with model routing
model_count = sum(1 for name, cfg in sorted_agents.items() if "model" in cfg)
if model_count > 0:
    print(f"  Model routing: {model_count} agents have model tier assignments")

# =============================================================================
# MCP SERVERS - Ensure required MCP servers are configured
# =============================================================================
# Loading strategy:
#   - enabled: True  = Server starts at OpenCode launch (for MCPs used by all main agents)
#   - enabled: False = Server starts on-demand when subagent invokes it (lazy loading)
#
# MCPs enabled at startup (used by main agents):
#   - osgrep, augment-context-engine, context7, playwriter, gh_grep
#
# MCPs lazy-loaded (subagent-only):
#   - claude-code-mcp, outscraper, dataforseo, shadcn, macos-automator, gsc, localwp, etc.
# =============================================================================

if 'mcp' not in config:
    config['mcp'] = {}

if 'tools' not in config:
    config['tools'] = {}

import shutil
import platform
import sys
bun_path = shutil.which('bun')
npx_path = shutil.which('npx')
if not npx_path and not bun_path:
    print("  Warning: Neither bun nor npx found in PATH", file=sys.stderr)
pkg_runner = f"{bun_path} x" if bun_path else (npx_path or "npx")

# -----------------------------------------------------------------------------
# MCP LOADING POLICY - Enforce enabled states for all MCPs
# -----------------------------------------------------------------------------
# Eager-loaded (enabled: True): Used by all main agents, start at launch
# Only osgrep remains eager - it's local, fast, no auth required
EAGER_MCPS = {'osgrep'}

# Lazy-loaded (enabled: False): Subagent-only, start on-demand
# sentry/socket: Remote MCPs requiring auth, disable until configured
# These save ~7K+ tokens on session startup
LAZY_MCPS = {'claude-code-mcp', 'outscraper', 'dataforseo', 'shadcn', 'macos-automator', 
             'gsc', 'localwp', 'chrome-devtools', 'quickfile', 'amazon-order-history', 
             'google-analytics-mcp', 'MCP_DOCKER', 'ahrefs',
             'playwriter', 'augment-context-engine', 'context7',
             'sentry', 'socket',
             # Oh-My-OpenCode MCPs - disable globally, use @github-search/@context7 subagents
             'grep_app', 'websearch', 'gh_grep'}
# Note: gh_grep removed from aidevops but may exist from old configs or OmO

# Apply loading policy to existing MCPs and warn about uncategorized ones
uncategorized = []
for mcp_name in list(config.get('mcp', {}).keys()):
    if mcp_name in EAGER_MCPS:
        config['mcp'][mcp_name]['enabled'] = True
    elif mcp_name in LAZY_MCPS:
        config['mcp'][mcp_name]['enabled'] = False
    else:
        uncategorized.append(mcp_name)

if uncategorized:
    print(f"  Warning: Uncategorized MCPs (add to EAGER_MCPS or LAZY_MCPS): {uncategorized}", file=sys.stderr)

print(f"  Applied MCP loading policy: {len(EAGER_MCPS)} eager, {len(LAZY_MCPS)} lazy")

# -----------------------------------------------------------------------------
# EAGER-LOADED MCPs (enabled: True) - Used by all main agents
# -----------------------------------------------------------------------------

# osgrep MCP - local semantic search (primary, try first)
# Install: npm install -g osgrep && osgrep setup
# Only enable if osgrep CLI is installed (avoids "Executable not found" errors)
osgrep_installed = shutil.which('osgrep') is not None
if osgrep_installed:
    if 'osgrep' not in config['mcp']:
        config['mcp']['osgrep'] = {
            "type": "local",
            "command": ["osgrep", "mcp"],
            "enabled": True
        }
        print("  Added osgrep MCP (eager load - used by all agents)")
    # osgrep_* enabled globally (used by all main agents)
    config['tools']['osgrep_*'] = True
else:
    # Disable osgrep if not installed to avoid MCP errors
    if 'osgrep' in config['mcp']:
        config['mcp']['osgrep']['enabled'] = False
    config['tools']['osgrep_*'] = False
    print("  osgrep not installed - MCP disabled (install: npm install -g osgrep && osgrep setup)")

# Playwriter MCP - browser automation via Chrome extension (used by all main agents)
# Requires: Chrome extension from https://chromewebstore.google.com/detail/playwriter-mcp/jfeammnjpkecdekppnclgkkffahnhfhe
if 'playwriter' not in config['mcp']:
    if bun_path:
        config['mcp']['playwriter'] = {
            "type": "local",
            "command": ["bun", "x", "playwriter@latest"],
            "enabled": True
        }
    else:
        config['mcp']['playwriter'] = {
            "type": "local",
            "command": ["npx", "playwriter@latest"],
            "enabled": True
        }
    print("  Added playwriter MCP (eager load - used by all agents)")

# playwriter_* enabled globally (used by all main agents)
config['tools']['playwriter_*'] = True

# gh_grep MCP removed - @github-search subagent uses CLI tools (rg, gh) instead
# This saves ~600 tokens per session with equivalent functionality
# See: tools/context/github-search.md

# -----------------------------------------------------------------------------
# LAZY-LOADED MCPs (enabled: False) - Subagent-only, start on-demand
# -----------------------------------------------------------------------------

# Outscraper MCP - for business intelligence extraction (subagent only)
# Note: enabled state is set by MCP loading policy above
if 'outscraper' not in config['mcp']:
    config['mcp']['outscraper'] = {
        "type": "local",
        "command": ["/bin/bash", "-c", "OUTSCRAPER_API_KEY=$OUTSCRAPER_API_KEY uv tool run outscraper-mcp-server"],
        "enabled": False
    }
    print("  Added outscraper MCP (lazy load - @outscraper subagent only)")

if 'outscraper_*' not in config['tools']:
    config['tools']['outscraper_*'] = False
    print("  Set outscraper_* disabled globally")

# DataForSEO MCP - for comprehensive SEO data (SEO agent and @dataforseo subagent)
# Note: enabled state is set by MCP loading policy above
if 'dataforseo' not in config['mcp']:
    config['mcp']['dataforseo'] = {
        "type": "local",
        "command": ["/bin/bash", "-c", f"source ~/.config/aidevops/credentials.sh && DATAFORSEO_USERNAME=$DATAFORSEO_USERNAME DATAFORSEO_PASSWORD=$DATAFORSEO_PASSWORD {pkg_runner} dataforseo-mcp-server"],
        "enabled": False
    }
    print("  Added dataforseo MCP (lazy load - SEO agent/@dataforseo subagent)")

if 'dataforseo_*' not in config['tools']:
    config['tools']['dataforseo_*'] = False
    print("  Set dataforseo_* disabled globally")

# shadcn MCP - UI component library (subagent only)
# Docs: https://ui.shadcn.com/docs/mcp
# Note: enabled state is set by MCP loading policy above
if 'shadcn' not in config['mcp']:
    config['mcp']['shadcn'] = {
        "type": "local",
        "command": ["npx", "shadcn@latest", "mcp"],
        "enabled": False
    }
    print("  Added shadcn MCP (lazy load - @shadcn subagent only)")

if 'shadcn_*' not in config['tools']:
    config['tools']['shadcn_*'] = False
    print("  Set shadcn_* disabled globally")

# Claude Code MCP - spawn Claude as sub-agent (subagent only)
# Source: https://github.com/steipete/claude-code-mcp
# Use @claude-code subagent to invoke this MCP
# Fork: https://github.com/marcusquinn/claude-code-mcp (until PR #40 merged upstream)
# Upstream: https://github.com/steipete/claude-code-mcp
# Note: Always overwrite to ensure correct fork is used
config['mcp']['claude-code-mcp'] = {
    "type": "local",
    "command": ["npx", "-y", "github:marcusquinn/claude-code-mcp"],
    "enabled": False
}
print("  Set claude-code-mcp to lazy load (@claude-code subagent only)")

# Claude Code MCP tools disabled globally
config['tools']['claude-code-mcp_*'] = False
print("  Set claude-code-mcp_* disabled globally")

# macOS Automator MCP - AppleScript and JXA automation (macOS only, subagent only)
# Docs: https://github.com/steipete/macos-automator-mcp
# Note: enabled state is set by MCP loading policy above
if platform.system() == 'Darwin':
    if 'macos-automator' not in config['mcp']:
        config['mcp']['macos-automator'] = {
            "type": "local",
            "command": ["npx", "-y", "@steipete/macos-automator-mcp@0.2.0"],
            "enabled": False
        }
        print("  Added macos-automator MCP (lazy load - @mac subagent only)")

    if 'macos-automator_*' not in config['tools']:
        config['tools']['macos-automator_*'] = False
        print("  Set macos-automator_* disabled globally")

# Disable Oh-My-OpenCode MCP tools globally
# OmO installs: grep_app (GitHub search), context7 (docs), websearch (Exa)
# MCPs are disabled via LAZY_MCPS above, but we also need to disable tools
omo_tool_patterns = ['grep_app_*', 'websearch_*', 'gh_grep_*']
for tool_pattern in omo_tool_patterns:
    if tool_pattern not in config.get('tools', {}):
        config['tools'][tool_pattern] = False
        print(f"  Disabled {tool_pattern} tools globally (use @github-search subagent)")

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)

print(f"  Updated {len(primary_agents)} primary agents in opencode.json")
PYEOF

echo -e "  ${GREEN}✓${NC} Primary agents configured in opencode.json"

# =============================================================================
# SUBAGENTS - Generated as markdown files (@mentionable)
# =============================================================================

echo -e "${BLUE}Generating subagent markdown files...${NC}"

# Remove existing subagent files (regenerate fresh)
find "$OPENCODE_AGENT_DIR" -name "*.md" -type f -delete 2>/dev/null || true

subagent_count=0

# Generate SUBAGENT files from subfolders
# Some subagents need specific MCP tools enabled
while IFS= read -r f; do
    name=$(basename "$f" .md)
    [[ "$name" == "AGENTS" || "$name" == "README" ]] && continue
    
    rel_path="${f#"$AGENTS_DIR"/}"
    
    # Determine additional tools based on subagent name/path
    extra_tools=""
    case "$name" in
        outscraper)
            extra_tools=$'  outscraper_*: true\n  webfetch: true'
            ;;
        mainwp|localwp)
            extra_tools=$'  localwp_*: true'
            ;;
        quickfile)
            extra_tools=$'  quickfile_*: true'
            ;;
        google-search-console)
            extra_tools=$'  gsc_*: true'
            ;;
        dataforseo)
            extra_tools=$'  dataforseo_*: true\n  webfetch: true'
            ;;
        claude-code)
            extra_tools=$'  claude-code-mcp_*: true'
            ;;
        # serper - REMOVED: Uses curl subagent now, no MCP tools
        playwriter)
            extra_tools=$'  playwriter_*: true'
            ;;
        shadcn)
            extra_tools=$'  shadcn_*: true\n  write: true\n  edit: true'
            ;;
        macos-automator|mac)
            # Only enable macos-automator tools on macOS
            if [[ "$(uname -s)" == "Darwin" ]]; then
                extra_tools=$'  macos-automator_*: true\n  webfetch: true'
            fi
            ;;
        *)
            ;;  # No extra tools for other agents
    esac
    
    if [[ -n "$extra_tools" ]]; then
        cat > "$OPENCODE_AGENT_DIR/$name.md" << EOF
---
description: Read ~/.aidevops/agents/${rel_path}
mode: subagent
temperature: 0.2
permission:
  external_directory: allow
tools:
  read: true
  bash: true
$extra_tools
---
EOF
    else
        cat > "$OPENCODE_AGENT_DIR/$name.md" << EOF
---
description: Read ~/.aidevops/agents/${rel_path}
mode: subagent
temperature: 0.2
permission:
  external_directory: allow
tools:
  read: true
  bash: true
---
EOF
    fi
    subagent_count=$((subagent_count + 1))
done < <(find "$AGENTS_DIR" -mindepth 2 -name "*.md" -type f -not -path "*/loop-state/*" | sort)

echo -e "  ${GREEN}✓${NC} Generated $subagent_count subagent files"

# =============================================================================
# MCP INDEX - Sync tool descriptions for on-demand discovery
# =============================================================================

echo -e "${BLUE}Syncing MCP tool index for on-demand discovery...${NC}"

MCP_INDEX_HELPER="$AGENTS_DIR/scripts/mcp-index-helper.sh"
if [[ -x "$MCP_INDEX_HELPER" ]]; then
    "$MCP_INDEX_HELPER" sync 2>/dev/null || echo -e "  ${YELLOW}⚠${NC} MCP index sync skipped (non-critical)"
    echo -e "  ${GREEN}✓${NC} MCP tool index updated"
else
    echo -e "  ${YELLOW}⚠${NC} MCP index helper not found (install with setup.sh)"
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo -e "${GREEN}Done!${NC}"
echo "  Primary agents: Auto-discovered from ~/.aidevops/agents/*.md (Tab-switchable)"
echo "  Subagents: $subagent_count auto-discovered from subfolders (@mentionable)"
echo "  Instructions: ~/.aidevops/agents/AGENTS.md (auto-loaded every session)"
echo "  Global rules: ~/.config/opencode/AGENTS.md (version check + pre-edit)"
echo ""
echo "Tab order: Build+ → (alphabetical)"
echo "  Note: Plan+ and AI-DevOps consolidated into Build+ (available as @plan-plus, @aidevops)"
echo ""
echo "MCP Loading Strategy:"
echo "  - MCPs disabled globally, enabled per-agent (reduces context tokens)"
echo "  - Use 'mcp-index-helper.sh search <query>' to discover tools on-demand"
echo "  - Subagents enable specific MCPs via frontmatter tools: section"
echo ""
echo "To add a new primary agent: Create ~/.aidevops/agents/{name}.md"
echo "To add a new subagent: Create ~/.aidevops/agents/{folder}/{name}.md"
echo ""
echo "Restart OpenCode to load new configuration."
