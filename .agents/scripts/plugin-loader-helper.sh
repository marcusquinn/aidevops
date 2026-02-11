#!/usr/bin/env bash
# =============================================================================
# Plugin Loader Helper
# =============================================================================
# Core plugin structure and agent loader for the aidevops framework.
# Discovers installed plugins, validates manifests, loads agent definitions,
# and manages plugin lifecycle hooks (init, load, unload).
#
# Usage:
#   plugin-loader-helper.sh discover              List all installed plugins
#   plugin-loader-helper.sh load [namespace]       Load plugin agents (all or specific)
#   plugin-loader-helper.sh unload <namespace>     Unload a plugin's agents
#   plugin-loader-helper.sh validate [namespace]   Validate plugin manifest(s)
#   plugin-loader-helper.sh agents [namespace]     List agents provided by plugin(s)
#   plugin-loader-helper.sh hooks <namespace> <hook>  Run a lifecycle hook
#   plugin-loader-helper.sh index                  Generate plugin entries for subagent-index
#   plugin-loader-helper.sh status                 Show plugin system status
#   plugin-loader-helper.sh help                   Show this help
#
# Manifest: Plugins declare capabilities via plugin.json in their namespace root.
# See .agents/aidevops/plugins.md for full documentation.
#
# Author: AI DevOps Framework
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-$HOME/.aidevops/agents}"
PLUGINS_FILE="${AIDEVOPS_CONFIG_DIR:-$HOME/.config/aidevops}/plugins.json"
PLUGIN_CACHE_DIR="${HOME}/.aidevops/.agent-workspace/tmp/plugin-cache"

# =============================================================================
# Logging
# =============================================================================

log_info() {
    local msg="$1"
    echo -e "${BLUE:-}[plugin-loader]${NC:-} $msg"
    return 0
}

log_success() {
    local msg="$1"
    echo -e "${GREEN:-}[OK]${NC:-} $msg"
    return 0
}

log_warning() {
    local msg="$1"
    echo -e "${YELLOW:-}[WARN]${NC:-} $msg"
    return 0
}

log_error() {
    local msg="$1"
    echo -e "${RED:-}[ERROR]${NC:-} $msg"
    return 0
}

# =============================================================================
# Plugin Discovery
# =============================================================================

# Get list of enabled plugin namespaces from plugins.json
# Returns: newline-separated list of namespace strings
get_enabled_namespaces() {
    if [[ ! -f "$PLUGINS_FILE" ]]; then
        return 0
    fi
    if ! command -v jq &>/dev/null; then
        log_warning "jq not found; cannot read plugins.json"
        return 0
    fi
    jq -r '.plugins[] | select(.enabled != false) | .namespace // empty' "$PLUGINS_FILE" 2>/dev/null || true
    return 0
}

# Get all plugin namespaces (enabled and disabled)
get_all_namespaces() {
    if [[ ! -f "$PLUGINS_FILE" ]]; then
        return 0
    fi
    if ! command -v jq &>/dev/null; then
        log_warning "jq not found; cannot read plugins.json"
        return 0
    fi
    jq -r '.plugins[].namespace // empty' "$PLUGINS_FILE" 2>/dev/null || true
    return 0
}

# Get a field from a plugin entry in plugins.json
# Arguments: namespace, field_name
get_plugin_field() {
    local namespace="$1"
    local field="$2"
    if [[ ! -f "$PLUGINS_FILE" ]]; then
        return 0
    fi
    jq -r --arg ns "$namespace" --arg f "$field" \
        '.plugins[] | select(.namespace == $ns) | .[$f] // empty' \
        "$PLUGINS_FILE" 2>/dev/null || echo ""
    return 0
}

# Check if a namespace is a valid installed plugin
# Arguments: namespace
# Returns: 0 if valid, 1 if not
is_valid_plugin() {
    local namespace="$1"
    local plugin_dir="$AGENTS_DIR/$namespace"

    if [[ ! -d "$plugin_dir" ]]; then
        return 1
    fi

    # Check it's registered in plugins.json
    local registered
    registered=$(get_plugin_field "$namespace" "name")
    if [[ -z "$registered" ]]; then
        return 1
    fi

    return 0
}

