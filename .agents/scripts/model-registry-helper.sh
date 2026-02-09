#!/usr/bin/env bash
# shellcheck disable=SC1091

# Model Registry Helper - Provider/Model Registry with Periodic Sync
# Maintains a SQLite registry of AI models from configured providers,
# compares against local subagent definitions, flags deprecated/renamed
# models, and suggests new models worth adding.
#
# Usage: model-registry-helper.sh [command] [options]
#
# Commands:
#   sync          Sync registry from all sources (subagents, embedded data, APIs)
#   list          List all models in the registry
#   status        Show registry health and staleness
#   check         Check configured models against live provider APIs
#   suggest       Suggest new models worth adding to subagent definitions
#   deprecations  Show deprecated/renamed/unavailable models
#   diff          Show differences between registry and local config
#   export        Export registry as JSON
#   help          Show this help
#
# Options:
#   --json        Output in JSON format (where supported)
#   --quiet       Suppress informational output
#   --force       Force full resync even if cache is fresh
#
# Runs on: aidevops update, optionally via cron
# Storage: ~/.aidevops/.agent-workspace/model-registry.db
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

readonly REGISTRY_DIR="${HOME}/.aidevops/.agent-workspace"
readonly REGISTRY_DB="${REGISTRY_DIR}/model-registry.db"
readonly SYNC_INTERVAL=86400  # 24 hours in seconds
readonly AGENTS_DIR="${SCRIPT_DIR}/.."
readonly MODELS_DIR="${AGENTS_DIR}/tools/ai-assistants/models"

# =============================================================================
# Database Setup
# =============================================================================

init_db() {
    mkdir -p "$REGISTRY_DIR" 2>/dev/null || true

    sqlite3 "$REGISTRY_DB" "
        CREATE TABLE IF NOT EXISTS models (
            model_id       TEXT NOT NULL,
            provider       TEXT NOT NULL,
            display_name   TEXT DEFAULT '',
            normalized_name TEXT DEFAULT '',
            context_window INTEGER DEFAULT 0,
            input_price    REAL DEFAULT 0.0,
            output_price   REAL DEFAULT 0.0,
            tier           TEXT DEFAULT '',
            capabilities   TEXT DEFAULT '',
            best_for       TEXT DEFAULT '',
            source         TEXT DEFAULT 'embedded',
            status         TEXT DEFAULT 'active',
            first_seen     TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            last_seen      TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            last_verified  TEXT DEFAULT '',
            deprecated     INTEGER DEFAULT 0,
            deprecation_note TEXT DEFAULT '',
            PRIMARY KEY (model_id, provider)
        );

        CREATE TABLE IF NOT EXISTS subagent_models (
            tier           TEXT PRIMARY KEY,
            model_id       TEXT NOT NULL,
            model_full_id  TEXT DEFAULT '',
            normalized_name TEXT DEFAULT '',
            fallback_id    TEXT DEFAULT '',
            subagent_file  TEXT NOT NULL,
            last_synced    TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE TABLE IF NOT EXISTS provider_models (
            model_id       TEXT NOT NULL,
            provider       TEXT NOT NULL,
            discovered_at  TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            in_registry    INTEGER DEFAULT 0,
            in_subagents   INTEGER DEFAULT 0,
            PRIMARY KEY (model_id, provider)
        );

        CREATE TABLE IF NOT EXISTS sync_log (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            sync_type      TEXT NOT NULL,
            source         TEXT NOT NULL,
            models_added   INTEGER DEFAULT 0,
            models_updated INTEGER DEFAULT 0,
            models_removed INTEGER DEFAULT 0,
            timestamp      TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            details        TEXT DEFAULT ''
        );
    " 2>/dev/null || {
        print_error "Failed to initialize registry database"
        return 1
    }
    return 0
}

# =============================================================================
# Model Name Normalization
# =============================================================================
# Normalizes model names for fuzzy matching across different naming conventions.
# e.g., "claude-3-5-haiku" and "claude-haiku-3.5" both normalize to "claude-haiku"

normalize_model_name() {
    local name="$1"
    # Strip provider prefix
    name="${name#*/}"
    # Strip date suffixes (e.g., -20250514, -20241022)
    name="${name%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}"
    # Strip preview suffixes (e.g., -preview-05-20)
    name=$(echo "$name" | sed -E 's/-preview-[0-9]{2}-[0-9]{2}$//')
    # Strip version numbers (e.g., -3-5, -3.5, -4, -2.5, -2.0)
    name=$(echo "$name" | sed -E 's/-[0-9]+(\.[0-9]+)?//g')
    # Lowercase
    echo "$name" | tr '[:upper:]' '[:lower:]'
    return 0
}

