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

**CRITICAL - DO THIS FIRST**: Before responding to ANY user message in a new conversation:
1. Run this command using the Bash tool: `bash ~/.aidevops/agents/scripts/aidevops-update-check.sh`
2. Greet with exactly this format (with line breaks):
   "Hi!
   
   We're running https://aidevops.sh v{version}.
   
   What would you like to work on?"

If the output contains `UPDATE_AVAILABLE|current|latest`, inform the user: "An aidevops update is available (current → latest). Run `aidevops update` to update, then restart OpenCode."
EOF
echo -e "  ${GREEN}✓${NC} Updated AGENTS.md with version check"

# Remove old primary agent markdown files (they're now in JSON, auto-discovered)
# This cleans up any legacy files from before auto-discovery
for f in Accounting.md AI-DevOps.md Build+.md Content.md Health.md Legal.md Marketing.md Research.md Sales.md SEO.md WordPress.md Plan+.md Build-Agent.md Build-MCP.md; do
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
    "plan-plus": "Plan+",
    "build-plus": "Build+",
    "build-agent": "Build-Agent",
    "build-mcp": "Build-MCP",
    "aidevops": "AI-DevOps",
}

# Agent ordering (agents listed here appear first in this order, rest alphabetical)
AGENT_ORDER = ["Plan+", "Build+", "Build-Agent", "Build-MCP", "AI-DevOps"]

# Special tool configurations per agent (by display name)
# These are MCP tools that specific agents need access to
AGENT_TOOLS = {
    "Plan+": {
        # Read-only agent - no write/edit/bash
        "write": False, "edit": False, "bash": False,
        "read": True, "glob": True, "grep": True, "webfetch": True, "task": False,
        "context7_*": True, "osgrep_*": True, "augment-context-engine_*": True, "repomix_*": True
    },
    "Build+": {
        "write": True, "edit": True, "bash": True, "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True, "todoread": True, "todowrite": True,
        "context7_*": True, "osgrep_*": True, "augment-context-engine_*": True, "repomix_*": True
    },
    "Build-Agent": {
        "write": True, "edit": True, "bash": True, "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True, "todoread": True, "todowrite": True,
        "context7_*": True, "osgrep_*": True, "augment-context-engine_*": True, "repomix_*": True
    },
    "Build-MCP": {
        "write": True, "edit": True, "bash": True, "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True, "todoread": True, "todowrite": True,
        "context7_*": True, "osgrep_*": True, "augment-context-engine_*": True, "repomix_*": True
    },
    "AI-DevOps": {
        "write": True, "edit": True, "bash": True, "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True, "todoread": True, "todowrite": True,
        "context7_*": True, "osgrep_*": True, "augment-context-engine_*": True, "repomix_*": True
    },
    "Accounting": {
        "write": True, "edit": True, "bash": True, "read": True, "glob": True, "grep": True,
        "webfetch": True, "task": True, "quickfile_*": True,
        "osgrep_*": True, "augment-context-engine_*": True
    },
    "SEO": {
        "write": True, "read": True, "bash": True, "webfetch": True,
        "gsc_*": True, "ahrefs_*": True, "dataforseo_*": True, "serper_*": True,
        "context7_*": True, "osgrep_*": True, "augment-context-engine_*": True
    },
    "WordPress": {
        "write": True, "edit": True, "bash": True, "read": True, "glob": True, "grep": True,
        "localwp_*": True, "context7_*": True, "osgrep_*": True, "augment-context-engine_*": True
    },
    "Content": {
        "write": True, "edit": True, "read": True, "webfetch": True,
        "osgrep_*": True, "augment-context-engine_*": True
    },
    "Research": {
        "read": True, "webfetch": True, "bash": True,
        "context7_*": True, "osgrep_*": True, "augment-context-engine_*": True
    },
}

# Default tools for agents not in AGENT_TOOLS
DEFAULT_TOOLS = {
    "write": True, "edit": True, "bash": True, "read": True, "glob": True, "grep": True,
    "webfetch": True, "task": True,
    "osgrep_*": True, "augment-context-engine_*": True
}

# Temperature settings (by display name, default 0.2)
AGENT_TEMPS = {
    "Plan+": 0.2,
    "Accounting": 0.1,
    "Legal": 0.1,
    "Content": 0.3,
    "Marketing": 0.3,
    "Research": 0.3,
}

# Files to skip (not primary agents)
SKIP_FILES = {"AGENTS.md", "README.md"}

def filename_to_display(filename):
    """Convert filename to display name."""
    name = filename.replace(".md", "")
    if name in DISPLAY_NAMES:
        return DISPLAY_NAMES[name]
    # Convert kebab-case to Title-Case
    return "-".join(word.capitalize() for word in name.split("-"))

def get_agent_config(display_name, filename):
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
    
    # Special permissions
    if display_name == "Plan+":
        config["permission"] = {"edit": "deny", "write": "deny", "bash": "deny"}
    else:
        config["permission"] = {"external_directory": "allow"}
    
    return config

