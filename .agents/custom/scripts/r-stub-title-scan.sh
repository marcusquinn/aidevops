#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# r-stub-title-scan.sh — Proactive detection: scan pulse-enabled repos for stub-title issues
#
# A stub title (e.g. "tNNN: $", "GH#NNN: $", ": $") is almost always the
# signature of the t2377 data-loss bug class or a similar framework misbehaviour.
# This scanner runs hourly and catches the incident BEFORE a human has to notice.
#
# Usage:
#   r-stub-title-scan.sh              Normal scan (files incident issues)
#   r-stub-title-scan.sh --dry-run    Scan and log only, no issue creation
#
# Environment:
#   STUB_SCAN_REPOS          Comma-separated slug allowlist (overrides repos.json)
#   STUB_SCAN_INCIDENT_REPO  Where to file incident issues (default: marcusquinn/aidevops)
#   STUB_SCAN_DRY_RUN=1      Equivalent to --dry-run flag
#
# State:
#   ~/.aidevops/logs/stub-title-incidents.log  — detection log (rotated at 1MB, 5 kept)
#   ~/.aidevops/cache/stub-title-seen.json     — 24h dedup cache
#
# Reference pattern: contribution-watch-helper.sh (cross-repo scan + file-issue-on-finding)
# Related: GH#19847 (t2377) — the data-loss bug this scanner detects instances of

set -euo pipefail

# PATH normalisation for launchd/MCP environments
export PATH="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# Resolve framework scripts directory (deployed or source)
FRAMEWORK_SCRIPTS="${HOME}/.aidevops/agents/scripts"
if [[ -f "${FRAMEWORK_SCRIPTS}/shared-constants.sh" ]]; then
    # shellcheck source=../../scripts/shared-constants.sh
    source "${FRAMEWORK_SCRIPTS}/shared-constants.sh" 2>/dev/null || true
fi

# Fallback colours if shared-constants.sh not loaded
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# =============================================================================
# Configuration
# =============================================================================

REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
LOGFILE="${HOME}/.aidevops/logs/stub-title-incidents.log"
SEEN_CACHE="${HOME}/.aidevops/cache/stub-title-seen.json"
INCIDENT_REPO="${STUB_SCAN_INCIDENT_REPO:-marcusquinn/aidevops}"
DRY_RUN="${STUB_SCAN_DRY_RUN:-0}"
MAX_LOG_SIZE=1048576  # 1MB
LOG_RETENTION=5

# Parse flags
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --help|-h)
            echo "Usage: r-stub-title-scan.sh [--dry-run]"
            echo "  Scan pulse-enabled repos for stub-title issues."
            echo "  --dry-run  Log findings only, do not file incident issues."
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

# =============================================================================
# Helpers
# =============================================================================

_log() {
    local level="$1"
    shift
    local msg="$*"
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "[${ts}] [${level}] ${msg}" >> "$LOGFILE"
    if [[ "$level" == "ERROR" ]]; then
        echo -e "${RED}[${level}]${NC} ${msg}" >&2
    elif [[ "$level" == "WARN" ]]; then
        echo -e "${YELLOW}[${level}]${NC} ${msg}" >&2
    else
        echo -e "${GREEN}[${level}]${NC} ${msg}"
    fi
    return 0
}

_ensure_dirs() {
    mkdir -p "$(dirname "$LOGFILE")" "$(dirname "$SEEN_CACHE")"
    return 0
}

# Rotate log file when it exceeds MAX_LOG_SIZE.
# Keeps LOG_RETENTION rotated copies (.1 through .N).
_rotate_log() {
    if [[ ! -f "$LOGFILE" ]]; then
        return 0
    fi
    local size
    size=$(wc -c < "$LOGFILE" 2>/dev/null || echo 0)
    size="${size// /}"  # trim whitespace (macOS wc quirk)
    if (( size < MAX_LOG_SIZE )); then
        return 0
    fi
    # Rotate: .5 -> delete, .4 -> .5, ... .1 -> .2, current -> .1
    local i
    for (( i = LOG_RETENTION; i >= 2; i-- )); do
        local prev=$(( i - 1 ))
        if [[ -f "${LOGFILE}.${prev}" ]]; then
            mv "${LOGFILE}.${prev}" "${LOGFILE}.${i}"
        fi
    done
    mv "$LOGFILE" "${LOGFILE}.1"
    _log "INFO" "Log rotated (exceeded ${MAX_LOG_SIZE} bytes)"
    return 0
}