# =============================================================================
# SQL Helpers
# =============================================================================

sql_escape() {
    local val="$1"
    echo "${val//\'/\'\'}"
    return 0
}

db_query() {
    local query="$1"
    sqlite3 -cmd ".timeout 5000" "$REGISTRY_DB" "$query" 2>/dev/null
    return $?
}

db_query_csv() {
    local query="$1"
    sqlite3 -cmd ".timeout 5000" -csv -header "$REGISTRY_DB" "$query" 2>/dev/null
    return $?
}

db_query_json() {
    local query="$1"
    sqlite3 -cmd ".timeout 5000" -json "$REGISTRY_DB" "$query" 2>/dev/null
    return $?
}

# =============================================================================
# Sync: Subagent Frontmatter
# =============================================================================

sync_subagents() {
    local added=0
    local updated=0

    if [[ ! -d "$MODELS_DIR" ]]; then
        print_warning "Models directory not found: $MODELS_DIR"
        return 0
    fi

    local md_file
    for md_file in "$MODELS_DIR"/*.md; do
        [[ ! -f "$md_file" ]] && continue
        local basename_file
        basename_file=$(basename "$md_file")

        # Skip README and non-model files
        [[ "$basename_file" == "README.md" ]] && continue
        [[ "$basename_file" == *"-reviewer.md" ]] && continue

        # Extract frontmatter fields
        local model_full="" model_tier="" model_fallback=""
        local in_frontmatter=false
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
                case "$line" in
                    model:*)
                        model_full="${line#model:}"
                        model_full="${model_full#"${model_full%%[![:space:]]*}"}"
                        ;;
                    model-tier:*)
                        model_tier="${line#model-tier:}"
                        model_tier="${model_tier#"${model_tier%%[![:space:]]*}"}"
                        ;;
                    model-fallback:*)
                        model_fallback="${line#model-fallback:}"
                        model_fallback="${model_fallback#"${model_fallback%%[![:space:]]*}"}"
                        ;;
                esac
            fi
        done < "$md_file"

        if [[ -z "$model_tier" || -z "$model_full" ]]; then
            continue
        fi

        # Extract short model_id from full ID (e.g., anthropic/claude-sonnet-4-20250514 -> claude-sonnet-4)
        local model_short
        model_short="${model_full#*/}"
        # Strip trailing date suffix (e.g., -20250514)
        model_short="${model_short%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}"

        # Compute normalized name for fuzzy matching
        local norm_name
        norm_name=$(normalize_model_name "$model_full")

        # Upsert into subagent_models
        db_query "
            INSERT INTO subagent_models (tier, model_id, model_full_id, normalized_name, fallback_id, subagent_file, last_synced)
            VALUES (
                '$(sql_escape "$model_tier")',
                '$(sql_escape "$model_short")',
                '$(sql_escape "$model_full")',
                '$(sql_escape "$norm_name")',
                '$(sql_escape "$model_fallback")',
                '$(sql_escape "$basename_file")',
                strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
            )
            ON CONFLICT(tier) DO UPDATE SET
                model_id = excluded.model_id,
                model_full_id = excluded.model_full_id,
                normalized_name = excluded.normalized_name,
                fallback_id = excluded.fallback_id,
                subagent_file = excluded.subagent_file,
                last_synced = excluded.last_synced;
        " && updated=$((updated + 1))
    done

    # Log sync
    db_query "
        INSERT INTO sync_log (sync_type, source, models_added, models_updated, details)
        VALUES ('subagents', 'frontmatter', $added, $updated, 'Synced from $MODELS_DIR');
    "

    print_info "Subagent sync: $updated tiers updated from frontmatter"
    return 0
}

# =============================================================================
# Sync: Embedded Model Data (from compare-models-helper.sh)
# =============================================================================

