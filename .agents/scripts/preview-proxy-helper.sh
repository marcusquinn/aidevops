#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# =============================================================================
# Preview Proxy Helper — per-worktree preview subdomains via local proxy
# =============================================================================
# Allocates unique ports per worktree branch and registers proxy routes so
# every worktree dev server gets its own subdomain.
#
# Usage:
#   preview-proxy-helper.sh allocate <repo_slug> <branch>
#   preview-proxy-helper.sh free <repo_slug> <branch>
#   preview-proxy-helper.sh list [<repo_slug>]
#   preview-proxy-helper.sh status
#   preview-proxy-helper.sh help
#
# State: ~/.aidevops/state/worktree-ports.json
# Config: ~/.config/aidevops/preview-proxy.json (optional)
#
# Design: GH#21560
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
readonly PP_STATE_DIR="${HOME}/.aidevops/state"
readonly PP_STATE_FILE="${PP_STATE_DIR}/worktree-ports.json"
readonly PP_CONFIG_FILE="${HOME}/.config/aidevops/preview-proxy.json"
readonly PP_BACKENDS_DIR="${SCRIPT_DIR}/preview-proxy-backends"

# Default port pool: 3100-3199 per project, 3200-3999 global overflow
readonly PP_DEFAULT_POOL_START=3100
readonly PP_DEFAULT_POOL_END=3199
readonly PP_GLOBAL_POOL_START=3200
readonly PP_GLOBAL_POOL_END=3999

# DNS label max length
readonly PP_DNS_LABEL_MAX=63

# -----------------------------------------------------------------------------
# State management
# -----------------------------------------------------------------------------

# Ensure state file exists with valid JSON.
_pp_ensure_state() {
    mkdir -p "$PP_STATE_DIR"
    if [[ ! -f "$PP_STATE_FILE" ]]; then
        echo '{}' > "$PP_STATE_FILE"
    fi
    return 0
}

# Read a value from state JSON. Returns empty string if not found.
_pp_state_get() {
    local jq_expr="$1"
    if ! command -v jq >/dev/null 2>&1; then
        print_warning "jq not installed — preview proxy state unavailable"
        return 1
    fi
    jq -r "$jq_expr // empty" "$PP_STATE_FILE" 2>/dev/null || echo ""
    return 0
}

# Write state atomically via temp file.
_pp_state_write() {
    local new_json="$1"
    local tmp_file="${PP_STATE_FILE}.tmp.$$"
    echo "$new_json" > "$tmp_file"
    mv -f "$tmp_file" "$PP_STATE_FILE"
    return 0
}

# -----------------------------------------------------------------------------
# Config helpers
# -----------------------------------------------------------------------------

# Read config value with fallback.
_pp_config_get() {
    local jq_expr="$1"
    local fallback="${2:-}"
    if [[ ! -f "$PP_CONFIG_FILE" ]] || ! command -v jq >/dev/null 2>&1; then
        echo "$fallback"
        return 0
    fi
    local val
    val="$(jq -r "$jq_expr // empty" "$PP_CONFIG_FILE" 2>/dev/null)" || val=""
    if [[ -z "$val" ]]; then
        echo "$fallback"
    else
        echo "$val"
    fi
    return 0
}

# Get the configured backend name (default: none / static fallback).
_pp_backend_name() {
    _pp_config_get '.backend' ''
    return 0
}

# Get the domain template (default: {branch_slug}.{repo}.local).
_pp_domain_template() {
    _pp_config_get '.domain_template' '{branch_slug}.{repo}.local'
    return 0
}

# Get port pool range for a given repo slug.
_pp_port_pool() {
    local repo_slug="$1"
    local pool_start pool_end
    pool_start="$(_pp_config_get ".port_pool.\"${repo_slug}\".start // .port_pool.default[0]" "$PP_DEFAULT_POOL_START")"
    pool_end="$(_pp_config_get ".port_pool.\"${repo_slug}\".end // .port_pool.default[1]" "$PP_DEFAULT_POOL_END")"
    echo "${pool_start}:${pool_end}"
    return 0
}

# -----------------------------------------------------------------------------
# Branch slug sanitization (DNS-safe)
# -----------------------------------------------------------------------------

