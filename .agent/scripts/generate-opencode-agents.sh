#!/bin/bash
# =============================================================================
# Generate OpenCode Agent Configuration
# =============================================================================
# Architecture:
#   - Primary agents: Defined in opencode.json (controls Tab order & MCP access)
#   - Subagents: Markdown files in ~/.config/opencode/agent/ (@mentionable)
#   - AGENTS.md: At ~/.config/opencode/AGENTS.md (global context reference)
#
# Source: ~/.aidevops/agents/
#   - Root .md files = Primary agents (defined in JSON for ordering)
#   - Subfolder .md files = Subagents (generated as markdown)
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

# Ensure AGENTS.md exists at config level
if [[ ! -f "$OPENCODE_CONFIG_DIR/AGENTS.md" ]]; then
    echo 'Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities.' > "$OPENCODE_CONFIG_DIR/AGENTS.md"
    echo -e "  ${GREEN}✓${NC} Created AGENTS.md"
fi

# Remove old primary agent markdown files (they're now in JSON)
for f in Accounting.md AI-DevOps.md Build+.md Content.md Health.md Legal.md Marketing.md Research.md Sales.md SEO.md WordPress.md; do
    rm -f "$OPENCODE_AGENT_DIR/$f"
done

# =============================================================================
# PRIMARY AGENTS - Defined in opencode.json for Tab order control
# =============================================================================

echo -e "${BLUE}Configuring primary agents in opencode.json...${NC}"

# Check if opencode.json exists
if [[ ! -f "$OPENCODE_CONFIG" ]]; then
    echo -e "${YELLOW}Warning: $OPENCODE_CONFIG not found. Creating minimal config.${NC}"
    echo '{"$schema": "https://opencode.ai/config.json"}' > "$OPENCODE_CONFIG"
fi

# Use Python to update the agent section (preserves other config)
python3 << 'PYEOF'
import json
import sys

config_path = sys.argv[1] if len(sys.argv) > 1 else "/Users/marcusquinn/.config/opencode/opencode.json"

try:
    with open(config_path, 'r') as f:
        config = json.load(f)
except:
    config = {"$schema": "https://opencode.ai/config.json"}

# Primary agents in desired order (Build+ first, then alphabetical)
# Each agent specifies which MCP tools it can access
primary_agents = {
    "Build+": {
        "description": "Read ~/.aidevops/agents/build-plus.md",
        "mode": "primary",
        "temperature": 0.2,
        "tools": {
            "write": True,
            "edit": True,
            "bash": True,
            "read": True,
            "glob": True,
            "grep": True,
            "webfetch": True,
            "task": True,
            "context7_*": True
        }
    },
    "Accounting": {
        "description": "Read ~/.aidevops/agents/accounting.md",
        "mode": "primary",
        "temperature": 0.1,
        "tools": {
            "write": True,
            "edit": True,
            "bash": True,
            "read": True,
            "glob": True,
            "grep": True,
            "webfetch": True,
            "task": True,
            "quickfile_*": True
        }
    },
    "AI-DevOps": {
        "description": "Read ~/.aidevops/agents/aidevops.md",
        "mode": "primary",
        "temperature": 0.2,
        "tools": {
            "write": True,
            "edit": True,
            "bash": True,
            "read": True,
            "glob": True,
            "grep": True,
            "webfetch": True,
            "task": True,
            "context7_*": True,
            "repomix_*": True
        }
    },
    "Content": {
        "description": "Read ~/.aidevops/agents/content.md",
        "mode": "primary",
        "temperature": 0.3,
        "tools": {
            "write": True,
            "edit": True,
            "read": True,
            "webfetch": True
        }
    },
    "Health": {
        "description": "Read ~/.aidevops/agents/health.md",
        "mode": "primary",
        "temperature": 0.2,
        "tools": {
            "write": True,
            "read": True
        }
    },
    "Legal": {
        "description": "Read ~/.aidevops/agents/legal.md",
        "mode": "primary",
        "temperature": 0.1,
        "tools": {
            "write": True,
            "read": True
        }
    },
    "Marketing": {
        "description": "Read ~/.aidevops/agents/marketing.md",
        "mode": "primary",
        "temperature": 0.3,
        "tools": {
            "write": True,
            "read": True,
            "webfetch": True
        }
    },
    "Research": {
        "description": "Read ~/.aidevops/agents/research.md",
        "mode": "primary",
        "temperature": 0.3,
        "tools": {
            "read": True,
            "webfetch": True,
            "bash": True,
            "context7_*": True
        }
    },
    "Sales": {
        "description": "Read ~/.aidevops/agents/sales.md",
        "mode": "primary",
        "temperature": 0.2,
        "tools": {
            "write": True,
            "read": True,
            "webfetch": True
        }
    },
    "SEO": {
        "description": "Read ~/.aidevops/agents/seo.md",
        "mode": "primary",
        "temperature": 0.2,
        "tools": {
            "write": True,
            "read": True,
            "bash": True,
            "webfetch": True,
            "gsc_*": True,
            "ahrefs_*": True
        }
    },
    "WordPress": {
        "description": "Read ~/.aidevops/agents/wordpress.md",
        "mode": "primary",
        "temperature": 0.2,
        "tools": {
            "write": True,
            "edit": True,
            "bash": True,
            "read": True,
            "glob": True,
            "grep": True,
            "localwp_*": True,
            "context7_*": True
        }
    }
}

config['agent'] = primary_agents

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
while IFS= read -r f; do
    name=$(basename "$f" .md)
    [[ "$name" == "AGENTS" || "$name" == "README" ]] && continue
    
    rel_path="${f#$AGENTS_DIR/}"
    
    cat > "$OPENCODE_AGENT_DIR/$name.md" << EOF
---
description: Read ~/.aidevops/agents/${rel_path}
mode: subagent
temperature: 0.2
tools:
  read: true
  bash: true
---
EOF
    ((subagent_count++))
done < <(find "$AGENTS_DIR" -mindepth 2 -name "*.md" -type f | sort)

echo -e "  ${GREEN}✓${NC} Generated $subagent_count subagent files"

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo -e "${GREEN}Done!${NC}"
echo "  Primary agents: 11 (in opencode.json, Tab-switchable)"
echo "  Subagents: $subagent_count (in ~/.config/opencode/agent/, @mentionable)"
echo "  AGENTS.md: ~/.config/opencode/AGENTS.md"
echo ""
echo "Restart OpenCode to load new configuration."