# Load the 24h dedup cache. Prune entries older than 24h.
_load_seen_cache() {
    if [[ ! -f "$SEEN_CACHE" ]]; then
        echo '{}' > "$SEEN_CACHE"
    fi
    # Prune entries older than 24h (86400 seconds)
    local now
    now=$(date +%s)
    local cutoff=$(( now - 86400 ))
    local pruned
    pruned=$(jq --argjson cutoff "$cutoff" \
        'to_entries | map(select(.value >= $cutoff)) | from_entries' \
        "$SEEN_CACHE" 2>/dev/null) || pruned='{}'
    echo "$pruned" > "$SEEN_CACHE"
    return 0
}

# Check if an issue+slug combo was already seen within 24h.
# Args: $1 = cache key (slug#number)
_is_seen() {
    local key="$1"
    local val
    val=$(jq -r --arg k "$key" '.[$k] // 0' "$SEEN_CACHE" 2>/dev/null) || val=0
    if (( val > 0 )); then
        return 0  # seen
    fi
    return 1  # not seen
}

# Mark an issue+slug combo as seen now.
# Args: $1 = cache key (slug#number)
_mark_seen() {
    local key="$1"
    local now
    now=$(date +%s)
    local updated
    updated=$(jq --arg k "$key" --argjson v "$now" '.[$k] = $v' "$SEEN_CACHE" 2>/dev/null) || {
        _log "WARN" "Failed to update seen cache for ${key}"
        return 1
    }
    echo "$updated" > "$SEEN_CACHE"
    return 0
}

# Get list of pulse-enabled repo slugs (excluding local_only).
_get_pulse_repos() {
    if [[ -n "${STUB_SCAN_REPOS:-}" ]]; then
        # Use explicit allowlist
        echo "$STUB_SCAN_REPOS" | tr ',' '\n'
        return 0
    fi
    if [[ ! -f "$REPOS_JSON" ]]; then
        _log "ERROR" "repos.json not found at ${REPOS_JSON}"
        return 1
    fi
    jq -r '.initialized_repos[] | select(.pulse == true) | select(.local_only != true) | .slug' \
        "$REPOS_JSON" 2>/dev/null
    return 0
}