sync_embedded() {
    local added=0
    local updated=0

    # Source the model data from compare-models-helper.sh
    local compare_helper="${SCRIPT_DIR}/compare-models-helper.sh"
    if [[ ! -f "$compare_helper" ]]; then
        print_warning "compare-models-helper.sh not found"
        return 0
    fi

    # Extract MODEL_DATA from compare-models-helper.sh
    local model_data=""
    local in_model_data=false
    while IFS= read -r line; do
        if [[ "$line" == 'readonly MODEL_DATA="'* ]]; then
            in_model_data=true
            model_data="${line#*=\"}"
            # Check if single-line
            if [[ "$model_data" == *'"' ]]; then
                model_data="${model_data%\"}"
                break
            fi
            continue
        fi
        if [[ "$in_model_data" == "true" ]]; then
            if [[ "$line" == *'"' ]]; then
                model_data="${model_data}
${line%\"}"
                break
            fi
            model_data="${model_data}
${line}"
        fi
    done < "$compare_helper"

    if [[ -z "$model_data" ]]; then
        print_warning "Could not extract MODEL_DATA from compare-models-helper.sh"
        return 0
    fi

    # Parse and upsert each model
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local model_id provider display_name ctx input output tier caps best_for
        model_id=$(echo "$line" | cut -d'|' -f1)
        provider=$(echo "$line" | cut -d'|' -f2)
        display_name=$(echo "$line" | cut -d'|' -f3)
        ctx=$(echo "$line" | cut -d'|' -f4)
        input=$(echo "$line" | cut -d'|' -f5)
        output=$(echo "$line" | cut -d'|' -f6)
        tier=$(echo "$line" | cut -d'|' -f7)
        caps=$(echo "$line" | cut -d'|' -f8)
        best_for=$(echo "$line" | cut -d'|' -f9)

        # Compute normalized name for fuzzy matching
        local norm_name
        norm_name=$(normalize_model_name "$model_id")

        # Check if model already exists
        local existing
        existing=$(db_query "SELECT model_id FROM models WHERE model_id='$(sql_escape "$model_id")' AND provider='$(sql_escape "$provider")';")

        if [[ -n "$existing" ]]; then
            db_query "
                UPDATE models SET
                    display_name = '$(sql_escape "$display_name")',
                    normalized_name = '$(sql_escape "$norm_name")',
                    context_window = $ctx,
                    input_price = $input,
                    output_price = $output,
                    tier = '$(sql_escape "$tier")',
                    capabilities = '$(sql_escape "$caps")',
                    best_for = '$(sql_escape "$best_for")',
                    last_seen = strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
                    source = 'embedded'
                WHERE model_id = '$(sql_escape "$model_id")' AND provider = '$(sql_escape "$provider")';
            "
            updated=$((updated + 1))
        else
            db_query "
                INSERT INTO models (model_id, provider, display_name, normalized_name, context_window, input_price, output_price, tier, capabilities, best_for, source)
                VALUES (
                    '$(sql_escape "$model_id")',
                    '$(sql_escape "$provider")',
                    '$(sql_escape "$display_name")',
                    '$(sql_escape "$norm_name")',
                    $ctx, $input, $output,
                    '$(sql_escape "$tier")',
                    '$(sql_escape "$caps")',
                    '$(sql_escape "$best_for")',
                    'embedded'
                );
            "
            added=$((added + 1))
        fi
    done <<< "$model_data"

    db_query "
        INSERT INTO sync_log (sync_type, source, models_added, models_updated, details)
        VALUES ('embedded', 'compare-models-helper.sh', $added, $updated, 'Parsed MODEL_DATA');
    "

    print_info "Embedded sync: $added added, $updated updated from compare-models-helper.sh"
    return 0
}

# =============================================================================
# Sync: Provider APIs (live model discovery)
# =============================================================================

sync_providers() {
    local added=0
    local json_flag="${1:-false}"

    # Reuse provider key detection from compare-models-helper.sh
    local provider_env_keys="Anthropic|ANTHROPIC_API_KEY
OpenAI|OPENAI_API_KEY
Google|GOOGLE_API_KEY,GEMINI_API_KEY
OpenRouter|OPENROUTER_API_KEY
Groq|GROQ_API_KEY
DeepSeek|DEEPSEEK_API_KEY"

    while IFS= read -r pline; do
        local provider key_names
        provider=$(echo "$pline" | cut -d'|' -f1)
        key_names=$(echo "$pline" | cut -d'|' -f2)

        local key_value=""
        IFS=',' read -ra keys <<< "$key_names"
        for key_name in "${keys[@]}"; do
            if [[ -n "${!key_name:-}" ]]; then
                key_value="${!key_name}"
                break
            fi
        done

        [[ -z "$key_value" ]] && continue

        local models_json=""
        case "$provider" in
            Anthropic)
                models_json=$(curl -s --max-time "$DEFAULT_TIMEOUT" \
                    -H "x-api-key: ${key_value}" \
                    -H "anthropic-version: 2023-06-01" \
                    "https://api.anthropic.com/v1/models" 2>/dev/null) || continue
                ;;
            OpenAI)
                models_json=$(curl -s --max-time "$DEFAULT_TIMEOUT" \
                    -H "Authorization: Bearer ${key_value}" \
                    "https://api.openai.com/v1/models" 2>/dev/null) || continue
                ;;
            Google)
                models_json=$(curl -s --max-time "$DEFAULT_TIMEOUT" \
                    "https://generativelanguage.googleapis.com/v1beta/models?key=${key_value}" 2>/dev/null) || continue
                ;;
            OpenRouter)
                models_json=$(curl -s --max-time "$DEFAULT_TIMEOUT" \
                    -H "Authorization: Bearer ${key_value}" \
                    "https://openrouter.ai/api/v1/models" 2>/dev/null) || continue
                ;;
            Groq)
                models_json=$(curl -s --max-time "$DEFAULT_TIMEOUT" \
                    -H "Authorization: Bearer ${key_value}" \
                    "https://api.groq.com/openai/v1/models" 2>/dev/null) || continue
                ;;
            DeepSeek)
                models_json=$(curl -s --max-time "$DEFAULT_TIMEOUT" \
                    -H "Authorization: Bearer ${key_value}" \
                    "https://api.deepseek.com/v1/models" 2>/dev/null) || continue
                ;;
            *)
                continue
                ;;
        esac

        [[ -z "$models_json" ]] && continue

        # Extract model IDs
        local model_ids=""
        case "$provider" in
            Google)
                model_ids=$(echo "$models_json" | jq -r '.models[].name // empty' 2>/dev/null | sed 's|^models/||' | sort) || continue
                ;;
            *)
                model_ids=$(echo "$models_json" | jq -r '.data[].id // empty' 2>/dev/null | sort) || continue
                ;;
        esac

        [[ -z "$model_ids" ]] && continue

        local provider_count=0
        while IFS= read -r mid; do
            [[ -z "$mid" ]] && continue

            # Check if this model is in our registry
            local in_registry
            in_registry=$(db_query "SELECT COUNT(*) FROM models WHERE model_id LIKE '%$(sql_escape "$mid")%' AND provider='$(sql_escape "$provider")';")
            local in_reg_flag=0
            [[ "$in_registry" -gt 0 ]] && in_reg_flag=1

            # Check if referenced in subagents
            local in_subagents
            in_subagents=$(db_query "SELECT COUNT(*) FROM subagent_models WHERE model_full_id LIKE '%$(sql_escape "$mid")%';")
            local in_sub_flag=0
            [[ "$in_subagents" -gt 0 ]] && in_sub_flag=1

            db_query "
                INSERT INTO provider_models (model_id, provider, in_registry, in_subagents, discovered_at)
                VALUES (
                    '$(sql_escape "$mid")',
                    '$(sql_escape "$provider")',
                    $in_reg_flag,
                    $in_sub_flag,
                    strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                )
                ON CONFLICT(model_id, provider) DO UPDATE SET
                    in_registry = excluded.in_registry,
                    in_subagents = excluded.in_subagents,
                    discovered_at = excluded.discovered_at;
            "
            provider_count=$((provider_count + 1))
        done <<< "$model_ids"

        added=$((added + provider_count))
        print_info "  $provider: $provider_count models discovered"
    done <<< "$provider_env_keys"

    db_query "
        INSERT INTO sync_log (sync_type, source, models_added, models_updated, details)
        VALUES ('provider_api', 'live', $added, 0, 'Discovered from provider APIs');
    "

    print_info "Provider sync: $added total models discovered from APIs"
    return 0
}