# Sanitize a branch name to a DNS-safe subdomain label.
# Strips common prefixes, lowercases, replaces invalid chars, truncates.
branch_to_slug() {
    local branch="$1"
    local slug="$branch"

    # Strip common worktree prefixes
    slug="${slug#feature/}"
    slug="${slug#bugfix/}"
    slug="${slug#hotfix/}"
    slug="${slug#refactor/}"
    slug="${slug#chore/}"
    slug="${slug#experiment/}"
    slug="${slug#release/}"
    slug="${slug#fix/}"

    # Lowercase
    slug="$(echo "$slug" | tr '[:upper:]' '[:lower:]')"

    # Replace non-alphanumeric (except hyphen) with hyphen
    slug="$(echo "$slug" | sed 's/[^a-z0-9-]/-/g')"

    # Collapse repeated hyphens
    slug="$(echo "$slug" | sed 's/--*/-/g')"

    # Trim leading/trailing hyphens
    slug="${slug#-}"
    slug="${slug%-}"

    # Truncate to DNS label max
    if [[ ${#slug} -gt $PP_DNS_LABEL_MAX ]]; then
        # Generate a short hash to avoid collisions after truncation
        local hash
        hash="$(echo -n "$branch" | shasum -a 256 | cut -c1-4)"
        local max_base=$((PP_DNS_LABEL_MAX - 5))  # room for -XXXX
        slug="${slug:0:$max_base}-${hash}"
    fi

    echo "$slug"
    return 0
}

# -----------------------------------------------------------------------------
# Port allocation
# -----------------------------------------------------------------------------

# Check if a port is currently in use.
_pp_port_in_use() {
    local port="$1"
    if lsof -ti:"$port" >/dev/null 2>&1; then
        return 0  # in use
    fi
    return 1
}

# Check if a port is already allocated in state.
_pp_port_allocated() {
    local port="$1"
    if ! command -v jq >/dev/null 2>&1; then
        return 1
    fi
    local count
    count="$(jq "[.. | objects | select(.port == $port)] | length" "$PP_STATE_FILE" 2>/dev/null)" || count=0
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    [[ "$count" -gt 0 ]]
}

# Find a free port in range. Returns the port number or empty string.
_pp_find_free_port() {
    local start="$1"
    local end="$2"
    local port

    for ((port = start; port <= end; port++)); do
        if ! _pp_port_allocated "$port" && ! _pp_port_in_use "$port"; then
            echo "$port"
            return 0
        fi
    done

    echo ""
    return 1
}

# Build the preview URL from template, repo, and branch slug.
_pp_build_url() {
    local repo_slug="$1"
    local branch_slug="$2"
    local port="$3"
    local template
    template="$(_pp_domain_template)"

    # Extract short repo name from slug (owner/repo -> repo)
    local repo_short="${repo_slug##*/}"

    local domain
    domain="${template//\{branch_slug\}/$branch_slug}"
    domain="${domain//\{repo\}/$repo_short}"

    local backend
    backend="$(_pp_backend_name)"

    if [[ -n "$backend" ]]; then
        # If a proxy backend is configured, use https
        echo "https://${domain}"
    else
        # Static fallback: just localhost with port
        echo "http://localhost:${port}"
    fi
    return 0
}

# Build the start hint from .aidevops.json in the worktree (if present).
_pp_build_start_hint() {
    local repo_slug="$1"
    local port="$2"

    # Try to find the project's .aidevops.json
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || repo_root=""

    if [[ -n "$repo_root" ]] && [[ -f "${repo_root}/.aidevops.json" ]] && command -v jq >/dev/null 2>&1; then
        local cmd port_env
        cmd="$(jq -r '.preview.command // empty' "${repo_root}/.aidevops.json" 2>/dev/null)" || cmd=""
        port_env="$(jq -r '.preview.port_env // empty' "${repo_root}/.aidevops.json" 2>/dev/null)" || port_env=""

        if [[ -n "$cmd" ]]; then
            if [[ -n "$port_env" ]]; then
                echo "${port_env}=${port} ${cmd}"
            else
                echo "AIDEVOPS_PREVIEW_PORT=${port} ${cmd}"
            fi
            return 0
        fi
    fi

    # Generic fallback
    echo "AIDEVOPS_PREVIEW_PORT=${port} <dev-command>"
    return 0
}

# -----------------------------------------------------------------------------
# Backend dispatch
# -----------------------------------------------------------------------------

# Register a route with the configured backend.
_pp_backend_register() {
    local repo_slug="$1"
    local branch_slug="$2"
    local port="$3"

    local backend
    backend="$(_pp_backend_name)"
    [[ -z "$backend" ]] && return 0  # no backend configured, static fallback

    local backend_script="${PP_BACKENDS_DIR}/${backend}.sh"
    if [[ ! -f "$backend_script" ]]; then
        print_warning "Preview proxy backend '$backend' not found at $backend_script"
        return 0  # non-fatal
    fi

    # shellcheck source=/dev/null
    source "$backend_script"

    if type pp_backend_register >/dev/null 2>&1; then
        pp_backend_register "$repo_slug" "$branch_slug" "$port" || {
            print_warning "Preview proxy backend registration failed (non-fatal)"
            return 0
        }
    fi
    return 0
}

# Deregister a route from the configured backend.
_pp_backend_deregister() {
    local repo_slug="$1"
    local branch_slug="$2"

    local backend
    backend="$(_pp_backend_name)"
    [[ -z "$backend" ]] && return 0

    local backend_script="${PP_BACKENDS_DIR}/${backend}.sh"
    if [[ ! -f "$backend_script" ]]; then
        return 0
    fi

    # shellcheck source=/dev/null
    source "$backend_script"

    if type pp_backend_deregister >/dev/null 2>&1; then
        pp_backend_deregister "$repo_slug" "$branch_slug" || {
            print_warning "Preview proxy backend deregistration failed (non-fatal)"
            return 0
        }
    fi
    return 0
}

# Shared jq format for allocation output — avoids repeating the string literal (ratchet).
# shellcheck disable=SC2016  # jq expression, not shell
readonly _PP_JQ_ALLOC_OUTPUT='{"port": ($port | tonumber), "url": $url, "start_hint": $hint}'
# shellcheck disable=SC2016
readonly _PP_JQ_STATE_ENTRY='.[$repo][$branch] = {"port": $port, "slug": $slug, "allocated_at": $ts}'

# Emit allocation JSON to stdout using the shared jq format.
_pp_emit_alloc_json() {
    local alloc_port="$1"
    local alloc_url="$2"
    local alloc_hint="$3"
    jq -n --arg port "$alloc_port" --arg url "$alloc_url" --arg hint "$alloc_hint" \
        "$_PP_JQ_ALLOC_OUTPUT"
    return 0
}

# -----------------------------------------------------------------------------
# Public commands
# -----------------------------------------------------------------------------

# Allocate a port + register proxy route for a branch.
# Output: JSON with port, url, start_hint on stdout.
cmd_allocate() {
    local repo_slug="$1"
    local branch="$2"

    if [[ -z "$repo_slug" ]] || [[ -z "$branch" ]]; then
        echo "Usage: preview-proxy-helper.sh allocate <repo_slug> <branch>" >&2
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        print_warning "jq required for preview proxy — skipping allocation"
        return 1
    fi

    _pp_ensure_state

    # Check if already allocated
    local existing_port
    existing_port="$(_pp_state_get ".\"${repo_slug}\".\"${branch}\".port")"
    if [[ -n "$existing_port" ]]; then
        local slug
        slug="$(branch_to_slug "$branch")"
        local url
        url="$(_pp_build_url "$repo_slug" "$slug" "$existing_port")"
        local hint
        hint="$(_pp_build_start_hint "$repo_slug" "$existing_port")"
        _pp_emit_alloc_json "$existing_port" "$url" "$hint"
        return 0
    fi

    # Get port pool
    local pool_range
    pool_range="$(_pp_port_pool "$repo_slug")"
    local pool_start="${pool_range%%:*}"
    local pool_end="${pool_range##*:}"

    # Find free port — try project pool first, then global overflow
    local port
    port="$(_pp_find_free_port "$pool_start" "$pool_end")" || port=""
    if [[ -z "$port" ]]; then
        port="$(_pp_find_free_port "$PP_GLOBAL_POOL_START" "$PP_GLOBAL_POOL_END")" || port=""
    fi

    if [[ -z "$port" ]]; then
        print_warning "No free ports available for preview proxy (pool ${pool_start}-${pool_end}, global ${PP_GLOBAL_POOL_START}-${PP_GLOBAL_POOL_END})"
        return 1
    fi

    # Generate branch slug
    local slug
    slug="$(branch_to_slug "$branch")"

    # Store allocation
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local updated_state
    updated_state="$(jq \
        --arg repo "$repo_slug" \
        --arg branch "$branch" \
        --argjson port "$port" \
        --arg slug "$slug" \
        --arg ts "$now" \
        "$_PP_JQ_STATE_ENTRY" \
        "$PP_STATE_FILE")"
    _pp_state_write "$updated_state"

    # Build output
    local url
    url="$(_pp_build_url "$repo_slug" "$slug" "$port")"
    local hint
    hint="$(_pp_build_start_hint "$repo_slug" "$port")"

    # Register with backend (best-effort)
    _pp_backend_register "$repo_slug" "$slug" "$port"

    # Output JSON
    _pp_emit_alloc_json "$port" "$url" "$hint"
    return 0
}

# Free a port + deregister proxy route for a branch.
cmd_free() {
    local repo_slug="$1"
    local branch="$2"

    if [[ -z "$repo_slug" ]] || [[ -z "$branch" ]]; then
        echo "Usage: preview-proxy-helper.sh free <repo_slug> <branch>" >&2
        return 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        return 0  # nothing to free without jq
    fi

    _pp_ensure_state

    # Check if allocation exists
    local existing_port
    existing_port="$(_pp_state_get ".\"${repo_slug}\".\"${branch}\".port")"
    if [[ -z "$existing_port" ]]; then
        return 0  # idempotent: already freed
    fi

    local slug
    slug="$(_pp_state_get ".\"${repo_slug}\".\"${branch}\".slug")"
    [[ -z "$slug" ]] && slug="$(branch_to_slug "$branch")"

    # Deregister from backend
    _pp_backend_deregister "$repo_slug" "$slug"

    # Remove from state
    local updated_state
    updated_state="$(jq \
        --arg repo "$repo_slug" \
        --arg branch "$branch" \
        'del(.[$repo][$branch]) | if .[$repo] == {} then del(.[$repo]) else . end' \
        "$PP_STATE_FILE")"
    _pp_state_write "$updated_state"

    echo "Freed port ${existing_port} for ${repo_slug}/${branch}"
    return 0
}

