#!/usr/bin/env bash
# shellcheck disable=SC1091

# Model Availability Helper - Probe before dispatch
# Lightweight provider health checks using direct HTTP API calls.
# Tests API key validity, model availability, and rate limits.
# Caches results with short TTL to avoid redundant probes.
#
# Usage: model-availability-helper.sh [command] [options]
#
# Commands:
#   check [provider|model]  Check if a provider/model is available (exit 0=yes, 1=no)
#   probe [--all]           Probe all configured providers (or specific one)
#   status                  Show cached availability status for all providers
#   rate-limits             Show current rate limit status from cache
#   resolve <tier>          Resolve best available model for a tier (with fallback)
#   invalidate [provider]   Clear cache for a provider (or all)
#   help                    Show this help
#
# Options:
#   --json        Output in JSON format
#   --quiet       Suppress informational output
#   --force       Bypass cache and probe live
#   --ttl N       Override cache TTL in seconds (default: 300)
#
# Integration:
#   - Called by supervisor-helper.sh before dispatch (replaces inline health check)
#   - Uses direct HTTP API calls (~1-2s) instead of full AI CLI sessions (~8s)
#   - Reads API keys from: env vars > gopass > credentials.sh
#   - Cache: SQLite at ~/.aidevops/.agent-workspace/model-availability.db
#
# Exit codes:
#   0 - Provider/model available
#   1 - Provider/model unavailable or error
#   2 - Rate limited (retry after delay)
#   3 - API key invalid or missing
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

readonly AVAILABILITY_DIR="${HOME}/.aidevops/.agent-workspace"
readonly AVAILABILITY_DB="${AVAILABILITY_DIR}/model-availability.db"
readonly DEFAULT_HEALTH_TTL=300    # 5 minutes for health checks
readonly DEFAULT_RATELIMIT_TTL=60  # 1 minute for rate limit data
readonly PROBE_TIMEOUT=10          # HTTP request timeout in seconds

# Known providers list (opencode is a meta-provider routing through its gateway)
readonly KNOWN_PROVIDERS="anthropic openai google openrouter groq deepseek opencode"

# OpenCode models cache (from models.dev, refreshed by opencode CLI)
readonly OPENCODE_MODELS_CACHE="${HOME}/.cache/opencode/models.json"

# Provider API endpoints for lightweight probes
# These endpoints are chosen for minimal cost: /models endpoints are free
# and return quickly, confirming both key validity and API availability.
# Uses functions instead of associative arrays for bash 3.2 compatibility (macOS).
get_provider_endpoint() {
    local provider="$1"
    case "$provider" in
        anthropic)  echo "https://api.anthropic.com/v1/models" ;;
        openai)     echo "https://api.openai.com/v1/models" ;;
        google)     echo "https://generativelanguage.googleapis.com/v1beta/models" ;;
        openrouter) echo "https://openrouter.ai/api/v1/models" ;;
        groq)       echo "https://api.groq.com/openai/v1/models" ;;
        deepseek)   echo "https://api.deepseek.com/v1/models" ;;
        opencode)   echo "https://opencode.ai/zen/v1/models" ;;
        *) return 1 ;;
    esac
    return 0
}

# Provider to env var mapping (comma-separated for multiple options)
get_provider_key_vars() {
    local provider="$1"
    case "$provider" in
        anthropic)  echo "ANTHROPIC_API_KEY" ;;
        openai)     echo "OPENAI_API_KEY" ;;
        google)     echo "GOOGLE_API_KEY,GEMINI_API_KEY" ;;
        openrouter) echo "OPENROUTER_API_KEY" ;;
        groq)       echo "GROQ_API_KEY" ;;
        deepseek)   echo "DEEPSEEK_API_KEY" ;;
        opencode)   echo "OPENCODE_API_KEY" ;;
        *) return 1 ;;
    esac
    return 0
}

# Check if a provider name is known
is_known_provider() {
    local provider="$1"
    case "$provider" in
        anthropic|openai|google|openrouter|groq|deepseek|opencode) return 0 ;;
        *) return 1 ;;
    esac
}

# Tier to primary/fallback model mapping
# Format: primary_provider/model|fallback_provider/model
# When OpenCode is available, prefer opencode/* model IDs (routed through
# OpenCode's gateway, no direct API keys needed for these).
get_tier_models() {
    local tier="$1"

    # Check if OpenCode is available (CLI installed and models cache exists)
    if _is_opencode_available; then
        case "$tier" in
            haiku)  echo "opencode/claude-3-5-haiku|opencode/gemini-3-flash" ;;
            flash)  echo "google/gemini-2.5-flash|opencode/gemini-3-flash" ;;
            sonnet) echo "opencode/claude-sonnet-4|anthropic/claude-sonnet-4-20250514" ;;
            pro)    echo "google/gemini-2.5-pro|opencode/gemini-3-pro" ;;
            opus)   echo "opencode/claude-opus-4-6|anthropic/claude-opus-4-6" ;;
            health) echo "opencode/claude-sonnet-4-5|google/gemini-2.5-flash" ;;
            eval)   echo "opencode/claude-sonnet-4-5|google/gemini-2.5-flash" ;;
            coding) echo "opencode/claude-opus-4-6|anthropic/claude-opus-4-6" ;;
            *) return 1 ;;
        esac
    else
        case "$tier" in
            haiku)  echo "anthropic/claude-3-5-haiku-20241022|google/gemini-2.5-flash" ;;
            flash)  echo "google/gemini-2.5-flash|openai/gpt-4.1-mini" ;;
            sonnet) echo "anthropic/claude-sonnet-4-20250514|openai/gpt-4.1" ;;
            pro)    echo "google/gemini-2.5-pro|anthropic/claude-sonnet-4-20250514" ;;
            opus)   echo "anthropic/claude-opus-4-6|openai/o3" ;;
            health) echo "anthropic/claude-sonnet-4-5|google/gemini-2.5-flash" ;;
            eval)   echo "anthropic/claude-sonnet-4-5|google/gemini-2.5-flash" ;;
            coding) echo "anthropic/claude-opus-4-6|openai/o3" ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

# Check if a tier name is known
is_known_tier() {
    local tier="$1"
    case "$tier" in
        haiku|flash|sonnet|pro|opus|health|eval|coding) return 0 ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# OpenCode Integration
# =============================================================================
# OpenCode maintains a model registry from models.dev cached at
# ~/.cache/opencode/models.json. This provides instant model discovery
# without needing direct API keys for each provider.

