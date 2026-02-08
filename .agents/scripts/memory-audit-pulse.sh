#!/usr/bin/env bash
# =============================================================================
# Memory Audit Pulse - Periodic self-improvement scan
# =============================================================================
# Automated memory hygiene: dedup, prune, graduate, and surface improvement
# opportunities. Designed to run as a supervisor pulse phase or standalone.
#
# Usage:
#   memory-audit-pulse.sh run [--dry-run] [--quiet]
#   memory-audit-pulse.sh status
#   memory-audit-pulse.sh help
#
# Integration:
#   - Supervisor pulse: called during memory audit phase
#   - Cron: 0 4 * * * ~/.aidevops/agents/scripts/memory-audit-pulse.sh run --quiet
#   - Manual: /memory-audit or memory-audit-pulse.sh run
#
# Phases:
#   1. Deduplication — remove exact and near-duplicate memories
#   2. Pruning — remove stale entries (>90 days, never accessed)
#   3. Graduation — promote high-value memories to shared docs
#   4. Opportunity scan — identify self-improvement patterns
#   5. Report — summary of actions taken
#
# Author: AI DevOps Framework
# Version: 1.0.0
# License: MIT
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

readonly MEMORY_DIR="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}"
readonly MEMORY_DB="$MEMORY_DIR/memory.db"
readonly AUDIT_LOG_DIR="$HOME/.aidevops/.agent-workspace/work/memory-audit"
readonly AUDIT_MARKER="$MEMORY_DIR/.last_audit_pulse"
readonly AUDIT_INTERVAL_HOURS=24

# Minimum interval between audit pulses (prevents redundant runs)
readonly AUDIT_INTERVAL_SECONDS=$((AUDIT_INTERVAL_HOURS * 3600))

# All log functions write to stderr so phase functions can return counts on stdout
log_info() { echo -e "${BLUE}[AUDIT]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[AUDIT]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[AUDIT]${NC} $*" >&2; }
log_error() { echo -e "${RED}[AUDIT]${NC} $*" >&2; }

#######################################
# SQLite wrapper with busy_timeout
#######################################
db() {
    sqlite3 -cmd ".timeout 5000" "$@"
}

#######################################
# Check if enough time has passed since last audit
# Returns 0 if audit should run, 1 if too soon
#######################################
should_run() {
    if [[ ! -f "$AUDIT_MARKER" ]]; then
        return 0
    fi

    local last_run
    last_run=$(stat -f %m "$AUDIT_MARKER" 2>/dev/null || stat -c %Y "$AUDIT_MARKER" 2>/dev/null || echo "0")
    local now
    now=$(date +%s)
    local elapsed=$((now - last_run))

    if [[ "$elapsed" -lt "$AUDIT_INTERVAL_SECONDS" ]]; then
        local remaining=$(( (AUDIT_INTERVAL_SECONDS - elapsed) / 3600 ))
        log_info "Last audit was $((elapsed / 3600))h ago (interval: ${AUDIT_INTERVAL_HOURS}h). Next in ~${remaining}h."
        return 1
    fi

    return 0
}

#######################################
# Phase 1: Deduplication
#######################################
phase_dedup() {
    local dry_run="$1"
    local quiet="$2"

    [[ "$quiet" != "true" ]] && log_info "Phase 1: Deduplication..."

    local output
    if [[ "$dry_run" == "true" ]]; then
        output=$("${SCRIPT_DIR}/memory-helper.sh" dedup --dry-run 2>&1) || true
    else
        output=$("${SCRIPT_DIR}/memory-helper.sh" dedup 2>&1) || true
    fi

    # Extract count from output
    local removed=0
    if echo "$output" | grep -q "Removed"; then
        removed=$(echo "$output" | grep -oE 'Removed [0-9]+' | grep -oE '[0-9]+' || echo "0")
    elif echo "$output" | grep -q "Would remove"; then
        removed=$(echo "$output" | grep -oE 'Would remove [0-9]+' | grep -oE '[0-9]+' || echo "0")
    fi

    [[ "$quiet" != "true" ]] && {
        if [[ "$removed" -gt 0 ]]; then
            log_success "Dedup: ${removed} duplicates ${dry_run:+would be }removed"
        else
            log_success "Dedup: no duplicates found"
        fi
    }

    echo "$removed"
    return 0
}