# =============================================================================
# Commands
# =============================================================================

cmd_sync() {
    local force=false
    local quiet=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            --quiet) quiet=true; shift ;;
            *) shift ;;
        esac
    done

    # Check if sync is needed
    if [[ "$force" != "true" ]]; then
        local last_sync
        last_sync=$(db_query "SELECT timestamp FROM sync_log ORDER BY id DESC LIMIT 1;" 2>/dev/null || echo "")
        if [[ -n "$last_sync" ]]; then
            local last_epoch now_epoch
            if [[ "$(uname)" == "Darwin" ]]; then
                last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_sync" "+%s" 2>/dev/null || echo "0")
            else
                last_epoch=$(date -d "$last_sync" "+%s" 2>/dev/null || echo "0")
            fi
            now_epoch=$(date "+%s")
            local age=$((now_epoch - last_epoch))
            if [[ $age -lt $SYNC_INTERVAL ]]; then
                local hours_ago=$((age / 3600))
                [[ "$quiet" != "true" ]] && print_info "Registry synced ${hours_ago}h ago (interval: $((SYNC_INTERVAL / 3600))h). Use --force to resync."
                return 0
            fi
        fi
    fi

    [[ "$quiet" != "true" ]] && echo ""
    [[ "$quiet" != "true" ]] && echo "Model Registry Sync"
    [[ "$quiet" != "true" ]] && echo "==================="
    [[ "$quiet" != "true" ]] && echo ""

    # Backup before sync
    if [[ -f "$REGISTRY_DB" ]]; then
        backup_sqlite_db "$REGISTRY_DB" "pre-sync" >/dev/null 2>&1 || true
    fi

    # Phase 1: Sync subagent frontmatter
    [[ "$quiet" != "true" ]] && print_info "Phase 1: Syncing subagent frontmatter..."
    sync_subagents

    # Phase 2: Sync embedded model data
    [[ "$quiet" != "true" ]] && print_info "Phase 2: Syncing embedded model data..."
    sync_embedded

    # Phase 3: Sync from provider APIs (if keys available)
    [[ "$quiet" != "true" ]] && print_info "Phase 3: Discovering models from provider APIs..."
    sync_providers

    # Cleanup old backups
    cleanup_sqlite_backups "$REGISTRY_DB" 3

    [[ "$quiet" != "true" ]] && echo ""
    [[ "$quiet" != "true" ]] && print_success "Registry sync complete"
    return 0
}

