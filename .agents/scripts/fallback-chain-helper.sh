#!/usr/bin/env bash
# shellcheck disable=SC1091

# Fallback Chain Helper - Per-agent and global model fallback chain resolution
# Resolves the best available model through a configurable chain of providers,
# with trigger-based activation on API errors, timeouts, and rate limits.
# Supports gateway providers (Cloudflare AI Gateway, OpenRouter) for
# provider-level fallback without per-provider API keys.
#
# Usage: fallback-chain-helper.sh [command] [options]
#
# Commands:
#   resolve <tier>          Resolve best model through fallback chain
#   trigger <tier> <error>  Process an error trigger and return next fallback
#   chain <tier>            Show the full fallback chain for a tier
#   status                  Show fallback chain health across all tiers
#   validate                Validate fallback chain configuration
#   gateway <provider>      Check gateway provider availability
#   help                    Show this help
#
# Options:
#   --config PATH     Override config file path
#   --agent FILE      Use per-agent fallback chain from frontmatter
#   --json            Output in JSON format
#   --quiet           Suppress informational output
#   --force           Bypass cache
#   --max-depth N     Maximum chain depth (default: 5)
#
# Trigger types:
#   api_error         Provider returned 5xx or connection failure
#   timeout           Request exceeded timeout threshold
#   rate_limit        Provider returned 429 (rate limited)
#   auth_error        Provider returned 401/403 (key invalid)
#   overloaded        Provider returned 529 (overloaded)
#
# Exit codes:
#   0 - Model resolved successfully
#   1 - No available model in chain
#   2 - Configuration error
#   3 - All providers exhausted
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

init_log_file

# =============================================================================
# Configuration
# =============================================================================

readonly FALLBACK_DIR="${HOME}/.aidevops/.agent-workspace"
readonly FALLBACK_DB="${FALLBACK_DIR}/fallback-chain.db"
readonly DEFAULT_CONFIG="${SCRIPT_DIR}/../configs/fallback-chain-config.json"
readonly AVAILABILITY_HELPER="${SCRIPT_DIR}/model-availability-helper.sh"
readonly DEFAULT_MAX_DEPTH=5
readonly COOLDOWN_SECONDS=300  # 5 minutes before retrying a failed provider
readonly GATEWAY_PROBE_TIMEOUT=10

# =============================================================================
# Database Setup
# =============================================================================

init_db() {
    mkdir -p "$FALLBACK_DIR" 2>/dev/null || true

    sqlite3 "$FALLBACK_DB" "
        PRAGMA journal_mode=WAL;
        PRAGMA busy_timeout=5000;

        CREATE TABLE IF NOT EXISTS trigger_log (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            tier           TEXT NOT NULL,
            trigger_type   TEXT NOT NULL,
            failed_model   TEXT NOT NULL,
            resolved_model TEXT DEFAULT '',
            chain_depth    INTEGER DEFAULT 0,
            details        TEXT DEFAULT '',
            timestamp      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS provider_cooldown (
            provider       TEXT PRIMARY KEY,
            reason         TEXT NOT NULL DEFAULT '',
            cooldown_until TEXT NOT NULL,
            created_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS gateway_health (
            gateway_id     TEXT PRIMARY KEY,
            gateway_type   TEXT NOT NULL DEFAULT '',
            status         TEXT NOT NULL DEFAULT 'unknown',
            endpoint       TEXT DEFAULT '',
            last_checked   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            response_ms    INTEGER DEFAULT 0,
            error_message  TEXT DEFAULT ''
        );

        CREATE INDEX IF NOT EXISTS idx_trigger_log_tier ON trigger_log(tier);
        CREATE INDEX IF NOT EXISTS idx_trigger_log_timestamp ON trigger_log(timestamp);
    " >/dev/null 2>/dev/null || {
        print_error "Failed to initialize fallback chain database"
        return 1
    }
    return 0
}

db_query() {
    local query="$1"
    sqlite3 -cmd ".timeout 5000" "$FALLBACK_DB" "$query" 2>/dev/null
    return $?
}

db_query_json() {
    local query="$1"
    sqlite3 -cmd ".timeout 5000" -json "$FALLBACK_DB" "$query" 2>/dev/null
    return $?
}

sql_escape() {
    local val="$1"
    echo "${val//\'/\'\'}"
    return 0
}

# =============================================================================
# Configuration Loading
# =============================================================================

# Load fallback chain config from JSON file.
# Supports both global config and per-agent overrides.
load_config() {
    local config_path="${1:-$DEFAULT_CONFIG}"

    # Try working config first (with real credentials), then template
    if [[ ! -f "$config_path" ]]; then
        local template_path="${config_path%.json}.json.txt"
        if [[ -f "$template_path" ]]; then
            config_path="$template_path"
        else
            print_error "Fallback chain config not found: $config_path"
            return 2
        fi
    fi

    # Validate JSON
    if ! jq empty "$config_path" 2>/dev/null; then
        print_error "Invalid JSON in fallback chain config: $config_path"
        return 2
    fi

    echo "$config_path"
    return 0
}

# Extract fallback chain from agent YAML frontmatter.
# Returns JSON array of model specs, or empty if not defined.
get_agent_chain() {
    local agent_file="$1"
    local tier="$2"

    if [[ ! -f "$agent_file" ]]; then
        return 1
    fi

    # Parse YAML frontmatter for fallback-chain field
    local in_frontmatter=false
    local in_chain=false
    local chain_json="["
    local first=true
    local line_num=0

    while IFS= read -r line; do
        line_num=$((line_num + 1))
        if [[ $line_num -eq 1 && "$line" == "---" ]]; then
            in_frontmatter=true
            continue
        fi
        if [[ "$in_frontmatter" == "true" && "$line" == "---" ]]; then
            break
        fi
        if [[ "$in_frontmatter" == "true" ]]; then
            # Check for fallback-chain: start
            if [[ "$line" =~ ^fallback-chain: ]]; then
                in_chain=true
                continue
            fi
            # Collect chain entries (YAML list items)
            if [[ "$in_chain" == "true" ]]; then
                if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+(.*) ]]; then
                    local entry="${BASH_REMATCH[1]}"
                    entry="${entry#"${entry%%[![:space:]]*}"}"
                    entry="${entry%"${entry##*[![:space:]]}"}"
                    if [[ "$first" == "true" ]]; then
                        first=false
                    else
                        chain_json="${chain_json},"
                    fi
                    chain_json="${chain_json}\"${entry}\""
                elif [[ ! "$line" =~ ^[[:space:]] ]]; then
                    # End of chain list (non-indented line)
                    in_chain=false
                fi
            fi
        fi
    done < "$agent_file"

    chain_json="${chain_json}]"

    # Return empty if no chain found
    if [[ "$chain_json" == "[]" ]]; then
        return 1
    fi

    echo "$chain_json"
    return 0
}