_is_opencode_available() {
    # Check if opencode CLI exists and models cache is present
    if command -v opencode &>/dev/null && [[ -f "$OPENCODE_MODELS_CACHE" && -s "$OPENCODE_MODELS_CACHE" ]]; then
        return 0
    fi
    return 1
}

# Check if a model exists in the OpenCode models cache.
# Returns 0 if found, 1 if not.
_opencode_model_exists() {
    local model_spec="$1"
    local provider model_id

    if [[ "$model_spec" == *"/"* ]]; then
        provider="${model_spec%%/*}"
        model_id="${model_spec#*/}"
    else
        model_id="$model_spec"
        provider=""
    fi

    if [[ ! -f "$OPENCODE_MODELS_CACHE" || ! -s "$OPENCODE_MODELS_CACHE" ]]; then
        return 1
    fi

    # Check the cache JSON: providers are top-level keys, models are nested
    if [[ -n "$provider" ]]; then
        jq -e --arg p "$provider" --arg m "$model_id" \
            '.[$p].models[$m] // empty' "$OPENCODE_MODELS_CACHE" >/dev/null 2>&1
        return $?
    else
        # Search all providers for this model ID
        jq -e --arg m "$model_id" \
            '[.[] | .models[$m] // empty] | length > 0' "$OPENCODE_MODELS_CACHE" >/dev/null 2>&1
        return $?
    fi
}

# =============================================================================
# Database Setup
# =============================================================================

init_db() {
    mkdir -p "$AVAILABILITY_DIR" 2>/dev/null || true

    sqlite3 "$AVAILABILITY_DB" "
        PRAGMA journal_mode=WAL;
        PRAGMA busy_timeout=5000;

        CREATE TABLE IF NOT EXISTS provider_health (
            provider       TEXT PRIMARY KEY,
            status         TEXT NOT NULL DEFAULT 'unknown',
            http_code      INTEGER DEFAULT 0,
            response_ms    INTEGER DEFAULT 0,
            error_message  TEXT DEFAULT '',
            models_count   INTEGER DEFAULT 0,
            checked_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            ttl_seconds    INTEGER NOT NULL DEFAULT $DEFAULT_HEALTH_TTL
        );

        CREATE TABLE IF NOT EXISTS model_availability (
            model_id       TEXT NOT NULL,
            provider       TEXT NOT NULL,
            available      INTEGER NOT NULL DEFAULT 0,
            checked_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            ttl_seconds    INTEGER NOT NULL DEFAULT $DEFAULT_HEALTH_TTL,
            PRIMARY KEY (model_id, provider)
        );

        CREATE TABLE IF NOT EXISTS rate_limits (
            provider       TEXT PRIMARY KEY,
            requests_limit INTEGER DEFAULT 0,
            requests_remaining INTEGER DEFAULT 0,
            requests_reset TEXT DEFAULT '',
            tokens_limit   INTEGER DEFAULT 0,
            tokens_remaining INTEGER DEFAULT 0,
            tokens_reset   TEXT DEFAULT '',
            checked_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            ttl_seconds    INTEGER NOT NULL DEFAULT $DEFAULT_RATELIMIT_TTL
        );

        CREATE TABLE IF NOT EXISTS probe_log (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            provider       TEXT NOT NULL,
            action         TEXT NOT NULL,
            result         TEXT NOT NULL,
            duration_ms    INTEGER DEFAULT 0,
            details        TEXT DEFAULT '',
            timestamp      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE INDEX IF NOT EXISTS idx_probe_log_provider ON probe_log(provider);
        CREATE INDEX IF NOT EXISTS idx_probe_log_timestamp ON probe_log(timestamp);
    " >/dev/null 2>/dev/null || {
        print_error "Failed to initialize availability database"
        return 1
    }
    return 0
}

db_query() {
    local query="$1"
    sqlite3 -cmd ".timeout 5000" "$AVAILABILITY_DB" "$query" 2>/dev/null
    return $?
}

db_query_json() {
    local query="$1"
    sqlite3 -cmd ".timeout 5000" -json "$AVAILABILITY_DB" "$query" 2>/dev/null
    return $?
}

sql_escape() {
    local val="$1"
    echo "${val//\'/\'\'}"
    return 0
}

# =============================================================================
# API Key Resolution
# =============================================================================
# Resolves API keys from three sources (in priority order):
# 1. Environment variables
# 2. gopass encrypted secrets
# 3. credentials.sh plaintext fallback
# SECURITY: Never prints key values. Returns 0 if found, 1 if not.

resolve_api_key() {
    local provider="$1"
    local key_vars
    key_vars=$(get_provider_key_vars "$provider" 2>/dev/null) || return 1

    if [[ -z "$key_vars" ]]; then
        return 1
    fi

    # Check each possible env var name
    IFS=',' read -ra var_names <<< "$key_vars"
    for var_name in "${var_names[@]}"; do
        # Source 1: Environment variable
        if [[ -n "${!var_name:-}" ]]; then
            echo "$var_name"
            return 0
        fi
    done

    # Source 2: gopass (if available)
    if command -v gopass &>/dev/null; then
        for var_name in "${var_names[@]}"; do
            local gopass_path="aidevops/${var_name}"
            if gopass show "$gopass_path" &>/dev/null; then
                # Export the key into the environment for this session
                local key_val
                key_val=$(gopass show "$gopass_path" 2>/dev/null)
                if [[ -n "$key_val" ]]; then
                    export "${var_name}=${key_val}"
                    echo "$var_name"
                    return 0
                fi
            fi
        done
    fi

    # Source 3: credentials.sh (plaintext fallback)
    local creds_file="${HOME}/.config/aidevops/credentials.sh"
    if [[ -f "$creds_file" ]]; then
        # Source the file to get variables (safe: we control this file)
        # shellcheck disable=SC1090
        source "$creds_file"
        for var_name in "${var_names[@]}"; do
            if [[ -n "${!var_name:-}" ]]; then
                echo "$var_name"
                return 0
            fi
        done
    fi

    return 1
}

# Get the actual key value (internal use only, never printed to output)
_get_key_value() {
    local provider="$1"
    local key_vars
    key_vars=$(get_provider_key_vars "$provider" 2>/dev/null) || return 1

    if [[ -z "$key_vars" ]]; then
        return 1
    fi

    IFS=',' read -ra var_names <<< "$key_vars"

    # Try env vars first (may have been populated by resolve_api_key)
    for var_name in "${var_names[@]}"; do
        if [[ -n "${!var_name:-}" ]]; then
            echo "${!var_name}"
            return 0
        fi
    done

    return 1
}