cmd_list() {
    local json_flag=false
    local filter_provider=""
    local filter_tier=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_flag=true; shift ;;
            --provider) filter_provider="${2:-}"; shift 2 ;;
            --tier) filter_tier="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    local where_clause="WHERE 1=1"
    [[ -n "$filter_provider" ]] && where_clause="$where_clause AND provider='$(sql_escape "$filter_provider")'"
    [[ -n "$filter_tier" ]] && where_clause="$where_clause AND tier='$(sql_escape "$filter_tier")'"

    if [[ "$json_flag" == "true" ]]; then
        db_query_json "
            SELECT model_id, provider, display_name, context_window, input_price, output_price,
                   tier, capabilities, status, deprecated, last_seen
            FROM models $where_clause
            ORDER BY provider, input_price;
        "
        return $?
    fi

    echo ""
    echo "Model Registry"
    echo "=============="
    echo ""

    local count
    count=$(db_query "SELECT COUNT(*) FROM models $where_clause;")

    if [[ "$count" -eq 0 ]]; then
        print_warning "Registry is empty. Run 'model-registry-helper.sh sync' first."
        return 0
    fi

    printf "%-24s %-10s %-8s %-10s %-10s %-7s %-8s\n" \
        "Model" "Provider" "Context" "In/1M" "Out/1M" "Tier" "Status"
    printf "%-24s %-10s %-8s %-10s %-10s %-7s %-8s\n" \
        "-----" "--------" "-------" "-----" "------" "----" "------"

    db_query "
        SELECT model_id, provider, context_window, input_price, output_price, tier, status, deprecated
        FROM models $where_clause
        ORDER BY provider, input_price;
    " | while IFS='|' read -r mid prov ctx inp outp tier stat dep; do
        local ctx_fmt
        if [[ "$ctx" -ge 1000000 ]]; then
            ctx_fmt="1M"
        elif [[ "$ctx" -ge 500000 ]]; then
            ctx_fmt="512K"
        elif [[ "$ctx" -ge 200000 ]]; then
            ctx_fmt="200K"
        elif [[ "$ctx" -ge 128000 ]]; then
            ctx_fmt="128K"
        else
            ctx_fmt="${ctx}"
        fi

        local status_display="$stat"
        [[ "$dep" == "1" ]] && status_display="DEPR"

        printf "%-24s %-10s %-8s \$%-9s \$%-9s %-7s %-8s\n" \
            "$mid" "$prov" "$ctx_fmt" "$inp" "$outp" "$tier" "$status_display"
    done

    echo ""
    echo "Total: $count models"
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

    if [[ ! -f "$REGISTRY_DB" ]]; then
        print_warning "Registry not initialized. Run 'model-registry-helper.sh sync' first."
        return 0
    fi

    local total_models total_providers total_subagents total_provider_models
    local last_sync deprecated_count

    total_models=$(db_query "SELECT COUNT(*) FROM models;")
    total_providers=$(db_query "SELECT COUNT(DISTINCT provider) FROM models;")
    total_subagents=$(db_query "SELECT COUNT(*) FROM subagent_models;")
    total_provider_models=$(db_query "SELECT COUNT(*) FROM provider_models;")
    deprecated_count=$(db_query "SELECT COUNT(*) FROM models WHERE deprecated=1;")
    last_sync=$(db_query "SELECT timestamp FROM sync_log ORDER BY id DESC LIMIT 1;" || echo "never")

    # Calculate staleness
    local staleness="unknown"
    if [[ -n "$last_sync" && "$last_sync" != "never" ]]; then
        local last_epoch now_epoch
        if [[ "$(uname)" == "Darwin" ]]; then
            last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_sync" "+%s" 2>/dev/null || echo "0")
        else
            last_epoch=$(date -d "$last_sync" "+%s" 2>/dev/null || echo "0")
        fi
        now_epoch=$(date "+%s")
        local age=$((now_epoch - last_epoch))
        if [[ $age -lt 3600 ]]; then
            staleness="fresh ($((age / 60))m ago)"
        elif [[ $age -lt 86400 ]]; then
            staleness="recent ($((age / 3600))h ago)"
        else
            staleness="stale ($((age / 86400))d ago)"
        fi
    fi

    if [[ "$json_flag" == "true" ]]; then
        echo "{\"total_models\":$total_models,\"total_providers\":$total_providers,\"subagent_tiers\":$total_subagents,\"provider_models_discovered\":$total_provider_models,\"deprecated\":$deprecated_count,\"last_sync\":\"$last_sync\",\"staleness\":\"$staleness\"}"
        return 0
    fi

    echo ""
    echo "Model Registry Status"
    echo "====================="
    echo ""
    echo "  Registry models:     $total_models"
    echo "  Providers:           $total_providers"
    echo "  Subagent tiers:      $total_subagents"
    echo "  API-discovered:      $total_provider_models"
    echo "  Deprecated:          $deprecated_count"
    echo "  Last sync:           ${last_sync:-never}"
    echo "  Staleness:           $staleness"
    echo ""

    # Show subagent tier mapping
    echo "Subagent Tier Mapping:"
    echo ""
    printf "  %-8s %-24s %-36s %-24s\n" "Tier" "Model" "Full ID" "Fallback"
    printf "  %-8s %-24s %-36s %-24s\n" "----" "-----" "-------" "--------"

    db_query "SELECT tier, model_id, model_full_id, fallback_id FROM subagent_models ORDER BY tier;" | \
    while IFS='|' read -r tier mid full_id fallback; do
        printf "  %-8s %-24s %-36s %-24s\n" "$tier" "$mid" "$full_id" "$fallback"
    done

    echo ""

    # Show recent sync log
    echo "Recent Sync History:"
    echo ""
    db_query "
        SELECT timestamp, sync_type, source, models_added, models_updated
        FROM sync_log ORDER BY id DESC LIMIT 5;
    " | while IFS='|' read -r ts stype src added updated; do
        echo "  $ts  $stype ($src): +$added ~$updated"
    done

    echo ""
    return 0
}