# Get the fallback chain for a tier from config.
# Priority: per-agent frontmatter > config tier-specific > config global default
get_chain_for_tier() {
    local tier="$1"
    local config_path="$2"
    local agent_file="${3:-}"

    # Priority 1: Per-agent frontmatter
    if [[ -n "$agent_file" ]]; then
        local agent_chain
        agent_chain=$(get_agent_chain "$agent_file" "$tier" 2>/dev/null) || true
        if [[ -n "$agent_chain" && "$agent_chain" != "[]" ]]; then
            echo "$agent_chain"
            return 0
        fi
    fi

    # Priority 2: Tier-specific chain from config
    local tier_chain
    tier_chain=$(jq -r --arg tier "$tier" '.chains[$tier] // empty' "$config_path" 2>/dev/null) || true
    if [[ -n "$tier_chain" && "$tier_chain" != "null" ]]; then
        echo "$tier_chain"
        return 0
    fi

    # Priority 3: Global default chain from config
    local default_chain
    default_chain=$(jq -r '.chains.default // empty' "$config_path" 2>/dev/null) || true
    if [[ -n "$default_chain" && "$default_chain" != "null" ]]; then
        echo "$default_chain"
        return 0
    fi

    # Priority 4: Hardcoded minimal fallback
    # Use the existing model-availability-helper.sh tier mapping
    local tier_spec=""
    case "$tier" in
        haiku)  tier_spec='["anthropic/claude-3-5-haiku-20241022","google/gemini-2.5-flash","openrouter/anthropic/claude-3-5-haiku-20241022"]' ;;
        flash)  tier_spec='["google/gemini-2.5-flash","openai/gpt-4.1-mini","openrouter/google/gemini-2.5-flash"]' ;;
        sonnet) tier_spec='["anthropic/claude-sonnet-4-20250514","openai/gpt-4.1","openrouter/anthropic/claude-sonnet-4-20250514"]' ;;
        pro)    tier_spec='["google/gemini-2.5-pro","anthropic/claude-sonnet-4-20250514","openrouter/google/gemini-2.5-pro"]' ;;
        opus)   tier_spec='["anthropic/claude-opus-4-6","openai/o3","openrouter/anthropic/claude-opus-4-6"]' ;;
        coding) tier_spec='["anthropic/claude-opus-4-6","openai/o3","openrouter/anthropic/claude-opus-4-6"]' ;;
        eval)   tier_spec='["anthropic/claude-sonnet-4-5","google/gemini-2.5-flash","openrouter/anthropic/claude-sonnet-4-5"]' ;;
        health) tier_spec='["anthropic/claude-sonnet-4-5","google/gemini-2.5-flash"]' ;;
        *)
            print_error "Unknown tier: $tier"
            return 1
            ;;
    esac
    echo "$tier_spec"
    return 0
}

# =============================================================================
# Provider Cooldown Management
# =============================================================================

# Check if a provider is in cooldown (recently failed).
is_provider_cooled_down() {
    local provider="$1"

    local cooldown_until
    cooldown_until=$(db_query "
        SELECT cooldown_until FROM provider_cooldown
        WHERE provider = '$(sql_escape "$provider")';
    ")

    if [[ -z "$cooldown_until" ]]; then
        return 1  # Not in cooldown
    fi

    local cooldown_epoch now_epoch
    if [[ "$(uname)" == "Darwin" ]]; then
        cooldown_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$cooldown_until" "+%s" 2>/dev/null || echo "0")
    else
        cooldown_epoch=$(date -d "$cooldown_until" "+%s" 2>/dev/null || echo "0")
    fi
    now_epoch=$(date "+%s")

    if [[ "$now_epoch" -lt "$cooldown_epoch" ]]; then
        return 0  # Still in cooldown
    fi

    # Cooldown expired, remove it
    db_query "DELETE FROM provider_cooldown WHERE provider = '$(sql_escape "$provider")';" || true
    return 1  # No longer in cooldown
}

# Put a provider into cooldown after a failure.
set_provider_cooldown() {
    local provider="$1"
    local reason="$2"
    local duration="${3:-$COOLDOWN_SECONDS}"

    local cooldown_until
    if [[ "$(uname)" == "Darwin" ]]; then
        cooldown_until=$(date -u -v+"${duration}S" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
    else
        cooldown_until=$(date -u -d "+${duration} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
    fi

    db_query "
        INSERT INTO provider_cooldown (provider, reason, cooldown_until)
        VALUES (
            '$(sql_escape "$provider")',
            '$(sql_escape "$reason")',
            '$(sql_escape "$cooldown_until")'
        )
        ON CONFLICT(provider) DO UPDATE SET
            reason = excluded.reason,
            cooldown_until = excluded.cooldown_until,
            created_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
    " || true
    return 0
}

# =============================================================================
# Trigger Detection
# =============================================================================

# Classify an error into a trigger type based on HTTP status code or error message.
classify_trigger() {
    local error_input="$1"

    # HTTP status code patterns
    case "$error_input" in
        429|*"rate limit"*|*"Rate limit"*|*"rate_limit"*|*"too many requests"*|*"Too Many Requests"*)
            echo "rate_limit"
            return 0
            ;;
        401|403|*"auth"*|*"forbidden"*|*"Forbidden"*|*"invalid"*"key"*|*"Invalid"*"key"*)
            echo "auth_error"
            return 0
            ;;
        500|502|503|504|*"internal server"*|*"Internal Server"*|*"bad gateway"*|*"Bad Gateway"*|*"service unavailable"*|*"Service Unavailable"*|*"gateway timeout"*|*"Gateway Timeout"*)
            echo "api_error"
            return 0
            ;;
        529|*"overloaded"*|*"Overloaded"*|*"capacity"*)
            echo "overloaded"
            return 0
            ;;
        *"timeout"*|*"Timeout"*|*"ETIMEDOUT"*|*"ECONNRESET"*|*"timed out"*)
            echo "timeout"
            return 0
            ;;
        *"connection refused"*|*"Connection refused"*|*"ECONNREFUSED"*|*"network"*|*"Network"*)
            echo "api_error"
            return 0
            ;;
        *)
            echo "unknown"
            return 0
            ;;
    esac
}