#######################################
# Phase 2: Pruning
#######################################
phase_prune() {
    local dry_run="$1"
    local quiet="$2"

    [[ "$quiet" != "true" ]] && log_info "Phase 2: Pruning stale entries..."

    if [[ ! -f "$MEMORY_DB" ]]; then
        echo "0"
        return 0
    fi

    # Count stale entries (>90 days, never accessed)
    local stale_count
    stale_count=$(db "$MEMORY_DB" \
        "SELECT COUNT(*) FROM learnings l LEFT JOIN learning_access a ON l.id = a.id WHERE l.created_at < datetime('now', '-90 days') AND a.id IS NULL;" \
        2>/dev/null || echo "0")

    if [[ "$stale_count" -gt 0 ]]; then
        if [[ "$dry_run" == "true" ]]; then
            [[ "$quiet" != "true" ]] && log_info "Prune: would remove $stale_count stale entries"
        else
            # The auto_prune in memory-helper.sh handles this, but we force it here
            "${SCRIPT_DIR}/memory-helper.sh" prune --older-than-days 90 >/dev/null 2>&1 || true
            [[ "$quiet" != "true" ]] && log_success "Prune: removed $stale_count stale entries"
        fi
    else
        [[ "$quiet" != "true" ]] && log_success "Prune: no stale entries"
    fi

    echo "$stale_count"
    return 0
}

#######################################
# Phase 3: Graduation
#######################################
phase_graduate() {
    local dry_run="$1"
    local quiet="$2"

    [[ "$quiet" != "true" ]] && log_info "Phase 3: Graduating high-value memories..."

    local graduate_script="${SCRIPT_DIR}/memory-graduate-helper.sh"

    if [[ ! -x "$graduate_script" ]]; then
        # Try repo path as fallback
        local repo_root
        repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
        if [[ -n "$repo_root" && -x "$repo_root/.agents/scripts/memory-graduate-helper.sh" ]]; then
            graduate_script="$repo_root/.agents/scripts/memory-graduate-helper.sh"
        else
            [[ "$quiet" != "true" ]] && log_warn "Graduate: memory-graduate-helper.sh not found, skipping"
            echo "0"
            return 0
        fi
    fi

    local grad_args=("graduate")
    [[ "$dry_run" == "true" ]] && grad_args+=("--dry-run")

    local output
    output=$("$graduate_script" "${grad_args[@]}" 2>&1) || true

    local graduated=0
    if echo "$output" | grep -q "Graduated"; then
        graduated=$(echo "$output" | grep -oE 'Graduated [0-9]+' | grep -oE '[0-9]+' || echo "0")
    fi

    [[ "$quiet" != "true" ]] && {
        if [[ "$graduated" -gt 0 ]]; then
            log_success "Graduate: ${graduated} memories ${dry_run:+would be }promoted to shared docs"
        else
            log_success "Graduate: no new candidates"
        fi
    }

    echo "$graduated"
    return 0
}