cmd_check() {
    local json_flag=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_flag=true; shift ;;
            *) shift ;;
        esac
    done

    echo ""
    echo "Model Availability Check"
    echo "========================"
    echo ""

    # Check each subagent model against provider APIs
    local issues=0

    db_query "SELECT tier, model_id, model_full_id, fallback_id FROM subagent_models;" | \
    while IFS='|' read -r tier mid full_id fallback; do
        local provider
        provider=$(echo "$full_id" | cut -d'/' -f1)

        # Get normalized name for this subagent model
        local norm_name
        norm_name=$(db_query "SELECT normalized_name FROM subagent_models WHERE tier='$(sql_escape "$tier")';" 2>/dev/null || echo "")
        [[ -z "$norm_name" ]] && norm_name=$(normalize_model_name "$full_id")

        # Check if model exists in provider_models (try both directions for fuzzy match)
        local found
        found=$(db_query "
            SELECT COUNT(*) FROM provider_models
            WHERE (model_id LIKE '%$(sql_escape "$mid")%'
                   OR '$(sql_escape "$mid")' LIKE '%' || model_id || '%')
            AND provider LIKE '%$(sql_escape "$provider")%';
        " 2>/dev/null || echo "0")

        local status_icon="Y"
        local status_text="available"

        if [[ "$found" -eq 0 ]]; then
            # Not found in API discovery - check embedded registry via normalized name
            local in_embedded
            in_embedded=$(db_query "
                SELECT COUNT(*) FROM models
                WHERE normalized_name = '$(sql_escape "$norm_name")'
                   OR model_id LIKE '%$(sql_escape "$mid")%'
                   OR '$(sql_escape "$mid")' LIKE '%' || model_id || '%';
            " 2>/dev/null || echo "0")

            if [[ "$in_embedded" -gt 0 ]]; then
                status_icon="?"
                status_text="in registry, not verified via API"
            else
                status_icon="!"
                status_text="NOT FOUND in registry or API"
                issues=$((issues + 1))
            fi
        fi

        printf "  %s %-8s %-36s %s\n" "$status_icon" "$tier" "$full_id" "$status_text"
    done

    echo ""
    if [[ $issues -gt 0 ]]; then
        print_warning "$issues model(s) have availability issues"
    else
        print_success "All configured models appear available"
    fi
    echo ""
    return 0
}

cmd_suggest() {
    local json_flag=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_flag=true; shift ;;
            *) shift ;;
        esac
    done

    echo ""
    echo "Model Suggestions"
    echo "================="
    echo ""
    echo "Models discovered from provider APIs but not in the registry:"
    echo ""

    local count=0
    db_query "
        SELECT pm.model_id, pm.provider, pm.discovered_at
        FROM provider_models pm
        WHERE pm.in_registry = 0
        AND pm.in_subagents = 0
        ORDER BY pm.provider, pm.model_id;
    " | while IFS='|' read -r mid prov discovered; do
        # Filter to interesting models (skip internal/deprecated-looking ones)
        case "$mid" in
            *embed*|*tts*|*whisper*|*dall-e*|*moderation*|*babbage*|*davinci-00*|*search*|*instruct*|*realtime*)
                continue
                ;;
        esac
        echo "  [$prov] $mid (discovered: $discovered)"
        count=$((count + 1))
    done

    echo ""
    if [[ $count -eq 0 ]]; then
        print_info "No new model suggestions. Registry is up to date."
    else
        echo "  $count potential models found."
        echo "  Review and add relevant ones to compare-models-helper.sh MODEL_DATA"
        echo "  and create subagent files in $MODELS_DIR/ as needed."
    fi
    echo ""
    return 0
}