# Determine cooldown duration based on trigger type.
get_cooldown_for_trigger() {
    local trigger_type="$1"
    local config_path="$2"

    # Try config first
    local configured_cooldown
    configured_cooldown=$(jq -r --arg trigger "$trigger_type" \
        '.triggers[$trigger].cooldown_seconds // empty' "$config_path" 2>/dev/null) || true

    if [[ -n "$configured_cooldown" && "$configured_cooldown" != "null" ]]; then
        echo "$configured_cooldown"
        return 0
    fi

    # Default cooldowns by trigger type
    case "$trigger_type" in
        rate_limit)  echo "60" ;;    # 1 minute
        auth_error)  echo "3600" ;;  # 1 hour (key won't fix itself)
        api_error)   echo "300" ;;   # 5 minutes
        overloaded)  echo "120" ;;   # 2 minutes
        timeout)     echo "180" ;;   # 3 minutes
        *)           echo "300" ;;   # 5 minutes default
    esac
    return 0
}

# Check if a trigger type should activate fallback.
should_trigger_fallback() {
    local trigger_type="$1"
    local config_path="$2"

    # Check config for trigger enablement
    local enabled
    enabled=$(jq -r --arg trigger "$trigger_type" \
        '.triggers[$trigger].enabled // true' "$config_path" 2>/dev/null) || true

    if [[ "$enabled" == "false" ]]; then
        return 1
    fi

    return 0
}

# =============================================================================
# Gateway Provider Support
# =============================================================================

# Extract provider name from a model spec.
# Handles both direct (anthropic/claude-sonnet-4) and gateway
# (openrouter/anthropic/claude-sonnet-4, gateway/cf/anthropic/claude-sonnet-4) formats.
parse_model_spec() {
    local model_spec="$1"
    local field="$2"  # provider, gateway, model, or full

    case "$model_spec" in
        gateway/cf/*)
            # Cloudflare AI Gateway: gateway/cf/provider/model
            case "$field" in
                gateway)  echo "cloudflare" ;;
                provider) echo "$model_spec" | cut -d'/' -f3 ;;
                model)    echo "$model_spec" | cut -d'/' -f4- ;;
                full)     echo "$model_spec" ;;
            esac
            ;;
        openrouter/*)
            # OpenRouter gateway: openrouter/provider/model
            case "$field" in
                gateway)  echo "openrouter" ;;
                provider) echo "$model_spec" | cut -d'/' -f2 ;;
                model)    echo "$model_spec" | cut -d'/' -f3- ;;
                full)     echo "$model_spec" ;;
            esac
            ;;
        */*)
            # Direct provider: provider/model
            case "$field" in
                gateway)  echo "direct" ;;
                provider) echo "${model_spec%%/*}" ;;
                model)    echo "${model_spec#*/}" ;;
                full)     echo "$model_spec" ;;
            esac
            ;;
        *)
            # Bare model name
            case "$field" in
                gateway)  echo "direct" ;;
                provider) echo "unknown" ;;
                model)    echo "$model_spec" ;;
                full)     echo "$model_spec" ;;
            esac
            ;;
    esac
    return 0
}

# Check if a gateway provider is available.
check_gateway() {
    local gateway_type="$1"
    local config_path="$2"
    local quiet="${3:-false}"

    case "$gateway_type" in
        openrouter)
            _check_openrouter_gateway "$config_path" "$quiet"
            return $?
            ;;
        cloudflare)
            _check_cloudflare_gateway "$config_path" "$quiet"
            return $?
            ;;
        direct)
            return 0  # Direct providers checked by model-availability-helper
            ;;
        *)
            [[ "$quiet" != "true" ]] && print_warning "Unknown gateway type: $gateway_type"
            return 1
            ;;
    esac
}