#######################################
# Phase 4: Opportunity scan
# Identifies patterns that suggest self-improvement opportunities
#######################################
phase_opportunities() {
    local quiet="$1"

    [[ "$quiet" != "true" ]] && log_info "Phase 4: Scanning for improvement opportunities..."

    if [[ ! -f "$MEMORY_DB" ]]; then
        echo "0"
        return 0
    fi

    local opportunities=0
    local opportunity_details=""

    # 4a. Check for repeated failure patterns (same type of error recurring)
    local repeated_failures
    repeated_failures=$(db "$MEMORY_DB" <<'EOF'
SELECT type, COUNT(*) as cnt
FROM learnings
WHERE type IN ('FAILED_APPROACH', 'FAILURE_PATTERN', 'ERROR_FIX')
AND created_at >= datetime('now', '-30 days')
GROUP BY type
HAVING cnt >= 3
ORDER BY cnt DESC;
EOF
    )

    if [[ -n "$repeated_failures" ]]; then
        while IFS='|' read -r ftype fcount; do
            [[ -z "$ftype" ]] && continue
            opportunities=$((opportunities + 1))
            opportunity_details+="  - Recurring ${ftype}: ${fcount} in last 30 days (investigate root cause)\n"
        done <<< "$repeated_failures"
    fi

    # 4b. Check for low-confidence memories that are frequently accessed
    # (suggests they should be validated and upgraded)
    local low_conf_popular
    low_conf_popular=$(db "$MEMORY_DB" <<'EOF'
SELECT l.id, substr(l.content, 1, 80), COALESCE(a.access_count, 0) as ac
FROM learnings l
LEFT JOIN learning_access a ON l.id = a.id
WHERE l.confidence = 'low'
AND COALESCE(a.access_count, 0) >= 3
LIMIT 5;
EOF
    )

    if [[ -n "$low_conf_popular" ]]; then
        while IFS='|' read -r lid lcontent lac; do
            [[ -z "$lid" ]] && continue
            opportunities=$((opportunities + 1))
            opportunity_details+="  - Popular but low-confidence ($lid, ${lac}x): upgrade confidence? ${lcontent}...\n"
        done <<< "$low_conf_popular"
    fi

    # 4c. Check for memories with no tags (harder to find later)
    local untagged_count
    untagged_count=$(db "$MEMORY_DB" \
        "SELECT COUNT(*) FROM learnings WHERE tags = '' OR tags IS NULL;" \
        2>/dev/null || echo "0")

    if [[ "$untagged_count" -gt 10 ]]; then
        opportunities=$((opportunities + 1))
        opportunity_details+="  - ${untagged_count} memories have no tags (reduces discoverability)\n"
    fi

    # 4d. Check for superseded memories that were never cleaned up
    local orphan_superseded
    orphan_superseded=$(db "$MEMORY_DB" <<'EOF'
SELECT COUNT(*) FROM learning_relations lr
WHERE lr.relation_type = 'updates'
AND lr.supersedes_id IN (SELECT id FROM learnings);
EOF
    )
    orphan_superseded="${orphan_superseded:-0}"

    if [[ "$orphan_superseded" -gt 5 ]]; then
        opportunities=$((opportunities + 1))
        opportunity_details+="  - ${orphan_superseded} superseded memories still in DB (consider archiving)\n"
    fi

    # 4e. Check memory growth rate (warn if growing too fast)
    local recent_7d
    recent_7d=$(db "$MEMORY_DB" \
        "SELECT COUNT(*) FROM learnings WHERE created_at >= datetime('now', '-7 days');" \
        2>/dev/null || echo "0")

    if [[ "$recent_7d" -gt 50 ]]; then
        opportunities=$((opportunities + 1))
        opportunity_details+="  - High memory growth: ${recent_7d} in 7 days (check for noisy auto-capture)\n"
    fi

    # 4f. Check for batch retrospective noise (session metadata stored as memories)
    local noise_count
    noise_count=$(db "$MEMORY_DB" <<'EOF'
SELECT COUNT(*) FROM learnings
WHERE content LIKE 'Batch retrospective:%'
   OR content LIKE 'Session review for batch%'
   OR content LIKE 'Implemented feature: t%'
   OR content LIKE 'Supervisor task t%';
EOF
    )
    noise_count="${noise_count:-0}"

    if [[ "$noise_count" -gt 5 ]]; then
        opportunities=$((opportunities + 1))
        opportunity_details+="  - ${noise_count} session-metadata memories (low value, consider filtering in auto-capture)\n"
    fi

    [[ "$quiet" != "true" ]] && {
        if [[ "$opportunities" -gt 0 ]]; then
            log_warn "Found $opportunities improvement opportunities:"
            echo -e "$opportunity_details" >&2
        else
            log_success "No improvement opportunities found"
        fi
    }

    echo "$opportunities"
    return 0
}