# =============================================================================
# Cache Management
# =============================================================================

is_cache_valid() {
    local provider="$1"
    local table="${2:-provider_health}"
    local custom_ttl="${3:-}"

    local row
    row=$(db_query "
        SELECT checked_at, ttl_seconds FROM $table
        WHERE provider = '$(sql_escape "$provider")'
        LIMIT 1;
    ")

    if [[ -z "$row" ]]; then
        return 1
    fi

    local checked_at ttl_seconds
    checked_at=$(echo "$row" | cut -d'|' -f1)
    ttl_seconds=$(echo "$row" | cut -d'|' -f2)

    # Allow TTL override
    if [[ -n "$custom_ttl" ]]; then
        ttl_seconds="$custom_ttl"
    fi

    local checked_epoch now_epoch
    if [[ "$(uname)" == "Darwin" ]]; then
        checked_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$checked_at" "+%s" 2>/dev/null || echo "0")
    else
        checked_epoch=$(date -d "$checked_at" "+%s" 2>/dev/null || echo "0")
    fi
    now_epoch=$(date "+%s")

    local age=$(( now_epoch - checked_epoch ))
    if [[ "$age" -lt "$ttl_seconds" ]]; then
        return 0
    fi

    return 1
}

invalidate_cache() {
    local provider="${1:-}"

    if [[ -z "$provider" ]]; then
        db_query "DELETE FROM provider_health;"
        db_query "DELETE FROM model_availability;"
        db_query "DELETE FROM rate_limits;"
        print_info "All availability caches cleared"
    else
        local escaped
        escaped=$(sql_escape "$provider")
        db_query "DELETE FROM provider_health WHERE provider = '$escaped';"
        db_query "DELETE FROM model_availability WHERE provider = '$escaped';"
        db_query "DELETE FROM rate_limits WHERE provider = '$escaped';"
        print_info "Cache cleared for provider: $provider"
    fi
    return 0
}

# =============================================================================
# Provider Probing
# =============================================================================

# Probe a single provider via its /models endpoint.
# This is a lightweight check: the /models endpoint is free on all providers,
# returns quickly, and confirms both API key validity and service availability.
#
# Returns: 0=healthy, 1=unhealthy, 2=rate-limited, 3=key-invalid
probe_provider() {
    local provider="$1"
    local force="${2:-false}"
    local custom_ttl="${3:-}"
    local quiet="${4:-false}"

    # Check cache first (unless forced)
    if [[ "$force" != "true" ]]; then
        if is_cache_valid "$provider" "provider_health" "$custom_ttl"; then
            local cached_status
            cached_status=$(db_query "SELECT status FROM provider_health WHERE provider = '$(sql_escape "$provider")';")
            if [[ "$cached_status" == "healthy" ]]; then
                [[ "$quiet" != "true" ]] && print_info "$provider: cached healthy"
                return 0
            elif [[ "$cached_status" == "rate_limited" ]]; then
                [[ "$quiet" != "true" ]] && print_warning "$provider: cached rate-limited"
                return 2
            elif [[ "$cached_status" == "key_invalid" ]]; then
                [[ "$quiet" != "true" ]] && print_warning "$provider: cached key-invalid"
                return 3
            else
                [[ "$quiet" != "true" ]] && print_warning "$provider: cached unhealthy"
                return 1
            fi
        fi
    fi

    # OpenCode provider: check via models cache (no API key needed)
    if [[ "$provider" == "opencode" ]]; then
        if _is_opencode_available; then
            local oc_models_count=0
            oc_models_count=$(jq -r '.opencode.models | length' "$OPENCODE_MODELS_CACHE" 2>/dev/null || echo "0")
            _record_health "opencode" "healthy" 200 0 "" "$oc_models_count"
            [[ "$quiet" != "true" ]] && print_success "opencode: healthy ($oc_models_count models in cache)"
            db_query "
                INSERT INTO probe_log (provider, action, result, duration_ms, details)
                VALUES ('opencode', 'cache_check', 'healthy', 0, '$oc_models_count models from cache');
            " || true
            return 0
        else
            _record_health "opencode" "unhealthy" 0 0 "OpenCode CLI or models cache not found" 0
            [[ "$quiet" != "true" ]] && print_warning "opencode: CLI or models cache not available"
            return 1
        fi
    fi

    # Resolve API key
    local key_var
    if ! key_var=$(resolve_api_key "$provider"); then
        [[ "$quiet" != "true" ]] && print_warning "$provider: no API key configured"
        _record_health "$provider" "no_key" 0 0 "No API key found" 0
        return 3
    fi

    local api_key
    if ! api_key=$(_get_key_value "$provider"); then
        [[ "$quiet" != "true" ]] && print_warning "$provider: could not resolve API key value"
        _record_health "$provider" "no_key" 0 0 "Key var $key_var found but empty" 0
        return 3
    fi

    local endpoint
    endpoint=$(get_provider_endpoint "$provider" 2>/dev/null) || true
    if [[ -z "$endpoint" ]]; then
        [[ "$quiet" != "true" ]] && print_error "$provider: no endpoint configured"
        return 1
    fi

    # Build curl command based on provider auth style
    local -a curl_args=(-s -w '\n%{http_code}\n%{time_total}' --max-time "$PROBE_TIMEOUT" -D -)
    case "$provider" in
        anthropic)
            curl_args+=(-H "x-api-key: ${api_key}" -H "anthropic-version: 2023-06-01")
            ;;
        google)
            # Google uses query parameter for key
            endpoint="${endpoint}?key=${api_key}&pageSize=1"
            ;;
        *)
            # OpenAI-compatible: Bearer token
            curl_args+=(-H "Authorization: Bearer ${api_key}")
            ;;
    esac

    # Execute probe
    local start_ms
    start_ms=$(date +%s%N 2>/dev/null || echo "0")

    local response
    response=$(curl "${curl_args[@]}" "$endpoint" 2>/dev/null) || true

    local end_ms
    end_ms=$(date +%s%N 2>/dev/null || echo "0")
    local duration_ms=0
    if [[ "$start_ms" != "0" && "$end_ms" != "0" ]]; then
        duration_ms=$(( (end_ms - start_ms) / 1000000 ))
    fi

    # Parse response: last two lines are http_code and time_total
    local http_code headers body
    http_code=$(echo "$response" | tail -1)
    # response_time from curl -w is in the second-to-last line (unused; duration_ms is more precise)

    # Separate headers from body (split on blank line)
    headers=$(echo "$response" | sed '/^$/q' | head -50)
    body=$(echo "$response" | sed '1,/^$/d' | head -n -2)

    # Parse rate limit headers (provider-specific)
    _parse_rate_limits "$provider" "$headers"

    # Determine status based on HTTP code
    local status="unknown"
    local error_msg=""
    local models_count=0
    local exit_code=1

    case "$http_code" in
        200)
            status="healthy"
            exit_code=0
            # Count models in response
            case "$provider" in
                google)
                    models_count=$(echo "$body" | jq -r '.models | length' 2>/dev/null || echo "0")
                    ;;
                *)
                    models_count=$(echo "$body" | jq -r '.data | length' 2>/dev/null || echo "0")
                    ;;
            esac
            [[ "$quiet" != "true" ]] && print_success "$provider: healthy (${duration_ms}ms, $models_count models)"
            ;;
        401|403)
            status="key_invalid"
            error_msg="Authentication failed (HTTP $http_code)"
            exit_code=3
            [[ "$quiet" != "true" ]] && print_error "$provider: API key invalid (HTTP $http_code)"
            ;;
        429)
            status="rate_limited"
            error_msg="Rate limited (HTTP 429)"
            exit_code=2
            [[ "$quiet" != "true" ]] && print_warning "$provider: rate limited"
            ;;
        500|502|503|504)
            status="unhealthy"
            error_msg="Server error (HTTP $http_code)"
            exit_code=1
            [[ "$quiet" != "true" ]] && print_error "$provider: server error (HTTP $http_code)"
            ;;
        "")
            status="unreachable"
            error_msg="Connection failed or timeout"
            exit_code=1
            [[ "$quiet" != "true" ]] && print_error "$provider: unreachable (timeout or DNS failure)"
            ;;
        *)
            status="unhealthy"
            error_msg="Unexpected HTTP $http_code"
            exit_code=1
            [[ "$quiet" != "true" ]] && print_warning "$provider: unexpected response (HTTP $http_code)"
            ;;
    esac

    # Record health status
    _record_health "$provider" "$status" "$http_code" "$duration_ms" "$error_msg" "$models_count"

    # Log the probe
    db_query "
        INSERT INTO probe_log (provider, action, result, duration_ms, details)
        VALUES (
            '$(sql_escape "$provider")',
            'health_probe',
            '$(sql_escape "$status")',
            $duration_ms,
            '$(sql_escape "HTTP $http_code, $models_count models")'
        );
    " || true

    # Prune old probe logs (keep last 100 per provider)
    db_query "
        DELETE FROM probe_log WHERE id IN (
            SELECT id FROM probe_log
            WHERE provider = '$(sql_escape "$provider")'
            ORDER BY timestamp DESC
            LIMIT -1 OFFSET 100
        );
    " || true

    return "$exit_code"
}