_check_openrouter_gateway() {
    local config_path="$1"
    local quiet="$2"

    # Check for OpenRouter API key
    local key_var="OPENROUTER_API_KEY"
    if [[ -z "${!key_var:-}" ]]; then
        # Try credentials.sh
        local creds_file="${HOME}/.config/aidevops/credentials.sh"
        if [[ -f "$creds_file" ]]; then
            # shellcheck disable=SC1090
            source "$creds_file"
        fi
    fi

    if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
        [[ "$quiet" != "true" ]] && print_warning "OpenRouter: no API key configured"
        _record_gateway_health "openrouter" "openrouter" "no_key" "" 0 "No OPENROUTER_API_KEY"
        return 1
    fi

    # Lightweight probe
    local start_ms
    start_ms=$(date +%s%N 2>/dev/null || echo "0")

    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$GATEWAY_PROBE_TIMEOUT" \
        -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
        "https://openrouter.ai/api/v1/models" 2>/dev/null) || http_code="000"

    local end_ms
    end_ms=$(date +%s%N 2>/dev/null || echo "0")
    local duration_ms=0
    if [[ "$start_ms" != "0" && "$end_ms" != "0" ]]; then
        duration_ms=$(( (end_ms - start_ms) / 1000000 ))
    fi

    if [[ "$http_code" == "200" ]]; then
        [[ "$quiet" != "true" ]] && print_success "OpenRouter: healthy (${duration_ms}ms)"
        _record_gateway_health "openrouter" "openrouter" "healthy" "https://openrouter.ai/api/v1" "$duration_ms" ""
        return 0
    fi

    [[ "$quiet" != "true" ]] && print_warning "OpenRouter: unhealthy (HTTP $http_code)"
    _record_gateway_health "openrouter" "openrouter" "unhealthy" "https://openrouter.ai/api/v1" "$duration_ms" "HTTP $http_code"
    return 1
}

_check_cloudflare_gateway() {
    local config_path="$1"
    local quiet="$2"

    # Get Cloudflare AI Gateway config
    local account_id gateway_id cf_token
    account_id=$(jq -r '.gateways.cloudflare.account_id // empty' "$config_path" 2>/dev/null) || true
    gateway_id=$(jq -r '.gateways.cloudflare.gateway_id // empty' "$config_path" 2>/dev/null) || true

    if [[ -z "$account_id" || -z "$gateway_id" ]]; then
        [[ "$quiet" != "true" ]] && print_warning "Cloudflare AI Gateway: not configured (missing account_id/gateway_id)"
        _record_gateway_health "cloudflare" "cloudflare" "not_configured" "" 0 "Missing account_id or gateway_id"
        return 1
    fi

    # Check for CF token
    cf_token="${CF_AIG_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}"
    if [[ -z "$cf_token" ]]; then
        local creds_file="${HOME}/.config/aidevops/credentials.sh"
        if [[ -f "$creds_file" ]]; then
            # shellcheck disable=SC1090
            source "$creds_file"
            cf_token="${CF_AIG_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}"
        fi
    fi

    local endpoint="https://gateway.ai.cloudflare.com/v1/${account_id}/${gateway_id}"

    # Lightweight probe (just check if the gateway endpoint responds)
    local start_ms
    start_ms=$(date +%s%N 2>/dev/null || echo "0")

    local -a curl_args=(-s -o /dev/null -w '%{http_code}' --max-time "$GATEWAY_PROBE_TIMEOUT")
    if [[ -n "$cf_token" ]]; then
        curl_args+=(-H "cf-aig-authorization: Bearer ${cf_token}")
    fi

    local http_code
    http_code=$(curl "${curl_args[@]}" "${endpoint}/openai/models" 2>/dev/null) || http_code="000"

    local end_ms
    end_ms=$(date +%s%N 2>/dev/null || echo "0")
    local duration_ms=0
    if [[ "$start_ms" != "0" && "$end_ms" != "0" ]]; then
        duration_ms=$(( (end_ms - start_ms) / 1000000 ))
    fi

    # CF AI Gateway returns various codes; 200 or 401 (needs auth) both mean it's reachable
    if [[ "$http_code" == "200" || "$http_code" == "401" ]]; then
        [[ "$quiet" != "true" ]] && print_success "Cloudflare AI Gateway: reachable (${duration_ms}ms)"
        _record_gateway_health "cloudflare" "cloudflare" "healthy" "$endpoint" "$duration_ms" ""
        return 0
    fi

    [[ "$quiet" != "true" ]] && print_warning "Cloudflare AI Gateway: unreachable (HTTP $http_code)"
    _record_gateway_health "cloudflare" "cloudflare" "unhealthy" "$endpoint" "$duration_ms" "HTTP $http_code"
    return 1
}

_record_gateway_health() {
    local gateway_id="$1"
    local gateway_type="$2"
    local status="$3"
    local endpoint="$4"
    local response_ms="$5"
    local error_msg="$6"

    db_query "
        INSERT INTO gateway_health (gateway_id, gateway_type, status, endpoint, last_checked, response_ms, error_message)
        VALUES (
            '$(sql_escape "$gateway_id")',
            '$(sql_escape "$gateway_type")',
            '$(sql_escape "$status")',
            '$(sql_escape "$endpoint")',
            strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            $response_ms,
            '$(sql_escape "$error_msg")'
        )
        ON CONFLICT(gateway_id) DO UPDATE SET
            gateway_type = excluded.gateway_type,
            status = excluded.status,
            endpoint = excluded.endpoint,
            last_checked = excluded.last_checked,
            response_ms = excluded.response_ms,
            error_message = excluded.error_message;
    " || true
    return 0
}

# =============================================================================
# Chain Resolution
# =============================================================================