#######################################
# Phase 5: Report
#######################################
phase_report() {
    local dedup_count="$1"
    local prune_count="$2"
    local graduate_count="$3"
    local opportunity_count="$4"
    local dry_run="$5"
    local quiet="$6"

    # Get current stats
    local total_memories=0
    if [[ -f "$MEMORY_DB" ]]; then
        total_memories=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "0")
    fi

    local db_size="0K"
    if [[ -f "$MEMORY_DB" ]]; then
        db_size=$(du -h "$MEMORY_DB" | cut -f1)
    fi

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Build report
    local report=""
    report+="Memory Audit Pulse Report\n"
    report+="========================\n"
    report+="Timestamp: $timestamp\n"
    local mode_label="LIVE"
    [[ "$dry_run" == "true" ]] && mode_label="DRY RUN"
    report+="Mode: $mode_label\n"
    report+="\n"
    report+="Actions:\n"
    report+="  Duplicates removed: $dedup_count\n"
    report+="  Stale entries pruned: $prune_count\n"
    report+="  Memories graduated: $graduate_count\n"
    report+="  Opportunities found: $opportunity_count\n"
    report+="\n"
    report+="Database:\n"
    report+="  Total memories: $total_memories\n"
    report+="  Database size: $db_size\n"

    [[ "$quiet" != "true" ]] && {
        echo ""
        echo -e "$report"
    }

    # Save report to audit log
    mkdir -p "$AUDIT_LOG_DIR"
    local report_file
    report_file="$AUDIT_LOG_DIR/audit-$(date -u +%Y%m%d-%H%M%S).txt"
    echo -e "$report" > "$report_file"

    # Append to JSONL history
    local history_file="$AUDIT_LOG_DIR/history.jsonl"
    echo "{\"timestamp\":\"$timestamp\",\"dedup\":$dedup_count,\"pruned\":$prune_count,\"graduated\":$graduate_count,\"opportunities\":$opportunity_count,\"total\":$total_memories,\"dry_run\":${dry_run:-false}}" >> "$history_file"

    return 0
}

#######################################
# Main: run all phases
#######################################
cmd_run() {
    local dry_run="false"
    local quiet="false"
    local force="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run="true"; shift ;;
            --quiet|-q) quiet="true"; shift ;;
            --force|-f) force="true"; shift ;;
            *) shift ;;
        esac
    done

    # Check interval (skip if --force)
    if [[ "$force" != "true" ]] && ! should_run; then
        return 0
    fi

    [[ "$quiet" != "true" ]] && log_info "Starting memory audit pulse..."

    if [[ ! -f "$MEMORY_DB" ]]; then
        [[ "$quiet" != "true" ]] && log_warn "No memory database found at $MEMORY_DB"
        return 0
    fi

    # Run all phases
    local dedup_count prune_count graduate_count opportunity_count

    dedup_count=$(phase_dedup "$dry_run" "$quiet")
    prune_count=$(phase_prune "$dry_run" "$quiet")
    graduate_count=$(phase_graduate "$dry_run" "$quiet")
    opportunity_count=$(phase_opportunities "$quiet")

    # Generate report
    phase_report "$dedup_count" "$prune_count" "$graduate_count" "$opportunity_count" "$dry_run" "$quiet"

    # Update marker (only on live runs)
    if [[ "$dry_run" != "true" ]]; then
        touch "$AUDIT_MARKER"
    fi

    [[ "$quiet" != "true" ]] && log_success "Audit pulse complete."

    return 0
}