_record_health() {
    local provider="$1"
    local status="$2"
    local http_code="$3"
    local duration_ms="$4"
    local error_msg="$5"
    local models_count="$6"

    db_query "
        INSERT INTO provider_health (provider, status, http_code, response_ms, error_message, models_count, checked_at, ttl_seconds)
        VALUES (
            '$(sql_escape "$provider")',
            '$(sql_escape "$status")',
            $http_code,
            $duration_ms,
            '$(sql_escape "$error_msg")',
            $models_count,
            strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            $DEFAULT_HEALTH_TTL
        )
        ON CONFLICT(provider) DO UPDATE SET
            status = excluded.status,
            http_code = excluded.http_code,
            response_ms = excluded.response_ms,
            error_message = excluded.error_message,
            models_count = excluded.models_count,
            checked_at = excluded.checked_at,
            ttl_seconds = excluded.ttl_seconds;
    " || true
    return 0
}

# =============================================================================
# Rate Limit Parsing
# =============================================================================

_parse_rate_limits() {
    local provider="$1"
    local headers="$2"

    local req_limit=0 req_remaining=0 req_reset=""
    local tok_limit=0 tok_remaining=0 tok_reset=""

    case "$provider" in
        anthropic)
            req_limit=$(echo "$headers" | grep -i 'anthropic-ratelimit-requests-limit' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
            req_remaining=$(echo "$headers" | grep -i 'anthropic-ratelimit-requests-remaining' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
            req_reset=$(echo "$headers" | grep -i 'anthropic-ratelimit-requests-reset' | head -1 | awk '{print $2}' | tr -d '\r' || echo "")
            tok_limit=$(echo "$headers" | grep -i 'anthropic-ratelimit-tokens-limit' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
            tok_remaining=$(echo "$headers" | grep -i 'anthropic-ratelimit-tokens-remaining' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
            tok_reset=$(echo "$headers" | grep -i 'anthropic-ratelimit-tokens-reset' | head -1 | awk '{print $2}' | tr -d '\r' || echo "")
            ;;
        openai)
            req_limit=$(echo "$headers" | grep -i 'x-ratelimit-limit-requests' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
            req_remaining=$(echo "$headers" | grep -i 'x-ratelimit-remaining-requests' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
            req_reset=$(echo "$headers" | grep -i 'x-ratelimit-reset-requests' | head -1 | awk '{print $2}' | tr -d '\r' || echo "")
            tok_limit=$(echo "$headers" | grep -i 'x-ratelimit-limit-tokens' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
            tok_remaining=$(echo "$headers" | grep -i 'x-ratelimit-remaining-tokens' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
            tok_reset=$(echo "$headers" | grep -i 'x-ratelimit-reset-tokens' | head -1 | awk '{print $2}' | tr -d '\r' || echo "")
            ;;
        groq)
            req_limit=$(echo "$headers" | grep -i 'x-ratelimit-limit-requests' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
            req_remaining=$(echo "$headers" | grep -i 'x-ratelimit-remaining-requests' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
            req_reset=$(echo "$headers" | grep -i 'x-ratelimit-reset-requests' | head -1 | awk '{print $2}' | tr -d '\r' || echo "")
            tok_limit=$(echo "$headers" | grep -i 'x-ratelimit-limit-tokens' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
            tok_remaining=$(echo "$headers" | grep -i 'x-ratelimit-remaining-tokens' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
            tok_reset=$(echo "$headers" | grep -i 'x-ratelimit-reset-tokens' | head -1 | awk '{print $2}' | tr -d '\r' || echo "")
            ;;
        *)
            # Other providers: try generic x-ratelimit headers
            req_limit=$(echo "$headers" | grep -i 'x-ratelimit-limit' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
            req_remaining=$(echo "$headers" | grep -i 'x-ratelimit-remaining' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
            ;;
    esac

    # Only store if we got meaningful data
    if [[ "$req_limit" != "0" || "$req_remaining" != "0" ]]; then
        db_query "
            INSERT INTO rate_limits (provider, requests_limit, requests_remaining, requests_reset,
                                     tokens_limit, tokens_remaining, tokens_reset, checked_at, ttl_seconds)
            VALUES (
                '$(sql_escape "$provider")',
                ${req_limit:-0},
                ${req_remaining:-0},
                '$(sql_escape "${req_reset:-}")',
                ${tok_limit:-0},
                ${tok_remaining:-0},
                '$(sql_escape "${tok_reset:-}")',
                strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
                $DEFAULT_RATELIMIT_TTL
            )
            ON CONFLICT(provider) DO UPDATE SET
                requests_limit = excluded.requests_limit,
                requests_remaining = excluded.requests_remaining,
                requests_reset = excluded.requests_reset,
                tokens_limit = excluded.tokens_limit,
                tokens_remaining = excluded.tokens_remaining,
                tokens_reset = excluded.tokens_reset,
                checked_at = excluded.checked_at,
                ttl_seconds = excluded.ttl_seconds;
        " || true
    fi
    return 0
}

# =============================================================================
# Model Availability Check
# =============================================================================

# Check if a specific model is available from its provider.
# First checks provider health, then verifies the model exists in the
# provider's model list (from the cached /models response or model-registry).
check_model_available() {
    local model_spec="$1"
    local force="${2:-false}"
    local quiet="${3:-false}"

    # Parse provider/model format
    local provider model_id
    if [[ "$model_spec" == *"/"* ]]; then
        provider="${model_spec%%/*}"
        model_id="${model_spec#*/}"
    else
        # Try to infer provider from model name
        case "$model_spec" in
            claude*) provider="anthropic" ;;
            gpt*|o3*|o4*) provider="openai" ;;
            gemini*) provider="google" ;;
            deepseek*) provider="deepseek" ;;
            llama*) provider="groq" ;;
            *) provider="" ;;
        esac
        model_id="$model_spec"
    fi

    if [[ -z "$provider" ]]; then
        [[ "$quiet" != "true" ]] && print_error "Cannot determine provider for: $model_spec"
        return 1
    fi

    # Check provider health first
    local probe_exit=0
    probe_provider "$provider" "$force" "" "$quiet" || probe_exit=$?

    if [[ "$probe_exit" -ne 0 ]]; then
        return "$probe_exit"
    fi

    # Check model-specific availability from cache
    local cached_available
    cached_available=$(db_query "
        SELECT available FROM model_availability
        WHERE model_id = '$(sql_escape "$model_id")' AND provider = '$(sql_escape "$provider")'
        AND (julianday('now') - julianday(checked_at)) * 86400 < ttl_seconds;
    ")

    if [[ -n "$cached_available" ]]; then
        if [[ "$cached_available" == "1" ]]; then
            [[ "$quiet" != "true" ]] && print_info "$model_spec: available (cached)"
            return 0
        else
            [[ "$quiet" != "true" ]] && print_warning "$model_spec: unavailable (cached)"
            return 1
        fi
    fi

    # Model-level check 1: OpenCode models cache (instant, preferred)
    if _opencode_model_exists "$model_spec"; then
        _record_model_availability "$model_id" "$provider" 1
        [[ "$quiet" != "true" ]] && print_success "$model_spec: available (OpenCode cache confirmed)"
        return 0
    fi

    # Model-level check 2: query the model-registry SQLite if available
    local registry_db="${AVAILABILITY_DIR}/model-registry.db"
    if [[ -f "$registry_db" ]]; then
        local in_registry
        in_registry=$(sqlite3 -cmd ".timeout 5000" "$registry_db" "
            SELECT COUNT(*) FROM provider_models
            WHERE model_id LIKE '%$(sql_escape "$model_id")%'
            AND provider LIKE '%$(sql_escape "$provider")%';
        " 2>/dev/null || echo "0")

        if [[ "$in_registry" -gt 0 ]]; then
            _record_model_availability "$model_id" "$provider" 1
            [[ "$quiet" != "true" ]] && print_success "$model_spec: available (registry confirmed)"
            return 0
        fi
    fi

    # If provider is healthy but we can't confirm the specific model,
    # assume available (provider health is the primary signal)
    _record_model_availability "$model_id" "$provider" 1
    [[ "$quiet" != "true" ]] && print_info "$model_spec: assumed available (provider healthy)"
    return 0
}

_record_model_availability() {
    local model_id="$1"
    local provider="$2"
    local available="$3"

    db_query "
        INSERT INTO model_availability (model_id, provider, available, checked_at, ttl_seconds)
        VALUES (
            '$(sql_escape "$model_id")',
            '$(sql_escape "$provider")',
            $available,
            strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            $DEFAULT_HEALTH_TTL
        )
        ON CONFLICT(model_id, provider) DO UPDATE SET
            available = excluded.available,
            checked_at = excluded.checked_at,
            ttl_seconds = excluded.ttl_seconds;
    " || true
    return 0
}

# =============================================================================
# Tier Resolution with Fallback
# =============================================================================

# Resolve the best available model for a given tier.
# Checks primary model first, falls back to secondary if primary is unavailable.
# If both fail, delegates to fallback-chain-helper.sh for extended chain resolution
# including gateway providers (OpenRouter, Cloudflare AI Gateway).
# Output: provider/model_id on stdout
# Returns: 0 if a model was resolved, 1 if no model available for this tier
resolve_tier() {
    local tier="$1"
    local force="${2:-false}"
    local quiet="${3:-false}"

    local tier_spec
    tier_spec=$(get_tier_models "$tier" 2>/dev/null) || true
    if [[ -z "$tier_spec" ]]; then
        [[ "$quiet" != "true" ]] && print_error "Unknown tier: $tier"
        return 1
    fi

    local primary fallback
    primary="${tier_spec%%|*}"
    fallback="${tier_spec#*|}"

    # Try primary
    if check_model_available "$primary" "$force" "true"; then
        echo "$primary"
        [[ "$quiet" != "true" ]] && print_success "Resolved $tier -> $primary (primary)"
        return 0
    fi

    # Try fallback
    if [[ -n "$fallback" && "$fallback" != "$primary" ]]; then
        if check_model_available "$fallback" "$force" "true"; then
            echo "$fallback"
            [[ "$quiet" != "true" ]] && print_warning "Resolved $tier -> $fallback (fallback, primary $primary unavailable)"
            return 0
        fi
    fi

    # Extended fallback: delegate to fallback-chain-helper.sh (t132.4)
    # This walks the full configured chain including gateway providers
    local chain_helper="${SCRIPT_DIR}/fallback-chain-helper.sh"
    if [[ -x "$chain_helper" ]]; then
        [[ "$quiet" != "true" ]] && print_info "Primary/fallback exhausted, trying extended fallback chain..."
        local chain_resolved
        chain_resolved=$("$chain_helper" resolve "$tier" --quiet 2>/dev/null) || true
        if [[ -n "$chain_resolved" ]]; then
            echo "$chain_resolved"
            [[ "$quiet" != "true" ]] && print_warning "Resolved $tier -> $chain_resolved (via fallback chain)"
            return 0
        fi
    fi

    [[ "$quiet" != "true" ]] && print_error "No available model for tier: $tier (tried $primary, $fallback, and extended chain)"
    return 1
}

# Resolve a model using the full fallback chain (t132.4).
# Unlike resolve_tier which tries primary/fallback first, this goes directly
# to the fallback chain configuration for maximum flexibility.
# Supports per-agent overrides via --agent flag.
resolve_tier_chain() {
    local tier="$1"
    local force="${2:-false}"
    local quiet="${3:-false}"
    local agent_file="${4:-}"

    local chain_helper="${SCRIPT_DIR}/fallback-chain-helper.sh"
    if [[ ! -x "$chain_helper" ]]; then
        [[ "$quiet" != "true" ]] && print_warning "fallback-chain-helper.sh not found, falling back to resolve_tier"
        resolve_tier "$tier" "$force" "$quiet"
        return $?
    fi

    local -a chain_args=("resolve" "$tier")
    [[ "$quiet" == "true" ]] && chain_args+=("--quiet")
    [[ "$force" == "true" ]] && chain_args+=("--force")
    [[ -n "$agent_file" ]] && chain_args+=("--agent" "$agent_file")

    local resolved
    resolved=$("$chain_helper" "${chain_args[@]}" 2>/dev/null) || true

    if [[ -n "$resolved" ]]; then
        echo "$resolved"
        [[ "$quiet" != "true" ]] && print_success "Resolved $tier -> $resolved (via fallback chain)"
        return 0
    fi

    [[ "$quiet" != "true" ]] && print_error "No available model for tier: $tier (fallback chain exhausted)"
    return 1
}

# =============================================================================
# Commands
# =============================================================================

cmd_check() {
    local target="${1:-}"
    local force=false
    local quiet=false
    local json_flag=false
    local custom_ttl=""
    shift || true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            --quiet) quiet=true; shift ;;
            --json) json_flag=true; shift ;;
            --ttl) custom_ttl="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$target" ]]; then
        print_error "Usage: model-availability-helper.sh check <provider|model>"
        return 1
    fi

    # Determine if target is a provider name, tier, or model spec
    if is_known_provider "$target"; then
        probe_provider "$target" "$force" "$custom_ttl" "$quiet"
        return $?
    elif is_known_tier "$target"; then
        resolve_tier "$target" "$force" "$quiet" >/dev/null
        return $?
    else
        # Assume it's a model spec (provider/model or model name)
        check_model_available "$target" "$force" "$quiet"
        return $?
    fi
}

cmd_probe() {
    local all=false
    local target=""
    local force=false
    local quiet=false
    local json_flag=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) all=true; shift ;;
            --force) force=true; shift ;;
            --quiet) quiet=true; shift ;;
            --json) json_flag=true; shift ;;
            *)
                if [[ -z "$target" ]]; then
                    target="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -n "$target" ]] && ! is_known_provider "$target"; then
        print_error "Unknown provider: $target"
        print_info "Available: $KNOWN_PROVIDERS"
        return 1
    fi

    local providers_to_probe=()
    if [[ -n "$target" ]]; then
        providers_to_probe=("$target")
    elif [[ "$all" == "true" ]]; then
        # Probe all known providers
        for p in $KNOWN_PROVIDERS; do
            providers_to_probe+=("$p")
        done
    else
        # Probe only providers with configured keys
        for p in $KNOWN_PROVIDERS; do
            if resolve_api_key "$p" >/dev/null 2>&1; then
                providers_to_probe+=("$p")
            fi
        done
    fi

    if [[ ${#providers_to_probe[@]} -eq 0 ]]; then
        print_warning "No providers to probe (no API keys configured)"
        return 1
    fi

    [[ "$quiet" != "true" ]] && echo ""
    [[ "$quiet" != "true" ]] && echo "Provider Availability Probe"
    [[ "$quiet" != "true" ]] && echo "==========================="
    [[ "$quiet" != "true" ]] && echo ""

    local healthy=0 unhealthy=0 no_key=0
    for provider in "${providers_to_probe[@]}"; do
        local exit_code=0
        probe_provider "$provider" "$force" "" "$quiet" || exit_code=$?
        case "$exit_code" in
            0) healthy=$((healthy + 1)) ;;
            3) no_key=$((no_key + 1)) ;;
            *) unhealthy=$((unhealthy + 1)) ;;
        esac
    done

    [[ "$quiet" != "true" ]] && echo ""
    [[ "$quiet" != "true" ]] && print_info "Summary: $healthy healthy, $unhealthy unhealthy, $no_key no key"

    if [[ "$json_flag" == "true" ]]; then
        db_query_json "SELECT provider, status, http_code, response_ms, models_count, checked_at FROM provider_health ORDER BY provider;"
    fi

    [[ "$unhealthy" -gt 0 ]] && return 1
    return 0
}