# Resolve the best available model by walking the fallback chain.
# Skips providers in cooldown, checks availability, and logs the resolution.
resolve_chain() {
    local tier="$1"
    local config_path="$2"
    local agent_file="${3:-}"
    local max_depth="${4:-$DEFAULT_MAX_DEPTH}"
    local force="${5:-false}"
    local quiet="${6:-false}"

    # Get the chain for this tier
    local chain_json
    chain_json=$(get_chain_for_tier "$tier" "$config_path" "$agent_file") || {
        print_error "Could not determine fallback chain for tier: $tier" >&2
        return 1
    }

    local chain_length
    chain_length=$(echo "$chain_json" | jq 'length' 2>/dev/null) || chain_length=0

    if [[ "$chain_length" -eq 0 ]]; then
        print_error "Empty fallback chain for tier: $tier" >&2
        return 1
    fi

    # Cap at max depth
    if [[ "$chain_length" -gt "$max_depth" ]]; then
        chain_length="$max_depth"
    fi

    # Walk the chain
    local depth=0
    while [[ "$depth" -lt "$chain_length" ]]; do
        local model_spec
        model_spec=$(echo "$chain_json" | jq -r ".[$depth]" 2>/dev/null) || true

        if [[ -z "$model_spec" || "$model_spec" == "null" ]]; then
            depth=$((depth + 1))
            continue
        fi

        local provider gateway
        provider=$(parse_model_spec "$model_spec" "provider")
        gateway=$(parse_model_spec "$model_spec" "gateway")

        # Check provider cooldown
        if is_provider_cooled_down "$provider"; then
            [[ "$quiet" != "true" ]] && print_warning "  [$depth] $model_spec: provider $provider in cooldown, skipping" >&2
            depth=$((depth + 1))
            continue
        fi

        # Check gateway availability (for gateway-routed models)
        if [[ "$gateway" != "direct" ]]; then
            if ! check_gateway "$gateway" "$config_path" "true"; then
                [[ "$quiet" != "true" ]] && print_warning "  [$depth] $model_spec: gateway $gateway unavailable, skipping" >&2
                depth=$((depth + 1))
                continue
            fi
        fi

        # Check model availability via model-availability-helper.sh
        if [[ -x "$AVAILABILITY_HELPER" && "$gateway" == "direct" ]]; then
            local avail_exit=0
            "$AVAILABILITY_HELPER" check "$provider" --quiet 2>/dev/null || avail_exit=$?

            if [[ "$avail_exit" -ne 0 ]]; then
                [[ "$quiet" != "true" ]] && print_warning "  [$depth] $model_spec: provider $provider unavailable (exit $avail_exit), skipping" >&2
                depth=$((depth + 1))
                continue
            fi
        fi

        # Model is available
        [[ "$quiet" != "true" ]] && print_success "  [$depth] $model_spec: available" >&2

        # Log the resolution
        db_query "
            INSERT INTO trigger_log (tier, trigger_type, failed_model, resolved_model, chain_depth, details)
            VALUES (
                '$(sql_escape "$tier")',
                'resolve',
                '',
                '$(sql_escape "$model_spec")',
                $depth,
                'Chain resolution'
            );
        " || true

        echo "$model_spec"
        return 0
    done

    [[ "$quiet" != "true" ]] && print_error "All models exhausted in fallback chain for tier: $tier" >&2
    return 3
}

# =============================================================================
# Commands
# =============================================================================

cmd_resolve() {
    local tier="${1:-}"
    shift || true

    local config_override="" agent_file="" json_flag=false quiet=false force=false max_depth="$DEFAULT_MAX_DEPTH"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config) config_override="${2:-}"; shift 2 ;;
            --agent) agent_file="${2:-}"; shift 2 ;;
            --json) json_flag=true; shift ;;
            --quiet) quiet=true; shift ;;
            --force) force=true; shift ;;
            --max-depth) max_depth="${2:-$DEFAULT_MAX_DEPTH}"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$tier" ]]; then
        print_error "Usage: fallback-chain-helper.sh resolve <tier>"
        return 1
    fi

    local config_path
    config_path=$(load_config "${config_override:-$DEFAULT_CONFIG}") || return $?

    [[ "$quiet" != "true" ]] && print_info "Resolving fallback chain for tier: $tier" >&2

    local resolved
    resolved=$(resolve_chain "$tier" "$config_path" "$agent_file" "$max_depth" "$force" "$quiet") || {
        local exit_code=$?
        if [[ "$json_flag" == "true" ]]; then
            echo "{\"tier\":\"$tier\",\"status\":\"exhausted\",\"model\":null}"
        fi
        return "$exit_code"
    }

    if [[ "$json_flag" == "true" ]]; then
        local provider gateway model_id
        provider=$(parse_model_spec "$resolved" "provider")
        gateway=$(parse_model_spec "$resolved" "gateway")
        model_id=$(parse_model_spec "$resolved" "model")
        echo "{\"tier\":\"$tier\",\"status\":\"resolved\",\"model\":\"$resolved\",\"provider\":\"$provider\",\"gateway\":\"$gateway\",\"model_id\":\"$model_id\"}"
    else
        echo "$resolved"
    fi

    return 0
}