# Discover all installed plugins and their status
# Output: tab-separated lines: namespace, name, enabled, has_manifest, agent_count
cmd_discover() {
    if [[ ! -f "$PLUGINS_FILE" ]]; then
        echo "No plugins configured (plugins.json not found)"
        return 0
    fi

    local count
    count=$(jq '.plugins | length' "$PLUGINS_FILE" 2>/dev/null || echo "0")

    if [[ "$count" == "0" ]]; then
        echo "No plugins installed."
        echo ""
        echo "Add a plugin: aidevops plugin add <repo-url> --namespace <name>"
        return 0
    fi

    echo "Discovered plugins ($count):"
    echo ""
    printf "  %-12s %-15s %-8s %-10s %-8s\n" "NAMESPACE" "NAME" "ENABLED" "MANIFEST" "AGENTS"
    printf "  %-12s %-15s %-8s %-10s %-8s\n" "---------" "----" "-------" "--------" "------"

    while IFS=$'\t' read -r ns name enabled; do
        [[ -z "$ns" ]] && continue

        local has_manifest="no"
        local agent_count=0
        local plugin_dir="$AGENTS_DIR/$ns"

        if [[ -d "$plugin_dir" ]]; then
            # Check for manifest
            if [[ -f "$plugin_dir/plugin.json" ]]; then
                has_manifest="yes"
            fi

            # Count agent files
            agent_count=$(find "$plugin_dir" -name '*.md' -not -name 'README*' -not -name 'AGENTS*' -not -name '*-skill.md' 2>/dev/null | wc -l | tr -d ' ')
        fi

        local enabled_str="yes"
        if [[ "$enabled" == "false" ]]; then
            enabled_str="no"
        fi

        printf "  %-12s %-15s %-8s %-10s %-8s\n" "$ns" "$name" "$enabled_str" "$has_manifest" "$agent_count"
    done < <(jq -r '.plugins[] | [.namespace, .name, (.enabled // true | tostring)] | @tsv' "$PLUGINS_FILE" 2>/dev/null)

    return 0
}

# =============================================================================
# Manifest Validation
# =============================================================================