cmd_status() {
    local json_flag=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_flag=true; shift ;;
            *) shift ;;
        esac
    done

    if [[ ! -f "$AVAILABILITY_DB" ]]; then
        print_warning "No availability data. Run 'model-availability-helper.sh probe' first."
        return 0
    fi

    if [[ "$json_flag" == "true" ]]; then
        echo "{"
        echo "  \"providers\":"
        db_query_json "SELECT provider, status, http_code, response_ms, models_count, error_message, checked_at FROM provider_health ORDER BY provider;"
        echo ","
        echo "  \"rate_limits\":"
        db_query_json "SELECT provider, requests_limit, requests_remaining, requests_reset, tokens_limit, tokens_remaining, tokens_reset, checked_at FROM rate_limits ORDER BY provider;"
        echo "}"
        return 0
    fi

    echo ""
    echo "Model Availability Status"
    echo "========================="
    echo ""

    echo "Provider Health:"
    echo ""
    printf "  %-12s %-12s %-6s %-8s %-8s %-20s\n" \
        "Provider" "Status" "HTTP" "Time" "Models" "Last Check"
    printf "  %-12s %-12s %-6s %-8s %-8s %-20s\n" \
        "--------" "------" "----" "----" "------" "----------"

    db_query "
        SELECT provider, status, http_code, response_ms, models_count, checked_at
        FROM provider_health ORDER BY provider;
    " | while IFS='|' read -r prov stat code ms models checked; do
        local status_display="$stat"
        case "$stat" in
            healthy) status_display="${GREEN}healthy${NC}" ;;
            unhealthy|unreachable) status_display="${RED}$stat${NC}" ;;
            rate_limited) status_display="${YELLOW}rate-ltd${NC}" ;;
            key_invalid) status_display="${RED}bad-key${NC}" ;;
            no_key) status_display="${YELLOW}no-key${NC}" ;;
        esac

        # Calculate age
        local age_display="$checked"
        local checked_epoch now_epoch
        if [[ "$(uname)" == "Darwin" ]]; then
            checked_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$checked" "+%s" 2>/dev/null || echo "0")
        else
            checked_epoch=$(date -d "$checked" "+%s" 2>/dev/null || echo "0")
        fi
        now_epoch=$(date "+%s")
        local age=$(( now_epoch - checked_epoch ))
        if [[ "$age" -lt 60 ]]; then
            age_display="${age}s ago"
        elif [[ "$age" -lt 3600 ]]; then
            age_display="$((age / 60))m ago"
        else
            age_display="$((age / 3600))h ago"
        fi

        printf "  %-12s %-12b %-6s %-8s %-8s %-20s\n" \
            "$prov" "$status_display" "$code" "${ms}ms" "$models" "$age_display"
    done

    # Show rate limits if available
    local rl_count
    rl_count=$(db_query "SELECT COUNT(*) FROM rate_limits WHERE requests_limit > 0;")
    if [[ "$rl_count" -gt 0 ]]; then
        echo ""
        echo "Rate Limits:"
        echo ""
        printf "  %-12s %-15s %-15s %-15s\n" \
            "Provider" "Req Remaining" "Tok Remaining" "Reset"
        printf "  %-12s %-15s %-15s %-15s\n" \
            "--------" "-------------" "-------------" "-----"

        db_query "
            SELECT provider, requests_limit, requests_remaining, requests_reset,
                   tokens_limit, tokens_remaining, tokens_reset
            FROM rate_limits WHERE requests_limit > 0 ORDER BY provider;
        " | while IFS='|' read -r prov rl rr rres tl tr tres; do
            local req_display="${rr}/${rl}"
            local tok_display="${tr}/${tl}"
            [[ "$tl" == "0" ]] && tok_display="n/a"
            printf "  %-12s %-15s %-15s %-15s\n" \
                "$prov" "$req_display" "$tok_display" "${rres:-n/a}"
        done
    fi

    # Show tier resolution
    echo ""
    echo "Tier Resolution:"
    echo ""
    printf "  %-8s %-35s %-35s\n" "Tier" "Primary" "Fallback"
    printf "  %-8s %-35s %-35s\n" "----" "-------" "--------"
    for tier in haiku flash sonnet pro opus health eval coding; do
        local spec
        spec=$(get_tier_models "$tier" 2>/dev/null) || spec=""
        local primary="${spec%%|*}"
        local fallback="${spec#*|}"
        printf "  %-8s %-35s %-35s\n" "$tier" "$primary" "$fallback"
    done

    echo ""

    # Show recent probe log
    local log_count
    log_count=$(db_query "SELECT COUNT(*) FROM probe_log;")
    if [[ "$log_count" -gt 0 ]]; then
        echo "Recent Probes (last 10):"
        echo ""
        db_query "
            SELECT timestamp, provider, action, result, duration_ms
            FROM probe_log ORDER BY timestamp DESC LIMIT 10;
        " | while IFS='|' read -r ts prov _action result ms; do
            echo "  $ts  $prov  $result  ${ms}ms"
        done
        echo ""
    fi

    return 0
}