cmd_deprecations() {
    local json_flag=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_flag=true; shift ;;
            *) shift ;;
        esac
    done

    echo ""
    echo "Deprecated/Unavailable Models"
    echo "============================="
    echo ""

    local dep_count
    dep_count=$(db_query "SELECT COUNT(*) FROM models WHERE deprecated=1;")

    if [[ "$dep_count" -eq 0 ]]; then
        print_info "No deprecated models found in registry."
        echo ""

        # Check for models in subagents that aren't in provider APIs
        echo "Models in subagents not confirmed by provider APIs:"
        echo ""
        local unconfirmed=0
        db_query "SELECT tier, model_id, model_full_id FROM subagent_models;" | \
        while IFS='|' read -r tier mid full_id; do
            local short_id
            short_id="${full_id#*/}"
            local api_found
            api_found=$(db_query "
                SELECT COUNT(*) FROM provider_models
                WHERE model_id = '$(sql_escape "$short_id")';
            " 2>/dev/null || echo "0")

            if [[ "$api_found" -eq 0 ]]; then
                echo "  ! [$tier] $full_id - not found in API discovery"
                unconfirmed=$((unconfirmed + 1))
            fi
        done

        if [[ $unconfirmed -eq 0 ]]; then
            print_info "  All subagent models confirmed via API discovery."
        fi
    else
        db_query "
            SELECT model_id, provider, deprecation_note, last_seen
            FROM models WHERE deprecated=1
            ORDER BY provider, model_id;
        " | while IFS='|' read -r mid prov note last; do
            echo "  ! $mid ($prov)"
            [[ -n "$note" ]] && echo "    Note: $note"
            echo "    Last seen: $last"
        done
    fi

    echo ""
    return 0
}

cmd_diff() {
    local json_flag=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_flag=true; shift ;;
            *) shift ;;
        esac
    done

    echo ""
    echo "Registry vs Local Config Diff"
    echo "=============================="
    echo ""

    # Compare subagent models with registry
    echo "Subagent Models vs Registry:"
    echo ""

    db_query "SELECT tier, model_id, model_full_id, normalized_name FROM subagent_models;" | \
    while IFS='|' read -r tier mid full_id norm_name; do
        [[ -z "$norm_name" ]] && norm_name=$(normalize_model_name "$full_id")
        local reg_match
        reg_match=$(db_query "
            SELECT model_id, input_price, output_price
            FROM models
            WHERE normalized_name = '$(sql_escape "$norm_name")'
               OR model_id LIKE '%$(sql_escape "$mid")%'
               OR '$(sql_escape "$mid")' LIKE '%' || model_id || '%'
            LIMIT 1;
        " 2>/dev/null || echo "")

        if [[ -n "$reg_match" ]]; then
            local reg_id reg_input reg_output
            reg_id=$(echo "$reg_match" | cut -d'|' -f1)
            reg_input=$(echo "$reg_match" | cut -d'|' -f2)
            reg_output=$(echo "$reg_match" | cut -d'|' -f3)
            printf "  = %-8s %-24s (registry: %s, \$%s/\$%s)\n" \
                "$tier" "$full_id" "$reg_id" "$reg_input" "$reg_output"
        else
            printf "  ! %-8s %-24s (NOT in registry)\n" "$tier" "$full_id"
        fi
    done

    echo ""

    # Show registry models not in subagents
    echo "Registry Models Not in Subagents:"
    echo ""

    local orphan_count=0
    db_query "
        SELECT m.model_id, m.provider, m.tier
        FROM models m
        WHERE NOT EXISTS (
            SELECT 1 FROM subagent_models s
            WHERE m.normalized_name = s.normalized_name
               OR m.model_id LIKE '%' || s.model_id || '%'
               OR s.model_id LIKE '%' || m.model_id || '%'
        )
        ORDER BY m.provider, m.model_id;
    " | while IFS='|' read -r mid prov tier; do
        printf "  + %-24s %-10s %-7s\n" "$mid" "$prov" "$tier"
        orphan_count=$((orphan_count + 1))
    done

    echo ""
    return 0
}