# Validate a plugin manifest (plugin.json)
# Arguments: namespace
# Returns: 0 if valid, 1 if invalid or missing
validate_manifest() {
    local namespace="$1"
    local plugin_dir="$AGENTS_DIR/$namespace"
    local manifest="$plugin_dir/plugin.json"

    if [[ ! -d "$plugin_dir" ]]; then
        log_error "Plugin directory not found: $plugin_dir"
        return 1
    fi

    # Manifest is optional — plugins work without it (backward compatible)
    if [[ ! -f "$manifest" ]]; then
        log_info "No manifest found for '$namespace' (using defaults)"
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        log_warning "jq not found; cannot validate manifest"
        return 0
    fi

    # Validate JSON syntax
    if ! jq empty "$manifest" 2>/dev/null; then
        log_error "Invalid JSON in $manifest"
        return 1
    fi

    local errors=0

    # Check required fields
    local name
    name=$(jq -r '.name // empty' "$manifest" 2>/dev/null)
    if [[ -z "$name" ]]; then
        log_error "Manifest missing required field: name"
        errors=$((errors + 1))
    fi

    local version
    version=$(jq -r '.version // empty' "$manifest" 2>/dev/null)
    if [[ -z "$version" ]]; then
        log_error "Manifest missing required field: version"
        errors=$((errors + 1))
    fi

    # Validate version format (semver-like)
    if [[ -n "$version" ]] && [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
        log_warning "Version '$version' is not semver format (expected: X.Y.Z)"
    fi

    # Validate agents array if present
    local agents_count
    agents_count=$(jq '.agents | length // 0' "$manifest" 2>/dev/null || echo "0")
    if [[ "$agents_count" -gt 0 ]]; then
        # Check each agent has required fields
        local i=0
        while [[ "$i" -lt "$agents_count" ]]; do
            local agent_file
            agent_file=$(jq -r --argjson i "$i" '.agents[$i].file // empty' "$manifest" 2>/dev/null)
            if [[ -z "$agent_file" ]]; then
                log_error "Agent entry $i missing required field: file"
                errors=$((errors + 1))
            elif [[ ! -f "$plugin_dir/$agent_file" ]]; then
                log_warning "Agent file not found: $plugin_dir/$agent_file"
            fi
            i=$((i + 1))
        done
    fi

    # Validate hooks if present
    local hooks
    hooks=$(jq -r '.hooks // empty | keys[]' "$manifest" 2>/dev/null || true)
    if [[ -n "$hooks" ]]; then
        while IFS= read -r hook; do
            local hook_script
            hook_script=$(jq -r --arg h "$hook" '.hooks[$h] // empty' "$manifest" 2>/dev/null)
            if [[ -n "$hook_script" && ! -f "$plugin_dir/$hook_script" ]]; then
                log_warning "Hook script not found: $plugin_dir/$hook_script (hook: $hook)"
            fi
        done <<< "$hooks"
    fi

    # Validate min_version if present
    local min_version
    min_version=$(jq -r '.min_aidevops_version // empty' "$manifest" 2>/dev/null)
    if [[ -n "$min_version" ]]; then
        local current_version
        current_version=$(cat "$HOME/.aidevops/version" 2>/dev/null || echo "0.0.0")
        # Simple version comparison (major.minor only)
        local min_major min_minor cur_major cur_minor
        min_major=$(echo "$min_version" | cut -d. -f1)
        min_minor=$(echo "$min_version" | cut -d. -f2)
        cur_major=$(echo "$current_version" | cut -d. -f1)
        cur_minor=$(echo "$current_version" | cut -d. -f2)
        if [[ "$cur_major" -lt "$min_major" ]] || { [[ "$cur_major" -eq "$min_major" ]] && [[ "$cur_minor" -lt "$min_minor" ]]; }; then
            log_warning "Plugin requires aidevops >= $min_version (current: $current_version)"
        fi
    fi

    if [[ "$errors" -gt 0 ]]; then
        log_error "Manifest validation failed with $errors error(s)"
        return 1
    fi

    log_success "Manifest valid for '$namespace'"
    return 0
}

# Validate all plugin manifests
cmd_validate() {
    local target="${1:-}"
    local failed=0

    if [[ -n "$target" ]]; then
        if ! is_valid_plugin "$target"; then
            log_error "Plugin '$target' not found"
            return 1
        fi
        validate_manifest "$target"
        return $?
    fi

    # Validate all enabled plugins
    local namespaces
    namespaces=$(get_enabled_namespaces)
    if [[ -z "$namespaces" ]]; then
        echo "No enabled plugins to validate."
        return 0
    fi

    while IFS= read -r ns; do
        [[ -z "$ns" ]] && continue
        if ! validate_manifest "$ns"; then
            failed=$((failed + 1))
        fi
    done <<< "$namespaces"

    if [[ "$failed" -gt 0 ]]; then
        log_error "$failed plugin(s) failed validation"
        return 1
    fi

    log_success "All plugin manifests valid"
    return 0
}

# =============================================================================
# Agent Loading
# =============================================================================

# Load agents from a plugin namespace
# Reads plugin.json manifest if available, falls back to directory scanning
# Arguments: namespace
# Output: tab-separated lines: name, file, description, model_tier
load_plugin_agents() {
    local namespace="$1"
    local plugin_dir="$AGENTS_DIR/$namespace"
    local manifest="$plugin_dir/plugin.json"

    if [[ ! -d "$plugin_dir" ]]; then
        return 0
    fi

    # If manifest exists and has agents array, use it
    if [[ -f "$manifest" ]] && command -v jq &>/dev/null; then
        local agents_count
        agents_count=$(jq '.agents | length // 0' "$manifest" 2>/dev/null || echo "0")

        if [[ "$agents_count" -gt 0 ]]; then
            jq -r --arg ns "$namespace" '.agents[] | [
                .name // (.file | sub("\\.md$"; "")),
                ($ns + "/" + .file),
                .description // "",
                .model // "sonnet"
            ] | @tsv' "$manifest" 2>/dev/null || true
            return 0
        fi
    fi

    # Fallback: scan directory for .md files and parse frontmatter
    local md_files
    md_files=$(find "$plugin_dir" -name '*.md' \
        -not -name 'README*' \
        -not -name 'AGENTS*' \
        -not -name '*-skill.md' \
        -not -path '*/node_modules/*' \
        -not -path '*/.git/*' \
        2>/dev/null | sort)

    if [[ -z "$md_files" ]]; then
        return 0
    fi

    while IFS= read -r md_file; do
        [[ -z "$md_file" ]] && continue

        local rel_path="${md_file#"$AGENTS_DIR/"}"
        local base_name
        base_name=$(basename "$md_file" .md)

        # Extract description from frontmatter if available
        local description=""
        local model="sonnet"
        if head -1 "$md_file" 2>/dev/null | grep -q '^---'; then
            # Parse YAML frontmatter (lightweight)
            local frontmatter
            frontmatter=$(sed -n '2,/^---$/p' "$md_file" 2>/dev/null | head -20)
            description=$(echo "$frontmatter" | grep -E '^description:' | sed 's/^description:\s*//' | head -1)
            local fm_model
            fm_model=$(echo "$frontmatter" | grep -E '^model:' | sed 's/^model:\s*//' | head -1)
            if [[ -n "$fm_model" ]]; then
                model="$fm_model"
            fi
        fi

        # If no description from frontmatter, use first heading
        if [[ -z "$description" ]]; then
            description=$(grep -m1 '^# ' "$md_file" 2>/dev/null | sed 's/^# //')
        fi

        printf "%s\t%s\t%s\t%s\n" "$base_name" "$rel_path" "$description" "$model"
    done <<< "$md_files"

    return 0
}

