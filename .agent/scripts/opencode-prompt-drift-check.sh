#!/bin/bash
# =============================================================================
# OpenCode Prompt Drift Detection
# =============================================================================
# Checks if upstream OpenCode prompts have changed since our build.txt was
# last synced. Compares the commit hash in build.txt header against the latest
# commit on the upstream file.
#
# Usage: ./opencode-prompt-drift-check.sh [--quiet]
# Exit codes: 0 = no drift, 1 = drift detected, 2 = check failed
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
PROMPTS_DIR="$(cd "$SCRIPT_DIR/../prompts" && pwd)" || exit
BUILD_TXT="$PROMPTS_DIR/build.txt"

UPSTREAM_REPO="anomalyco/opencode"
UPSTREAM_BRANCH="dev"
UPSTREAM_FILE="packages/opencode/src/session/prompt/anthropic.txt"

QUIET="${1:-}"

# Extract our tracked commit hash from build.txt header
get_local_hash() {
    local hash
    hash=$(head -1 "$BUILD_TXT" | grep -oE '[0-9a-f]{12}' || echo "")
    echo "$hash"
}

# Get latest commit hash for the upstream file
get_upstream_hash() {
    local response
    response=$(curl -sf --max-time 10 \
        "https://api.github.com/repos/${UPSTREAM_REPO}/commits?path=${UPSTREAM_FILE}&sha=${UPSTREAM_BRANCH}&per_page=1" \
        -H "Accept: application/vnd.github.v3+json" 2>/dev/null) || return 1

    local hash
    hash=$(echo "$response" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['sha'][:12])" 2>/dev/null) || return 1
    echo "$hash"
}

main() {
    if [[ ! -f "$BUILD_TXT" ]]; then
        [[ "$QUIET" != "--quiet" ]] && echo "ERROR: build.txt not found at $BUILD_TXT"
        return 2
    fi

    local local_hash
    local_hash=$(get_local_hash)
    if [[ -z "$local_hash" ]]; then
        [[ "$QUIET" != "--quiet" ]] && echo "WARNING: No upstream hash found in build.txt header"
        return 2
    fi

    local upstream_hash
    upstream_hash=$(get_upstream_hash) || {
        [[ "$QUIET" != "--quiet" ]] && echo "WARNING: Could not fetch upstream commit (network issue?)"
        return 2
    }

    if [[ "$local_hash" == "$upstream_hash" ]]; then
        [[ "$QUIET" != "--quiet" ]] && echo "OK: build.txt is in sync with upstream ($local_hash)"
        return 0
    else
        if [[ "$QUIET" == "--quiet" ]]; then
            echo "PROMPT_DRIFT|${local_hash}|${upstream_hash}"
        else
            echo "DRIFT DETECTED: upstream prompt has changed"
            echo "  Local:    $local_hash"
            echo "  Upstream: $upstream_hash"
            echo ""
            echo "  View diff: https://github.com/${UPSTREAM_REPO}/compare/${local_hash}...${upstream_hash}"
            echo "  To update: review changes and update .agent/prompts/build.txt"
        fi
        return 1
    fi
}

main "$@"