# List all allocations.
cmd_list() {
    local filter_slug="${1:-}"

    if ! command -v jq >/dev/null 2>&1; then
        echo "jq required" >&2
        return 1
    fi

    _pp_ensure_state

    if [[ -n "$filter_slug" ]]; then
        jq --arg repo "$filter_slug" '.[$repo] // {}' "$PP_STATE_FILE"
    else
        jq '.' "$PP_STATE_FILE"
    fi
    return 0
}

# Show status summary.
cmd_status() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "jq required" >&2
        return 1
    fi

    _pp_ensure_state

    local total_allocs
    total_allocs="$(jq '[.. | objects | select(.port)] | length' "$PP_STATE_FILE" 2>/dev/null)" || total_allocs=0
    [[ "$total_allocs" =~ ^[0-9]+$ ]] || total_allocs=0

    local backend
    backend="$(_pp_backend_name)"
    [[ -z "$backend" ]] && backend="(none — static localhost fallback)"

    echo "Preview Proxy Status"
    echo "===================="
    echo "  State file: $PP_STATE_FILE"
    echo "  Config:     ${PP_CONFIG_FILE}$( [[ -f "$PP_CONFIG_FILE" ]] && echo " (present)" || echo " (absent — using defaults)")"
    echo "  Backend:    $backend"
    echo "  Active allocations: $total_allocs"

    if [[ "$total_allocs" -gt 0 ]]; then
        echo ""
        echo "Allocations:"
        jq -r 'to_entries[] | .key as $repo | .value | to_entries[] | "  \($repo) / \(.key) → port \(.value.port) (slug: \(.value.slug))"' "$PP_STATE_FILE" 2>/dev/null || true
    fi
    return 0
}

# Show help.
cmd_help() {
    echo "preview-proxy-helper.sh — per-worktree preview subdomains"
    echo ""
    echo "Commands:"
    echo "  allocate <repo_slug> <branch>  Allocate port + register proxy route"
    echo "  free <repo_slug> <branch>      Free port + deregister route (idempotent)"
    echo "  list [<repo_slug>]             List all allocations"
    echo "  status                         Show status summary"
    echo "  help                           Show this help"
    echo ""
    echo "State:  $PP_STATE_FILE"
    echo "Config: $PP_CONFIG_FILE (optional)"
    echo "Design: GH#21560, reference/preview-proxy.md"
    return 0
}

# -----------------------------------------------------------------------------
# Main dispatch
# -----------------------------------------------------------------------------
main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
    allocate) cmd_allocate "$@" ;;
    free) cmd_free "$@" ;;
    list) cmd_list "$@" ;;
    status) cmd_status "$@" ;;
    help | --help | -h) cmd_help ;;
    *)
        echo "Unknown command: $cmd" >&2
        cmd_help >&2
        return 1
        ;;
    esac
}

# Only run main if not being sourced
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