# Load all enabled plugin agents
cmd_load() {
    local target="${1:-}"

    if [[ -n "$target" ]]; then
        if ! is_valid_plugin "$target"; then
            log_error "Plugin '$target' not found or not registered"
            return 1
        fi

        # Run init hook if available
        run_hook "$target" "init" 2>/dev/null || true

        local agents
        agents=$(load_plugin_agents "$target")
        if [[ -z "$agents" ]]; then
            log_info "No agents found in plugin '$target'"
            return 0
        fi

        log_success "Loaded agents from '$target':"
        echo "$agents" | while IFS=$'\t' read -r name file desc model; do
            printf "  %-20s %-30s %s\n" "$name" "$file" "$desc"
        done

        # Run load hook if available
        run_hook "$target" "load" 2>/dev/null || true
        return 0
    fi

    # Load all enabled plugins
    local namespaces
    namespaces=$(get_enabled_namespaces)
    if [[ -z "$namespaces" ]]; then
        echo "No enabled plugins to load."
        return 0
    fi

    local total_agents=0
    local total_plugins=0

    while IFS= read -r ns; do
        [[ -z "$ns" ]] && continue

        # Run init hook
        run_hook "$ns" "init" 2>/dev/null || true

        local agents
        agents=$(load_plugin_agents "$ns")
        if [[ -n "$agents" ]]; then
            local count
            count=$(echo "$agents" | wc -l | tr -d ' ')
            total_agents=$((total_agents + count))
            total_plugins=$((total_plugins + 1))
            log_info "Loaded $count agent(s) from '$ns'"
        fi

        # Run load hook
        run_hook "$ns" "load" 2>/dev/null || true
    done <<< "$namespaces"

    log_success "Loaded $total_agents agent(s) from $total_plugins plugin(s)"
    return 0
}