cmd_rate_limits() {
    local json_flag=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_flag=true; shift ;;
            *) shift ;;
        esac
    done

    if [[ ! -f "$AVAILABILITY_DB" ]]; then
        print_warning "No rate limit data. Run 'model-availability-helper.sh probe' first."
        return 0
    fi

    if [[ "$json_flag" == "true" ]]; then
        db_query_json "SELECT * FROM rate_limits ORDER BY provider;"
        return 0
    fi

    echo ""
    echo "Rate Limit Status"
    echo "================="
    echo ""

    local count
    count=$(db_query "SELECT COUNT(*) FROM rate_limits;")

    if [[ "$count" -eq 0 ]]; then
        print_info "No rate limit data cached. Probe providers to collect rate limit headers."
        return 0
    fi

    printf "  %-12s %-12s %-12s %-20s %-12s %-12s %-20s %-20s\n" \
        "Provider" "Req Limit" "Req Left" "Req Reset" "Tok Limit" "Tok Left" "Tok Reset" "Checked"
    printf "  %-12s %-12s %-12s %-20s %-12s %-12s %-20s %-20s\n" \
        "--------" "---------" "--------" "---------" "---------" "--------" "---------" "-------"

    db_query "SELECT * FROM rate_limits ORDER BY provider;" | \
    while IFS='|' read -r prov rl rr rres tl tr tres checked _ttl; do
        printf "  %-12s %-12s %-12s %-20s %-12s %-12s %-20s %-20s\n" \
            "$prov" "$rl" "$rr" "${rres:-n/a}" "$tl" "$tr" "${tres:-n/a}" "$checked"
    done

    echo ""
    return 0
}