cmd_trigger() {
    local tier="${1:-}"
    local error_input="${2:-}"
    shift 2 || true

    local config_override="" agent_file="" json_flag=false quiet=false max_depth="$DEFAULT_MAX_DEPTH"
    local failed_model=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config) config_override="${2:-}"; shift 2 ;;
            --agent) agent_file="${2:-}"; shift 2 ;;
            --json) json_flag=true; shift ;;
            --quiet) quiet=true; shift ;;
            --failed-model) failed_model="${2:-}"; shift 2 ;;
            --max-depth) max_depth="${2:-$DEFAULT_MAX_DEPTH}"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$tier" || -z "$error_input" ]]; then
        print_error "Usage: fallback-chain-helper.sh trigger <tier> <error> [--failed-model model]"
        return 1
    fi

    local config_path
    config_path=$(load_config "${config_override:-$DEFAULT_CONFIG}") || return $?

    # Classify the trigger
    local trigger_type
    trigger_type=$(classify_trigger "$error_input")

    [[ "$quiet" != "true" ]] && print_info "Trigger: $trigger_type (from: $error_input)" >&2

    # Check if this trigger type should activate fallback
    if ! should_trigger_fallback "$trigger_type" "$config_path"; then
        [[ "$quiet" != "true" ]] && print_info "Trigger type '$trigger_type' is disabled in config" >&2
        return 1
    fi

    # Put the failed provider into cooldown
    if [[ -n "$failed_model" ]]; then
        local failed_provider
        failed_provider=$(parse_model_spec "$failed_model" "provider")
        local cooldown_duration
        cooldown_duration=$(get_cooldown_for_trigger "$trigger_type" "$config_path")
        set_provider_cooldown "$failed_provider" "$trigger_type" "$cooldown_duration"
        [[ "$quiet" != "true" ]] && print_info "Provider $failed_provider in cooldown for ${cooldown_duration}s ($trigger_type)" >&2
    fi

    # Resolve next available model from chain
    local resolved
    resolved=$(resolve_chain "$tier" "$config_path" "$agent_file" "$max_depth" "false" "$quiet") || {
        local exit_code=$?
        # Log the exhaustion
        db_query "
            INSERT INTO trigger_log (tier, trigger_type, failed_model, resolved_model, chain_depth, details)
            VALUES (
                '$(sql_escape "$tier")',
                '$(sql_escape "$trigger_type")',
                '$(sql_escape "${failed_model:-unknown}")',
                '',
                $max_depth,
                '$(sql_escape "Chain exhausted after trigger: $error_input")'
            );
        " || true
        if [[ "$json_flag" == "true" ]]; then
            echo "{\"tier\":\"$tier\",\"trigger\":\"$trigger_type\",\"status\":\"exhausted\",\"model\":null,\"failed_model\":\"${failed_model:-}\"}"
        fi
        return "$exit_code"
    }

    # Log the trigger resolution
    db_query "
        INSERT INTO trigger_log (tier, trigger_type, failed_model, resolved_model, chain_depth, details)
        VALUES (
            '$(sql_escape "$tier")',
            '$(sql_escape "$trigger_type")',
            '$(sql_escape "${failed_model:-unknown}")',
            '$(sql_escape "$resolved")',
            0,
            '$(sql_escape "Triggered by: $error_input")'
        );
    " || true

    if [[ "$json_flag" == "true" ]]; then
        local provider gateway model_id
        provider=$(parse_model_spec "$resolved" "provider")
        gateway=$(parse_model_spec "$resolved" "gateway")
        model_id=$(parse_model_spec "$resolved" "model")
        echo "{\"tier\":\"$tier\",\"trigger\":\"$trigger_type\",\"status\":\"resolved\",\"model\":\"$resolved\",\"provider\":\"$provider\",\"gateway\":\"$gateway\",\"model_id\":\"$model_id\",\"failed_model\":\"${failed_model:-}\"}"
    else
        echo "$resolved"
    fi

    return 0
}

cmd_chain() {
    local tier="${1:-}"
    shift || true

    local config_override="" agent_file="" json_flag=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config) config_override="${2:-}"; shift 2 ;;
            --agent) agent_file="${2:-}"; shift 2 ;;
            --json) json_flag=true; shift ;;
            *) shift ;;
        esac
    done

    if [[ -z "$tier" ]]; then
        print_error "Usage: fallback-chain-helper.sh chain <tier>"
        return 1
    fi

    local config_path
    config_path=$(load_config "${config_override:-$DEFAULT_CONFIG}") || return $?

    local chain_json
    chain_json=$(get_chain_for_tier "$tier" "$config_path" "$agent_file") || {
        print_error "Could not determine chain for tier: $tier"
        return 1
    }

    if [[ "$json_flag" == "true" ]]; then
        echo "{\"tier\":\"$tier\",\"chain\":$chain_json}"
        return 0
    fi

    echo ""
    echo "Fallback Chain: $tier"
    echo "===================="
    echo ""

    local chain_length idx
    chain_length=$(echo "$chain_json" | jq 'length' 2>/dev/null) || chain_length=0
    idx=0

    while [[ "$idx" -lt "$chain_length" ]]; do
        local model_spec provider gateway model_id
        model_spec=$(echo "$chain_json" | jq -r ".[$idx]" 2>/dev/null) || true
        provider=$(parse_model_spec "$model_spec" "provider")
        gateway=$(parse_model_spec "$model_spec" "gateway")
        model_id=$(parse_model_spec "$model_spec" "model")

        local cooldown_status=""
        if is_provider_cooled_down "$provider"; then
            cooldown_status=" [COOLDOWN]"
        fi

        local gateway_label=""
        if [[ "$gateway" != "direct" ]]; then
            gateway_label=" via $gateway"
        fi

        printf "  %d. %s (%s%s)%s\n" "$((idx + 1))" "$model_spec" "$provider" "$gateway_label" "$cooldown_status"
        idx=$((idx + 1))
    done

    echo ""
    return 0
}