# Unload a plugin's agents (run unload hook)
cmd_unload() {
    local namespace="${1:-}"

    if [[ -z "$namespace" ]]; then
        log_error "Namespace required"
        echo "Usage: plugin-loader-helper.sh unload <namespace>"
        return 1
    fi

    if ! is_valid_plugin "$namespace"; then
        log_error "Plugin '$namespace' not found"
        return 1
    fi

    # Run unload hook
    run_hook "$namespace" "unload"

    log_success "Unloaded plugin '$namespace'"
    return 0
}

# List agents from plugin(s)
cmd_agents() {
    local target="${1:-}"

    if [[ -n "$target" ]]; then
        if ! is_valid_plugin "$target"; then
            log_error "Plugin '$target' not found"
            return 1
        fi

        local agents
        agents=$(load_plugin_agents "$target")
        if [[ -z "$agents" ]]; then
            echo "No agents found in plugin '$target'"
            return 0
        fi

        echo "Agents in plugin '$target':"
        echo ""
        printf "  %-20s %-35s %-8s %s\n" "NAME" "FILE" "MODEL" "DESCRIPTION"
        printf "  %-20s %-35s %-8s %s\n" "----" "----" "-----" "-----------"

        echo "$agents" | while IFS=$'\t' read -r name file desc model; do
            printf "  %-20s %-35s %-8s %s\n" "$name" "$file" "$model" "$desc"
        done
        return 0
    fi

    # List agents from all enabled plugins
    local namespaces
    namespaces=$(get_enabled_namespaces)
    if [[ -z "$namespaces" ]]; then
        echo "No enabled plugins."
        return 0
    fi

    echo "Plugin agents:"
    echo ""
    printf "  %-12s %-20s %-35s %-8s %s\n" "PLUGIN" "NAME" "FILE" "MODEL" "DESCRIPTION"
    printf "  %-12s %-20s %-35s %-8s %s\n" "------" "----" "----" "-----" "-----------"

    while IFS= read -r ns; do
        [[ -z "$ns" ]] && continue
        local agents
        agents=$(load_plugin_agents "$ns")
        if [[ -n "$agents" ]]; then
            echo "$agents" | while IFS=$'\t' read -r name file desc model; do
                printf "  %-12s %-20s %-35s %-8s %s\n" "$ns" "$name" "$file" "$model" "$desc"
            done
        fi
    done <<< "$namespaces"

    return 0
}

# =============================================================================
# Lifecycle Hooks
# =============================================================================

# Run a lifecycle hook for a plugin
# Arguments: namespace, hook_name (init|load|unload)
# Returns: 0 on success or if no hook defined, 1 on hook failure
run_hook() {
    local namespace="$1"
    local hook_name="$2"
    local plugin_dir="$AGENTS_DIR/$namespace"
    local manifest="$plugin_dir/plugin.json"

    # Validate hook name
    case "$hook_name" in
        init|load|unload) ;;
        *)
            log_error "Invalid hook name: $hook_name (valid: init, load, unload)"
            return 1
            ;;
    esac

    local hook_script=""

    # Check manifest for hook definition
    if [[ -f "$manifest" ]] && command -v jq &>/dev/null; then
        hook_script=$(jq -r --arg h "$hook_name" '.hooks[$h] // empty' "$manifest" 2>/dev/null)
    fi

    # Fallback: check for conventional hook script names
    if [[ -z "$hook_script" ]]; then
        local conventional="scripts/on-${hook_name}.sh"
        if [[ -f "$plugin_dir/$conventional" ]]; then
            hook_script="$conventional"
        fi
    fi

    # No hook defined — that's fine
    if [[ -z "$hook_script" ]]; then
        return 0
    fi

    local full_path="$plugin_dir/$hook_script"
    if [[ ! -f "$full_path" ]]; then
        log_warning "Hook script not found: $full_path"
        return 0
    fi

    # Ensure executable
    if [[ ! -x "$full_path" ]]; then
        chmod +x "$full_path"
    fi

    log_info "Running $hook_name hook for '$namespace'..."

    # Run hook with plugin context environment variables
    local exit_code=0
    AIDEVOPS_PLUGIN_NAMESPACE="$namespace" \
    AIDEVOPS_PLUGIN_DIR="$plugin_dir" \
    AIDEVOPS_AGENTS_DIR="$AGENTS_DIR" \
    AIDEVOPS_HOOK="$hook_name" \
    bash "$full_path" || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        log_warning "Hook $hook_name for '$namespace' exited with code $exit_code"
        return 1
    fi

    return 0
}