cmd_resolve() {
    local tier="${1:-}"
    local force=false
    local quiet=false
    local json_flag=false
    shift || true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            --quiet) quiet=true; shift ;;
            --json) json_flag=true; shift ;;
            *) shift ;;
        esac
    done

    if [[ -z "$tier" ]]; then
        print_error "Usage: model-availability-helper.sh resolve <tier>"
        print_info "Available tiers: haiku flash sonnet pro opus health eval coding"
        return 1
    fi

    local resolved
    resolved=$(resolve_tier "$tier" "$force" "$quiet")
    local exit_code=$?

    if [[ "$json_flag" == "true" ]]; then
        if [[ $exit_code -eq 0 ]]; then
            local provider model_id
            provider="${resolved%%/*}"
            model_id="${resolved#*/}"
            echo "{\"tier\":\"$tier\",\"provider\":\"$provider\",\"model\":\"$model_id\",\"full_id\":\"$resolved\",\"status\":\"available\"}"
        else
            echo "{\"tier\":\"$tier\",\"status\":\"unavailable\"}"
        fi
    else
        if [[ $exit_code -eq 0 ]]; then
            echo "$resolved"
        fi
    fi

    return "$exit_code"
}

cmd_invalidate() {
    local target="${1:-}"
    invalidate_cache "$target"
    return 0
}