cmd_status() {
    local json_flag=false config_override=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_flag=true; shift ;;
            --config) config_override="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    local config_path
    config_path=$(load_config "${config_override:-$DEFAULT_CONFIG}") || return $?

    if [[ "$json_flag" == "true" ]]; then
        local cooldowns triggers gateways
        cooldowns=$(db_query_json "SELECT provider, reason, cooldown_until FROM provider_cooldown ORDER BY provider;" 2>/dev/null || echo "[]")
        triggers=$(db_query_json "SELECT tier, trigger_type, failed_model, resolved_model, chain_depth, timestamp FROM trigger_log ORDER BY id DESC LIMIT 20;" 2>/dev/null || echo "[]")
        gateways=$(db_query_json "SELECT gateway_id, gateway_type, status, endpoint, last_checked, response_ms FROM gateway_health ORDER BY gateway_id;" 2>/dev/null || echo "[]")
        echo "{\"cooldowns\":$cooldowns,\"recent_triggers\":$triggers,\"gateways\":$gateways}"
        return 0
    fi

    echo ""
    echo "Fallback Chain Status"
    echo "====================="
    echo ""

    # Show chains for all tiers
    echo "Tier Chains:"
    echo ""
    local tiers="haiku flash sonnet pro opus coding eval health"
    for tier in $tiers; do
        local chain_json
        chain_json=$(get_chain_for_tier "$tier" "$config_path" "" 2>/dev/null) || chain_json="[]"
        local chain_length
        chain_length=$(echo "$chain_json" | jq 'length' 2>/dev/null || echo "0")
        local first_model last_model
        first_model=$(echo "$chain_json" | jq -r '.[0] // "none"' 2>/dev/null)
        last_model=$(echo "$chain_json" | jq -r '.[-1] // "none"' 2>/dev/null)
        printf "  %-8s %s -> ... -> %s (%d models)\n" "$tier" "$first_model" "$last_model" "$chain_length"
    done

    # Show active cooldowns
    echo ""
    echo "Active Cooldowns:"
    echo ""
    local cooldown_count
    cooldown_count=$(db_query "SELECT COUNT(*) FROM provider_cooldown;" 2>/dev/null || echo "0")
    if [[ "$cooldown_count" -eq 0 ]]; then
        echo "  (none)"
    else
        db_query "SELECT provider, reason, cooldown_until FROM provider_cooldown ORDER BY provider;" | \
        while IFS='|' read -r prov reason until; do
            printf "  %-12s %-15s until %s\n" "$prov" "$reason" "$until"
        done
    fi

    # Show gateway health
    echo ""
    echo "Gateway Health:"
    echo ""
    local gw_count
    gw_count=$(db_query "SELECT COUNT(*) FROM gateway_health;" 2>/dev/null || echo "0")
    if [[ "$gw_count" -eq 0 ]]; then
        echo "  (no gateways probed yet)"
    else
        printf "  %-12s %-12s %-12s %-8s %s\n" "Gateway" "Type" "Status" "Time" "Endpoint"
        printf "  %-12s %-12s %-12s %-8s %s\n" "-------" "----" "------" "----" "--------"
        db_query "SELECT gateway_id, gateway_type, status, response_ms, endpoint FROM gateway_health ORDER BY gateway_id;" | \
        while IFS='|' read -r gid gtype gstatus gms gendpoint; do
            printf "  %-12s %-12s %-12s %-8s %s\n" "$gid" "$gtype" "$gstatus" "${gms}ms" "$gendpoint"
        done
    fi

    # Show recent triggers
    echo ""
    echo "Recent Triggers (last 10):"
    echo ""
    local trigger_count
    trigger_count=$(db_query "SELECT COUNT(*) FROM trigger_log;" 2>/dev/null || echo "0")
    if [[ "$trigger_count" -eq 0 ]]; then
        echo "  (no triggers recorded)"
    else
        db_query "
            SELECT timestamp, tier, trigger_type, failed_model, resolved_model, chain_depth
            FROM trigger_log ORDER BY id DESC LIMIT 10;
        " | while IFS='|' read -r ts tier ttype failed resolved depth; do
            printf "  %s  %-8s %-12s %s -> %s (depth %s)\n" \
                "$ts" "$tier" "$ttype" "${failed:-n/a}" "${resolved:-EXHAUSTED}" "$depth"
        done
    fi

    echo ""
    return 0
}

cmd_validate() {
    local config_override=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config) config_override="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    local config_path
    config_path=$(load_config "${config_override:-$DEFAULT_CONFIG}") || return $?

    echo ""
    echo "Fallback Chain Validation"
    echo "========================="
    echo ""

    local issues=0

    # Check JSON structure
    if ! jq empty "$config_path" 2>/dev/null; then
        print_error "Invalid JSON: $config_path"
        return 2
    fi
    print_success "JSON syntax: valid"

    # Check required top-level keys
    local has_chains has_triggers has_gateways
    has_chains=$(jq 'has("chains")' "$config_path" 2>/dev/null)
    has_triggers=$(jq 'has("triggers")' "$config_path" 2>/dev/null)
    has_gateways=$(jq 'has("gateways")' "$config_path" 2>/dev/null)

    if [[ "$has_chains" != "true" ]]; then
        print_warning "Missing 'chains' key (will use hardcoded defaults)"
        issues=$((issues + 1))
    else
        print_success "chains: present"
    fi

    if [[ "$has_triggers" != "true" ]]; then
        print_warning "Missing 'triggers' key (will use default trigger settings)"
        issues=$((issues + 1))
    else
        print_success "triggers: present"
    fi

    if [[ "$has_gateways" != "true" ]]; then
        print_info "No 'gateways' key (gateway fallback disabled)"
    else
        print_success "gateways: present"
    fi

    # Validate each chain has at least 2 entries
    echo ""
    echo "Chain Validation:"
    local tiers
    tiers=$(jq -r '.chains | keys[]' "$config_path" 2>/dev/null) || tiers=""
    for tier in $tiers; do
        local chain_length
        chain_length=$(jq -r --arg t "$tier" '.chains[$t] | length' "$config_path" 2>/dev/null) || chain_length=0
        if [[ "$chain_length" -lt 2 ]]; then
            print_warning "  $tier: only $chain_length model(s) (recommend >= 2 for fallback)"
            issues=$((issues + 1))
        else
            print_success "  $tier: $chain_length models"
        fi
    done

    # Validate trigger types
    echo ""
    echo "Trigger Validation:"
    local trigger_types="api_error timeout rate_limit auth_error overloaded"
    for tt in $trigger_types; do
        local enabled
        enabled=$(jq -r --arg t "$tt" '.triggers[$t].enabled // "not configured"' "$config_path" 2>/dev/null)
        if [[ "$enabled" == "not configured" ]]; then
            print_info "  $tt: not configured (defaults to enabled)"
        elif [[ "$enabled" == "true" ]]; then
            print_success "  $tt: enabled"
        else
            print_info "  $tt: disabled"
        fi
    done

    echo ""
    if [[ "$issues" -gt 0 ]]; then
        print_warning "$issues issue(s) found (non-critical, defaults will be used)"
    else
        print_success "Configuration is valid"
    fi
    echo ""
    return 0
}