cmd_export() {
    local format="json"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --csv) format="csv"; shift ;;
            *) shift ;;
        esac
    done

    case "$format" in
        csv)
            db_query_csv "
                SELECT model_id, provider, display_name, context_window,
                       input_price, output_price, tier, capabilities,
                       best_for, status, deprecated, last_seen
                FROM models ORDER BY provider, model_id;
            "
            ;;
        *)
            db_query_json "
                SELECT model_id, provider, display_name, context_window,
                       input_price, output_price, tier, capabilities,
                       best_for, status, deprecated, last_seen
                FROM models ORDER BY provider, model_id;
            "
            ;;
    esac
    return $?
}

cmd_help() {
    echo ""
    echo "Model Registry Helper - Provider/Model Registry with Periodic Sync"
    echo "==================================================================="
    echo ""
    echo "Usage: model-registry-helper.sh [command] [options]"
    echo ""
    echo "Commands:"
    echo "  sync          Sync registry from all sources (subagents, embedded data, APIs)"
    echo "  list          List all models in the registry"
    echo "  status        Show registry health, staleness, and tier mapping"
    echo "  check         Check configured subagent models against registry/APIs"
    echo "  suggest       Suggest new models discovered from APIs but not tracked"
    echo "  deprecations  Show deprecated/renamed/unavailable models"
    echo "  diff          Show differences between registry and local config"
    echo "  export        Export registry data (JSON or CSV)"
    echo "  help          Show this help"
    echo ""
    echo "Options:"
    echo "  --json        Output in JSON format (list, status, export)"
    echo "  --quiet       Suppress informational output (sync)"
    echo "  --force       Force full resync even if cache is fresh (sync)"
    echo "  --provider X  Filter by provider name (list)"
    echo "  --tier X      Filter by tier (list)"
    echo "  --csv         Export as CSV instead of JSON (export)"
    echo ""
    echo "Examples:"
    echo "  model-registry-helper.sh sync                    # Full sync"
    echo "  model-registry-helper.sh sync --force            # Force resync"
    echo "  model-registry-helper.sh list                    # List all models"
    echo "  model-registry-helper.sh list --provider Google  # Google models only"
    echo "  model-registry-helper.sh status                  # Registry health"
    echo "  model-registry-helper.sh check                   # Verify subagent models"
    echo "  model-registry-helper.sh suggest                 # New model suggestions"
    echo "  model-registry-helper.sh diff                    # Config vs registry"
    echo "  model-registry-helper.sh export --json           # Export as JSON"
    echo ""
    echo "Integration:"
    echo "  - Runs automatically on 'aidevops update'"
    echo "  - Can be added to cron for periodic sync"
    echo "  - Storage: $REGISTRY_DB"
    echo ""
    echo "Data Sources:"
    echo "  1. Subagent frontmatter ($MODELS_DIR/*.md)"
    echo "  2. Embedded data (compare-models-helper.sh MODEL_DATA)"
    echo "  3. Provider APIs (Anthropic, OpenAI, Google, OpenRouter, Groq, DeepSeek)"
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
        sync)
            cmd_sync "$@"
            ;;
        list)
            cmd_list "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        check)
            cmd_check "$@"
            ;;
        suggest)
            cmd_suggest "$@"
            ;;
        deprecations|deprecated)
            cmd_deprecations "$@"
            ;;
        diff)
            cmd_diff "$@"
            ;;
        export)
            cmd_export "$@"
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