# Run a specific hook via CLI
cmd_hooks() {
    local namespace="${1:-}"
    local hook="${2:-}"

    if [[ -z "$namespace" || -z "$hook" ]]; then
        log_error "Namespace and hook name required"
        echo "Usage: plugin-loader-helper.sh hooks <namespace> <hook>"
        echo "Hooks: init, load, unload"
        return 1
    fi

    if ! is_valid_plugin "$namespace"; then
        log_error "Plugin '$namespace' not found"
        return 1
    fi

    run_hook "$namespace" "$hook"
    return $?
}

# =============================================================================
# Subagent Index Integration
# =============================================================================

# Generate TOON-format subagent index entries for all plugin agents
# Output: TOON lines suitable for appending to subagent-index.toon
cmd_index() {
    local namespaces
    namespaces=$(get_enabled_namespaces)
    if [[ -z "$namespaces" ]]; then
        return 0
    fi

    local entries=()
    local plugin_count=0

    while IFS= read -r ns; do
        [[ -z "$ns" ]] && continue

        local agents
        agents=$(load_plugin_agents "$ns")
        if [[ -z "$agents" ]]; then
            continue
        fi

        # Collect agent files for this plugin
        local key_files=""
        while IFS=$'\t' read -r name file desc model; do
            local base
            base=$(basename "$file" .md)
            if [[ -n "$key_files" ]]; then
                key_files="${key_files}|${base}"
            else
                key_files="$base"
            fi
        done <<< "$agents"

        # Get plugin description from manifest or plugins.json
        local plugin_desc=""
        local manifest="$AGENTS_DIR/$ns/plugin.json"
        if [[ -f "$manifest" ]] && command -v jq &>/dev/null; then
            plugin_desc=$(jq -r '.description // empty' "$manifest" 2>/dev/null)
        fi
        if [[ -z "$plugin_desc" ]]; then
            local plugin_name
            plugin_name=$(get_plugin_field "$ns" "name")
            plugin_desc="Plugin: ${plugin_name:-$ns}"
        fi

        entries+=("${ns}/,${plugin_desc},${key_files}")
        plugin_count=$((plugin_count + 1))
    done <<< "$namespaces"

    if [[ "${#entries[@]}" -eq 0 ]]; then
        return 0
    fi

    # Output TOON format
    echo "<!--TOON:plugin_agents[${#entries[@]}]{folder,purpose,key_files}:"
    for entry in "${entries[@]}"; do
        echo "$entry"
    done
    echo "-->"

    return 0
}

# =============================================================================
# Status
# =============================================================================