#######################################
# Show audit status and history
#######################################
cmd_status() {
    echo ""
    echo "=== Memory Audit Pulse Status ==="
    echo ""

    # Last audit
    if [[ -f "$AUDIT_MARKER" ]]; then
        local last_run
        last_run=$(stat -f %m "$AUDIT_MARKER" 2>/dev/null || stat -c %Y "$AUDIT_MARKER" 2>/dev/null || echo "0")
        local now
        now=$(date +%s)
        local elapsed=$(( (now - last_run) / 3600 ))
        log_info "Last audit: ${elapsed}h ago"
    else
        log_info "Last audit: never"
    fi

    # Audit interval
    log_info "Audit interval: ${AUDIT_INTERVAL_HOURS}h"

    # History
    local history_file="$AUDIT_LOG_DIR/history.jsonl"
    if [[ -f "$history_file" ]]; then
        local history_count
        history_count=$(wc -l < "$history_file" | tr -d ' ')
        log_info "Total audits: $history_count"

        echo ""
        echo "Recent audits:"
        tail -5 "$history_file" | while IFS= read -r line; do
            local ts dedup pruned graduated opps
            ts=$(echo "$line" | jq -r '.timestamp' 2>/dev/null || echo "?")
            dedup=$(echo "$line" | jq -r '.dedup' 2>/dev/null || echo "0")
            pruned=$(echo "$line" | jq -r '.pruned' 2>/dev/null || echo "0")
            graduated=$(echo "$line" | jq -r '.graduated' 2>/dev/null || echo "0")
            opps=$(echo "$line" | jq -r '.opportunities' 2>/dev/null || echo "0")
            echo "  $ts | dedup:$dedup prune:$pruned grad:$graduated opps:$opps"
        done
    else
        log_info "No audit history yet"
    fi

    # Memory DB stats
    echo ""
    if [[ -f "$MEMORY_DB" ]]; then
        local total
        total=$(db "$MEMORY_DB" "SELECT COUNT(*) FROM learnings;" 2>/dev/null || echo "0")
        local db_size
        db_size=$(du -h "$MEMORY_DB" | cut -f1)
        log_info "Memory DB: $total memories, $db_size"
    else
        log_info "Memory DB: not found"
    fi

    echo ""
    return 0
}

#######################################
# Show help
#######################################
cmd_help() {
    cat << 'EOF'
memory-audit-pulse.sh - Periodic memory self-improvement scan

Automated memory hygiene that deduplicates, prunes, graduates, and
identifies improvement opportunities in the memory database.

USAGE:
    memory-audit-pulse.sh <command> [options]

COMMANDS:
    run         Run the full audit pulse (all phases)
    status      Show audit status and history
    help        Show this help

RUN OPTIONS:
    --dry-run   Preview actions without making changes
    --quiet     Suppress output (for cron/supervisor use)
    --force     Run even if interval hasn't elapsed

PHASES:
    1. Dedup     Remove exact and near-duplicate memories
    2. Prune     Remove stale entries (>90 days, never accessed)
    3. Graduate  Promote high-value memories to shared docs
    4. Scan      Identify self-improvement opportunities:
                 - Recurring failure patterns
                 - Popular but low-confidence memories
                 - Untagged memories (poor discoverability)
                 - Session metadata noise
                 - High memory growth rate
    5. Report    Summary of actions + JSONL history

INTEGRATION:
    # Supervisor pulse (automatic)
    Called during supervisor memory audit phase

    # Cron (daily at 4 AM)
    0 4 * * * ~/.aidevops/agents/scripts/memory-audit-pulse.sh run --quiet

    # Manual
    memory-audit-pulse.sh run
    memory-audit-pulse.sh run --dry-run

EXAMPLES:
    # Preview what the audit would do
    memory-audit-pulse.sh run --dry-run

    # Run full audit (respects 24h interval)
    memory-audit-pulse.sh run

    # Force run regardless of interval
    memory-audit-pulse.sh run --force

    # Check status and history
    memory-audit-pulse.sh status
EOF
    return 0
}

#######################################
# Main
#######################################
main() {
    local command="${1:-help}"
    shift || true

    case "$command" in
        run|pulse)    cmd_run "$@" ;;
        status|stats) cmd_status ;;
        help|--help|-h) cmd_help ;;
        *)
            log_error "Unknown command: $command"
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
exit $?