# Check if a title is a stub title.
# Stub patterns: "tNNN: " (just prefix + colon + optional whitespace)
#                "GH#NNN: " (just prefix + colon + optional whitespace)
#                ": " (just colon + optional whitespace — fully empty description)
# Args: $1 = title string
_is_stub_title() {
    local title="$1"
    # Match: optional task-ID prefix, then colon, then only whitespace to end
    if [[ "$title" =~ ^(t[0-9]+|GH#[0-9]+)?:[[:space:]]*$ ]]; then
        return 0  # stub
    fi
    return 1
}

# File an incident issue on the incident repo.
# Args: $1 = affected slug, $2 = affected issue number, $3 = stub title
_file_incident_issue() {
    local affected_slug="$1"
    local affected_number="$2"
    local stub_title="$3"
    local incident_title="Incident: #${affected_number} has stub title in ${affected_slug}"
    local incident_body
    incident_body="$(cat <<BODY
## Stub Title Detected

**Affected issue:** ${affected_slug}#${affected_number}
**Detected title:** \`${stub_title}\`
**Detection time:** $(date -u '+%Y-%m-%dT%H:%M:%SZ')
**Scanner:** \`r-stub-title-scan.sh\`

A stub title (\`tNNN:\`, \`GH#NNN:\`, or \`:\` followed by only whitespace) typically
indicates the t2377 data-loss bug class or similar framework misbehaviour where the
\`enrich-path\` overwrites the issue title/body with empty data.

### Recommended actions

1. Check the issue body — if also wiped, the enrich path likely fired with stale/empty data.
2. Restore the original title from \`git log\` of \`TODO.md\` or the task brief at \`todo/tasks/\`.
3. If this is a recurring pattern, investigate the dispatch that triggered the overwrite.

### Related

- GH#19847 (t2377) — root-cause data-loss bug
- \`.agents/reference/detection-routines.md\` — scanner documentation

<!-- aidevops:generator=r-stub-title-scan -->
BODY
)"

    if [[ "$DRY_RUN" == "1" ]]; then
        _log "DRY-RUN" "Would file incident: ${incident_title}"
        return 0
    fi

    # Check for existing open incident issue to avoid duplicates
    local existing
    existing=$(gh issue list --repo "$INCIDENT_REPO" --state open \
        --search "Incident: #${affected_number} has stub title in ${affected_slug}" \
        --json number --jq '.[0].number // empty' 2>/dev/null) || existing=""

    if [[ -n "$existing" ]]; then
        # Update existing incident with a new timestamp comment
        local comment_body
        comment_body="Still observed at $(date -u '+%Y-%m-%dT%H:%M:%SZ'). Title: \`${stub_title}\`"
        gh issue comment "$existing" --repo "$INCIDENT_REPO" --body "$comment_body" >/dev/null 2>&1 || {
            _log "WARN" "Failed to comment on existing incident #${existing}"
            return 1
        }
        _log "INFO" "Updated existing incident #${existing} for ${affected_slug}#${affected_number}"
        return 0
    fi

    # File new incident issue via the gh_create_issue wrapper if available
    local issue_url
    if type -t gh_create_issue &>/dev/null; then
        issue_url=$(gh_create_issue --repo "$INCIDENT_REPO" \
            --title "$incident_title" \
            --body "$incident_body" \
            --label "automation" --label "monitoring" --label "incident" 2>&1) || {
            _log "ERROR" "gh_create_issue failed for ${affected_slug}#${affected_number}: ${issue_url}"
            return 1
        }
    else
        issue_url=$(gh issue create --repo "$INCIDENT_REPO" \
            --title "$incident_title" \
            --body "$incident_body" \
            --label "automation" --label "monitoring" --label "incident" 2>&1) || {
            _log "ERROR" "gh issue create failed for ${affected_slug}#${affected_number}: ${issue_url}"
            return 1
        }
    fi
    _log "INFO" "Filed incident issue: ${issue_url} for ${affected_slug}#${affected_number}"
    return 0
}

# =============================================================================
# Main scan
# =============================================================================

main() {
    _ensure_dirs
    _rotate_log
    _load_seen_cache

    _log "INFO" "Stub-title scan started (dry_run=${DRY_RUN})"

    local repos
    repos=$(_get_pulse_repos) || {
        _log "ERROR" "Failed to enumerate pulse repos"
        return 1
    }

    local total_found=0
    local total_repos=0
    local failed_repos=0

    while IFS= read -r slug; do
        [[ -z "$slug" ]] && continue
        total_repos=$(( total_repos + 1 ))

        _log "INFO" "Scanning ${slug}..."

        # Fetch open issues (limit 500 per the design spec)
        local issues_json
        issues_json=$(gh issue list --repo "$slug" --state open --limit 500 \
            --json number,title 2>/dev/null) || {
            _log "WARN" "Failed to fetch issues for ${slug} (network/auth error)"
            failed_repos=$(( failed_repos + 1 ))
            continue
        }

        # Filter for stub titles using jq
        local stubs
        stubs=$(echo "$issues_json" | jq -r '.[] | select(
            .title | test("^(t[0-9]+|GH#[0-9]+)?:\\s*$")
        ) | "\(.number)\t\(.title)"' 2>/dev/null) || {
            _log "WARN" "jq filter failed for ${slug}"
            failed_repos=$(( failed_repos + 1 ))
            continue
        }

        if [[ -z "$stubs" ]]; then
            _log "INFO" "No stub titles found in ${slug}"
            continue
        fi

        while IFS=$'\t' read -r issue_num issue_title; do
            [[ -z "$issue_num" ]] && continue
            total_found=$(( total_found + 1 ))

            local cache_key="${slug}#${issue_num}"

            _log "FOUND" "Stub title in ${slug}#${issue_num}: '${issue_title}'"

            if _is_seen "$cache_key"; then
                _log "INFO" "Already reported ${cache_key} within 24h — updating existing incident"
            fi

            _file_incident_issue "$slug" "$issue_num" "$issue_title"
            _mark_seen "$cache_key"
        done <<< "$stubs"
    done <<< "$repos"

    _log "INFO" "Scan complete: ${total_repos} repos scanned, ${total_found} stub titles found, ${failed_repos} repos failed"

    if (( total_found > 0 )); then
        _log "WARN" "Found ${total_found} stub-title issue(s) — check incident issues on ${INCIDENT_REPO}"
    fi

    return 0
}

main "$@"