cmd_gateway() {
    local gateway="${1:-}"
    shift || true

    local config_override="" quiet=false json_flag=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config) config_override="${2:-}"; shift 2 ;;
            --quiet) quiet=true; shift ;;
            --json) json_flag=true; shift ;;
            *) shift ;;
        esac
    done

    if [[ -z "$gateway" ]]; then
        print_error "Usage: fallback-chain-helper.sh gateway <openrouter|cloudflare>"
        return 1
    fi

    local config_path
    config_path=$(load_config "${config_override:-$DEFAULT_CONFIG}") || return $?

    check_gateway "$gateway" "$config_path" "$quiet"
    local exit_code=$?

    if [[ "$json_flag" == "true" ]]; then
        db_query_json "SELECT * FROM gateway_health WHERE gateway_id = '$(sql_escape "$gateway")';" 2>/dev/null || echo "[]"
    fi

    return "$exit_code"
}

cmd_help() {
    echo ""
    echo "Fallback Chain Helper - Per-agent and global model fallback chains"
    echo "=================================================================="
    echo ""
    echo "Usage: fallback-chain-helper.sh [command] [options]"
    echo ""
    echo "Commands:"
    echo "  resolve <tier>          Resolve best model through fallback chain"
    echo "  trigger <tier> <error>  Process error trigger and return next fallback"
    echo "  chain <tier>            Show the full fallback chain for a tier"
    echo "  status                  Show fallback chain health across all tiers"
    echo "  validate                Validate fallback chain configuration"
    echo "  gateway <provider>      Check gateway provider availability"
    echo "  help                    Show this help"
    echo ""
    echo "Options:"
    echo "  --config PATH     Override config file path"
    echo "  --agent FILE      Use per-agent fallback chain from frontmatter"
    echo "  --json            Output in JSON format"
    echo "  --quiet           Suppress informational output"
    echo "  --force           Bypass cache"
    echo "  --max-depth N     Maximum chain depth (default: $DEFAULT_MAX_DEPTH)"
    echo "  --failed-model M  Model that failed (for trigger command)"
    echo ""
    echo "Trigger types:"
    echo "  api_error         Provider returned 5xx or connection failure"
    echo "  timeout           Request exceeded timeout threshold"
    echo "  rate_limit        Provider returned 429"
    echo "  auth_error        Provider returned 401/403"
    echo "  overloaded        Provider returned 529"
    echo ""
    echo "Model spec formats:"
    echo "  provider/model                    Direct provider (e.g., anthropic/claude-sonnet-4)"
    echo "  openrouter/provider/model         Via OpenRouter gateway"
    echo "  gateway/cf/provider/model         Via Cloudflare AI Gateway"
    echo ""
    echo "Examples:"
    echo "  # Resolve best model for coding tier"
    echo "  fallback-chain-helper.sh resolve coding"
    echo ""
    echo "  # Resolve with per-agent chain override"
    echo "  fallback-chain-helper.sh resolve sonnet --agent models/sonnet.md"
    echo ""
    echo "  # Process a rate limit trigger"
    echo "  fallback-chain-helper.sh trigger coding 429 --failed-model anthropic/claude-opus-4-6"
    echo ""
    echo "  # Show chain for a tier"
    echo "  fallback-chain-helper.sh chain opus"
    echo ""
    echo "  # Check OpenRouter gateway"
    echo "  fallback-chain-helper.sh gateway openrouter"
    echo ""
    echo "  # Validate configuration"
    echo "  fallback-chain-helper.sh validate"
    echo ""
    echo "Configuration:"
    echo "  Global: $DEFAULT_CONFIG"
    echo "  Per-agent: YAML frontmatter 'fallback-chain:' in model tier files"
    echo "  Database: $FALLBACK_DB"
    echo ""
    echo "Integration:"
    echo "  - model-availability-helper.sh: Uses for provider health checks"
    echo "  - supervisor-helper.sh: Calls resolve/trigger during dispatch"
    echo "  - Gateway providers: OpenRouter, Cloudflare AI Gateway"
    echo ""
    echo "Exit codes:"
    echo "  0 - Model resolved successfully"
    echo "  1 - No available model / usage error"
    echo "  2 - Configuration error"
    echo "  3 - All providers exhausted"
    echo ""
    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="${1:-help}"
    shift || true

    # Initialize DB for all commands except help
    if [[ "$command" != "help" && "$command" != "--help" && "$command" != "-h" ]]; then
        init_db || return 1
    fi

    case "$command" in
        resolve)
            cmd_resolve "$@"
            ;;
        trigger)
            cmd_trigger "$@"
            ;;
        chain)
            cmd_chain "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        validate)
            cmd_validate "$@"
            ;;
        gateway)
            cmd_gateway "$@"
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            print_error "Unknown command: $command"
            cmd_help
            return 1
            ;;
    esac
    return $?
}

main "$@"