cmd_status() {
    echo "Plugin System Status"
    echo "===================="
    echo ""

    # Check plugins.json
    if [[ -f "$PLUGINS_FILE" ]]; then
        local total enabled disabled
        total=$(jq '.plugins | length' "$PLUGINS_FILE" 2>/dev/null || echo "0")
        enabled=$(jq '[.plugins[] | select(.enabled != false)] | length' "$PLUGINS_FILE" 2>/dev/null || echo "0")
        disabled=$((total - enabled))
        echo "Plugins configured: $total ($enabled enabled, $disabled disabled)"
    else
        echo "Plugins configured: 0 (plugins.json not found)"
    fi

    # Count total agents across plugins
    local total_agents=0
    local namespaces
    namespaces=$(get_enabled_namespaces)
    if [[ -n "$namespaces" ]]; then
        while IFS= read -r ns; do
            [[ -z "$ns" ]] && continue
            local agents
            agents=$(load_plugin_agents "$ns")
            if [[ -n "$agents" ]]; then
                local count
                count=$(echo "$agents" | wc -l | tr -d ' ')
                total_agents=$((total_agents + count))
            fi
        done <<< "$namespaces"
    fi
    echo "Total plugin agents: $total_agents"

    # Check for manifests
    local with_manifest=0
    if [[ -n "$namespaces" ]]; then
        while IFS= read -r ns; do
            [[ -z "$ns" ]] && continue
            if [[ -f "$AGENTS_DIR/$ns/plugin.json" ]]; then
                with_manifest=$((with_manifest + 1))
            fi
        done <<< "$namespaces"
    fi
    echo "Plugins with manifest: $with_manifest"

    echo ""
    echo "Paths:"
    echo "  Plugins config: $PLUGINS_FILE"
    echo "  Agents dir:     $AGENTS_DIR"
    echo "  Cache dir:      $PLUGIN_CACHE_DIR"

    return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
    cat << 'EOF'
Plugin Loader Helper - Core plugin structure and agent loader

USAGE:
    plugin-loader-helper.sh <command> [options]

COMMANDS:
    discover              List all installed plugins with status
    load [namespace]      Load plugin agents (all enabled or specific)
    unload <namespace>    Unload a plugin (run unload hook)
    validate [namespace]  Validate plugin manifest(s)
    agents [namespace]    List agents provided by plugin(s)
    hooks <ns> <hook>     Run a lifecycle hook (init, load, unload)
    index                 Generate TOON entries for subagent-index
    status                Show plugin system status
    help                  Show this help

MANIFEST FORMAT (plugin.json):
    {
      "name": "my-plugin",
      "version": "1.0.0",
      "description": "What this plugin does",
      "min_aidevops_version": "2.100.0",
      "agents": [
        {
          "file": "my-agent.md",
          "name": "my-agent",
          "description": "Agent purpose",
          "model": "sonnet"
        }
      ],
      "hooks": {
        "init": "scripts/on-init.sh",
        "load": "scripts/on-load.sh",
        "unload": "scripts/on-unload.sh"
      },
      "scripts": ["scripts/my-helper.sh"],
      "dependencies": []
    }

LIFECYCLE HOOKS:
    init     Run once when plugin is first installed or updated
    load     Run each time plugin agents are loaded into a session
    unload   Run when plugin is disabled or removed

    Hooks receive environment variables:
      AIDEVOPS_PLUGIN_NAMESPACE  Plugin namespace
      AIDEVOPS_PLUGIN_DIR        Plugin directory path
      AIDEVOPS_AGENTS_DIR        Root agents directory
      AIDEVOPS_HOOK              Current hook name

EXAMPLES:
    plugin-loader-helper.sh discover
    plugin-loader-helper.sh load pro
    plugin-loader-helper.sh validate
    plugin-loader-helper.sh agents pro
    plugin-loader-helper.sh hooks pro init
    plugin-loader-helper.sh index >> subagent-index.toon
    plugin-loader-helper.sh status
EOF
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        discover|disc|d)    cmd_discover "$@" ;;
        load|l)             cmd_load "$@" ;;
        unload|ul)          cmd_unload "$@" ;;
        validate|val|v)     cmd_validate "$@" ;;
        agents|ag|a)        cmd_agents "$@" ;;
        hooks|hook|h)       cmd_hooks "$@" ;;
        index|idx|i)        cmd_index "$@" ;;
        status|st|s)        cmd_status "$@" ;;
        help|--help|-h)     show_help ;;
        *)
            log_error "Unknown command: $command"
            echo "Run 'plugin-loader-helper.sh help' for usage."
            return 1
            ;;
    esac
}

main "$@"