# Discover all root-level .md files
primary_agents = {}
discovered = []

for filepath in glob.glob(os.path.join(agents_dir, "*.md")):
    filename = os.path.basename(filepath)
    if filename in SKIP_FILES:
        continue
    
    display_name = filename_to_display(filename)
    primary_agents[display_name] = get_agent_config(display_name, filename)
    discovered.append(display_name)

# Sort agents: ordered ones first, then alphabetical
def sort_key(name):
    if name in AGENT_ORDER:
        return (0, AGENT_ORDER.index(name))
    return (1, name.lower())

sorted_agents = dict(sorted(primary_agents.items(), key=lambda x: sort_key(x[0])))

config['agent'] = sorted_agents

print(f"  Auto-discovered {len(sorted_agents)} primary agents from {agents_dir}")
print(f"  Order: {', '.join(list(sorted_agents.keys())[:5])}...")

# =============================================================================
# MCP SERVERS - Ensure required MCP servers are configured
# =============================================================================

if 'mcp' not in config:
    config['mcp'] = {}

if 'tools' not in config:
    config['tools'] = {}

# osgrep MCP - local semantic search (primary, try first)
# Install: npm install -g osgrep && osgrep install-opencode
if 'osgrep' not in config['mcp']:
    config['mcp']['osgrep'] = {
        "type": "local",
        "command": ["osgrep", "mcp"],
        "enabled": True
    }

# Ensure osgrep_* is disabled globally (enabled per-agent)
if 'osgrep_*' not in config['tools']:
    config['tools']['osgrep_*'] = False

# Outscraper MCP - for business intelligence extraction (subagent only)
if 'outscraper' not in config['mcp']:
    config['mcp']['outscraper'] = {
        "type": "local",
        "command": ["/bin/bash", "-c", "OUTSCRAPER_API_KEY=$OUTSCRAPER_API_KEY uv tool run outscraper-mcp-server"],
        "enabled": True
    }
    print("  Added outscraper MCP server")

if 'outscraper_*' not in config['tools']:
    config['tools']['outscraper_*'] = False
    print("  Added outscraper_* to tools (disabled globally, enabled for @outscraper subagent)")

# DataForSEO MCP - for comprehensive SEO data
# Uses bun x if available, falls back to npx
import shutil
bun_path = shutil.which('bun')
npx_path = shutil.which('npx') or '/opt/homebrew/bin/npx'
pkg_runner = f"{bun_path} x" if bun_path else npx_path

if 'dataforseo' not in config['mcp']:
    config['mcp']['dataforseo'] = {
        "type": "local",
        "command": ["/bin/bash", "-c", f"source ~/.config/aidevops/mcp-env.sh && DATAFORSEO_USERNAME=$DATAFORSEO_USERNAME DATAFORSEO_PASSWORD=$DATAFORSEO_PASSWORD {pkg_runner} dataforseo-mcp-server"],
        "enabled": True
    }
    print("  Added dataforseo MCP server")

if 'dataforseo_*' not in config['tools']:
    config['tools']['dataforseo_*'] = False
    print("  Added dataforseo_* to tools (disabled globally, enabled for SEO agent)")

# Serper MCP - for Google Search API
if 'serper' not in config['mcp']:
    config['mcp']['serper'] = {
        "type": "local",
        "command": ["/bin/bash", "-c", f"source ~/.config/aidevops/mcp-env.sh && SERPER_API_KEY=$SERPER_API_KEY {pkg_runner} serper-mcp-server"],
        "enabled": True
    }
    print("  Added serper MCP server")

if 'serper_*' not in config['tools']:
    config['tools']['serper_*'] = False
    print("  Added serper_* to tools (disabled globally, enabled for SEO agent)")

# Playwriter MCP - browser automation via Chrome extension
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
    print("  Added playwriter MCP server (install Chrome extension separately)")

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
        serper)
            extra_tools=$'  serper_*: true\n  webfetch: true'
            ;;
        playwriter)
            extra_tools=$'  playwriter_*: true'
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
    ((subagent_count++))
done < <(find "$AGENTS_DIR" -mindepth 2 -name "*.md" -type f | sort)

echo -e "  ${GREEN}✓${NC} Generated $subagent_count subagent files"

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo -e "${GREEN}Done!${NC}"
echo "  Primary agents: Auto-discovered from ~/.aidevops/agents/*.md (Tab-switchable)"
echo "  Subagents: $subagent_count auto-discovered from subfolders (@mentionable)"
echo "  AGENTS.md: ~/.config/opencode/AGENTS.md"
echo ""
echo "Tab order: Plan+ → Build+ → Build-Agent → Build-MCP → AI-DevOps → (alphabetical)"
echo ""
echo "To add a new primary agent: Create ~/.aidevops/agents/{name}.md"
echo "To add a new subagent: Create ~/.aidevops/agents/{folder}/{name}.md"
echo ""
echo "Restart OpenCode to load new configuration."