# Resolve using the full fallback chain (t132.4).
# Delegates to fallback-chain-helper.sh for extended chain resolution
# including gateway providers and per-agent overrides.
cmd_resolve_chain() {
    local tier="${1:-}"
    local force=false
    local quiet=false
    local json_flag=false
    local agent_file=""
    shift || true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            --quiet) quiet=true; shift ;;
            --json) json_flag=true; shift ;;
            --agent) agent_file="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$tier" ]]; then
        print_error "Usage: model-availability-helper.sh resolve-chain <tier> [--agent file]"
        print_info "Available tiers: haiku flash sonnet pro opus health eval coding"
        return 1
    fi

    local resolved
    resolved=$(resolve_tier_chain "$tier" "$force" "$quiet" "$agent_file")
    local exit_code=$?

    if [[ "$json_flag" == "true" ]]; then
        if [[ $exit_code -eq 0 ]]; then
            local provider model_id
            provider="${resolved%%/*}"
            model_id="${resolved#*/}"
            echo "{\"tier\":\"$tier\",\"provider\":\"$provider\",\"model\":\"$model_id\",\"full_id\":\"$resolved\",\"status\":\"available\",\"method\":\"chain\"}"
        else
            echo "{\"tier\":\"$tier\",\"status\":\"exhausted\",\"method\":\"chain\"}"
        fi
    else
        if [[ $exit_code -eq 0 ]]; then
            echo "$resolved"
        fi
    fi

    return "$exit_code"
}

cmd_help() {
    echo ""
    echo "Model Availability Helper - Probe before dispatch"
    echo "================================================="
    echo ""
    echo "Usage: model-availability-helper.sh [command] [options]"
    echo ""
    echo "Commands:"
    echo "  check <provider|model|tier>  Check availability (exit 0=yes, 1=no, 2=rate-limited, 3=bad-key)"
    echo "  probe [provider] [--all]     Probe providers (default: only those with keys)"
    echo "  status                       Show cached availability status"
    echo "  rate-limits                  Show rate limit data from cache"
    echo "  resolve <tier>               Resolve best available model for tier (primary + fallback)"
    echo "  resolve-chain <tier>         Resolve via full fallback chain (t132.4, includes gateways)"
    echo "  invalidate [provider]        Clear cache (all or specific provider)"
    echo "  help                         Show this help"
    echo ""
    echo "Options:"
    echo "  --json        Output in JSON format"
    echo "  --quiet       Suppress informational output"
    echo "  --force       Bypass cache and probe live"
    echo "  --ttl N       Override cache TTL in seconds"
    echo "  --agent FILE  Per-agent fallback chain override (resolve-chain only)"
    echo ""
    echo "Tiers:"
    echo "  haiku   - Cheapest (triage, classification)"
    echo "  flash   - Low cost (large context, summarization)"
    echo "  sonnet  - Medium (code implementation, review)"
    echo "  pro     - Medium-high (large codebase analysis)"
    echo "  opus    - Highest (architecture, complex reasoning)"
    echo "  health  - Cheapest probe model"
    echo "  eval    - Cheap evaluation model"
    echo "  coding  - Best SOTA coding model"
    echo ""
    echo "Providers:"
    echo "  anthropic, openai, google, openrouter, groq, deepseek, opencode"
    echo "  The 'opencode' provider uses the OpenCode models cache (~/.cache/opencode/models.json)"
    echo "  instead of direct API probing. When OpenCode is available, tier resolution"
    echo "  prefers opencode/* model IDs (routed through OpenCode's gateway)."
    echo ""
    echo "Examples:"
    echo "  model-availability-helper.sh check anthropic"
    echo "  model-availability-helper.sh check opencode"
    echo "  model-availability-helper.sh check opencode/claude-sonnet-4"
    echo "  model-availability-helper.sh check anthropic/claude-sonnet-4-20250514"
    echo "  model-availability-helper.sh check sonnet"
    echo "  model-availability-helper.sh probe --all"
    echo "  model-availability-helper.sh resolve opus --json"
    echo "  model-availability-helper.sh resolve-chain coding --json"
    echo "  model-availability-helper.sh resolve-chain sonnet --agent models/sonnet.md"
    echo "  model-availability-helper.sh status"
    echo "  model-availability-helper.sh rate-limits --json"
    echo "  model-availability-helper.sh invalidate anthropic"
    echo ""
    echo "Integration with supervisor:"
    echo "  # In supervisor dispatch, replace check_model_health() with:"
    echo "  model-availability-helper.sh check anthropic --quiet"
    echo ""
    echo "  # Resolve model with fallback for a tier:"
    echo "  MODEL=\$(model-availability-helper.sh resolve coding --quiet)"
    echo ""
    echo "  # Resolve via full fallback chain (includes gateway providers):"
    echo "  MODEL=\$(model-availability-helper.sh resolve-chain coding --quiet)"
    echo ""
    echo "Exit codes:"
    echo "  0 - Available"
    echo "  1 - Unavailable or error"
    echo "  2 - Rate limited"
    echo "  3 - API key invalid or missing"
    echo ""
    echo "Cache: $AVAILABILITY_DB"
    echo "OpenCode models: $OPENCODE_MODELS_CACHE"
    echo "TTL: ${DEFAULT_HEALTH_TTL}s (health), ${DEFAULT_RATELIMIT_TTL}s (rate limits)"
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
        check)
            cmd_check "$@"
            ;;
        probe)
            cmd_probe "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        rate-limits|ratelimits|rate_limits)
            cmd_rate_limits "$@"
            ;;
        resolve)
            cmd_resolve "$@"
            ;;
        resolve-chain|resolve_chain)
            cmd_resolve_chain "$@"
            ;;
        invalidate|clear|flush)
            cmd_invalidate "$@"
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
