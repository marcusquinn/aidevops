#!/usr/bin/env bash
set -euo pipefail

# deploy-agents-on-merge.sh - Fast targeted agent deployment after PR merge
#
# Called by the supervisor after merging PRs that modify .agents/ files.
# Much faster than full setup.sh --non-interactive because it only syncs
# changed agent files instead of running all migrations and optional steps.
#
# Usage:
#   deploy-agents-on-merge.sh [options]
#
# Options:
#   --repo <path>       Path to the aidevops repo (default: ~/Git/aidevops)
#   --scripts-only      Only deploy .agents/scripts/ (fastest)
#   --full              Run full setup.sh --non-interactive instead
#   --dry-run           Show what would be deployed without doing it
#   --diff <commit>     Only deploy files changed since <commit>
#   --quiet             Suppress non-error output
#   --help              Show this help
#
# Exit codes:
#   0 - Deploy successful
#   1 - Deploy failed
#   2 - Nothing to deploy (no changes detected)

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

QUIET=false

log_info() {
    if [[ "$QUIET" == "false" ]]; then
        echo -e "${BLUE}[deploy]${NC} $1"
    fi
    return 0
}

log_success() {
    if [[ "$QUIET" == "false" ]]; then
        echo -e "${GREEN}[deploy]${NC} $1"
    fi
    return 0
}

log_warn() {
    echo -e "${YELLOW}[deploy]${NC} $1" >&2
    return 0
}

log_error() {
    echo -e "${RED}[deploy]${NC} $1" >&2
    return 0
}

# Defaults
REPO_DIR="${HOME}/Git/aidevops"
TARGET_DIR="${HOME}/.aidevops/agents"
SCRIPTS_ONLY=false
FULL_DEPLOY=false
DRY_RUN=false
DIFF_COMMIT=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo)
                [[ $# -lt 2 ]] && { log_error "--repo requires a path"; return 1; }
                REPO_DIR="$2"
                shift 2
                ;;
            --scripts-only)
                SCRIPTS_ONLY=true
                shift
                ;;
            --full)
                FULL_DEPLOY=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --diff)
                [[ $# -lt 2 ]] && { log_error "--diff requires a commit"; return 1; }
                DIFF_COMMIT="$2"
                shift 2
                ;;
            --quiet)
                QUIET=true
                shift
                ;;
            --help|-h)
                head -25 "$0" | tail -20
                return 0
                ;;
            *)
                log_error "Unknown option: $1"
                return 1
                ;;
        esac
    done
    return 0
}

# Validate the repo directory
validate_repo() {
    # Support both regular repos (.git dir) and worktrees (.git file)
    if [[ ! -d "$REPO_DIR/.git" && ! -f "$REPO_DIR/.git" ]]; then
        log_error "Not a git repo: $REPO_DIR"
        return 1
    fi

    if [[ ! -d "$REPO_DIR/.agents" ]]; then
        log_error "No .agents/ directory in $REPO_DIR"
        return 1
    fi

    return 0
}

# Pull latest main (fast-forward only)
pull_latest() {
    local current_branch
    current_branch=$(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo "")

    if [[ "$current_branch" != "main" ]]; then
        log_warn "Repo is on branch '$current_branch', not main — skipping pull"
        return 0
    fi

    log_info "Pulling latest main..."
    if ! git -C "$REPO_DIR" pull --ff-only origin main --quiet 2>/dev/null; then
        log_warn "Fast-forward pull failed — trying regular pull"
        git -C "$REPO_DIR" pull origin main --quiet 2>/dev/null || true
    fi

    return 0
}

# Detect which agent files changed since a commit
detect_changes() {
    local since_commit="$1"
    local changed_files

    if [[ -n "$since_commit" ]]; then
        changed_files=$(git -C "$REPO_DIR" diff --name-only "$since_commit" HEAD -- '.agents/' 2>/dev/null || echo "")
    else
        # Compare deployed VERSION with repo VERSION to detect staleness
        local repo_version deployed_version
        repo_version=$(cat "$REPO_DIR/VERSION" 2>/dev/null || echo "unknown")
        deployed_version=$(cat "$TARGET_DIR/VERSION" 2>/dev/null || echo "none")

        if [[ "$repo_version" == "$deployed_version" ]]; then
            log_info "Deployed agents ($deployed_version) match repo ($repo_version)"
            echo ""
            return 0
        fi

        log_info "Version mismatch: deployed=$deployed_version repo=$repo_version"
        # Return all agent files as changed (version mismatch = full sync needed)
        changed_files=$(git -C "$REPO_DIR" ls-files '.agents/' 2>/dev/null || echo "")
    fi

    echo "$changed_files"
    return 0
}

# Deploy scripts only (fastest path)
deploy_scripts_only() {
    local source_dir="$REPO_DIR/.agents/scripts"
    local target_scripts_dir="$TARGET_DIR/scripts"

    if [[ ! -d "$source_dir" ]]; then
        log_error "Source scripts directory not found: $source_dir"
        return 1
    fi

    mkdir -p "$target_scripts_dir"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] Would sync $source_dir/ -> $target_scripts_dir/"
        local count
        count=$(find "$source_dir" -type f | wc -l | tr -d ' ')
        log_info "[dry-run] $count files would be deployed"
        return 0
    fi

    log_info "Deploying scripts to $target_scripts_dir..."

    if command -v rsync &>/dev/null; then
        rsync -a --delete "$source_dir/" "$target_scripts_dir/"
    else
        # Fallback: tar-based copy
        (cd "$source_dir" && tar cf - .) | (cd "$target_scripts_dir" && tar xf -)
    fi

    # Set executable permissions
    chmod +x "$target_scripts_dir/"*.sh 2>/dev/null || true

    local count
    count=$(find "$target_scripts_dir" -name "*.sh" -type f | wc -l | tr -d ' ')
    log_success "Deployed $count scripts"

    return 0
}

# Deploy all agent files (selective sync, preserving custom/draft)
deploy_all_agents() {
    local source_dir="$REPO_DIR/.agents"

    if [[ ! -d "$source_dir" ]]; then
        log_error "Source agents directory not found: $source_dir"
        return 1
    fi

    mkdir -p "$TARGET_DIR"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] Would sync $source_dir/ -> $TARGET_DIR/"
        log_info "[dry-run] Preserving: custom/, draft/"
        return 0
    fi

    log_info "Deploying all agents to $TARGET_DIR..."

    if command -v rsync &>/dev/null; then
        rsync -a \
            --exclude='loop-state/' \
            --exclude='custom/' \
            --exclude='draft/' \
            "$source_dir/" "$TARGET_DIR/"
    else
        # Preserve custom and draft directories
        local tmp_preserve
        tmp_preserve=$(mktemp -d)
        local preserve_ok=true

        for pdir in custom draft; do
            if [[ -d "$TARGET_DIR/$pdir" ]]; then
                if ! cp -R "$TARGET_DIR/$pdir" "$tmp_preserve/$pdir"; then
                    preserve_ok=false
                fi
            fi
        done

        if [[ "$preserve_ok" == "false" ]]; then
            log_error "Failed to preserve custom/draft directories"
            rm -rf "$tmp_preserve"
            return 1
        fi

        # Copy all agents
        (cd "$source_dir" && tar cf - --exclude='loop-state' --exclude='custom' --exclude='draft' .) | \
            (cd "$TARGET_DIR" && tar xf -)

        # Restore preserved directories
        for pdir in custom draft; do
            if [[ -d "$tmp_preserve/$pdir" ]]; then
                cp -R "$tmp_preserve/$pdir" "$TARGET_DIR/$pdir"
            fi
        done
        rm -rf "$tmp_preserve"
    fi

    # Set executable permissions on scripts
    chmod +x "$TARGET_DIR/scripts/"*.sh 2>/dev/null || true

    # Copy VERSION file
    if [[ -f "$REPO_DIR/VERSION" ]]; then
        cp "$REPO_DIR/VERSION" "$TARGET_DIR/VERSION"
    fi

    local agent_count script_count
    agent_count=$(find "$TARGET_DIR" -name "*.md" -type f | wc -l | tr -d ' ')
    script_count=$(find "$TARGET_DIR/scripts" -name "*.sh" -type f 2>/dev/null | wc -l | tr -d ' ')
    log_success "Deployed $agent_count agent files and $script_count scripts"

    return 0
}

# Deploy only specific changed files (most targeted)
deploy_changed_files() {
    local changed_files="$1"

    if [[ -z "$changed_files" ]]; then
        log_info "No changed files to deploy"
        return 2
    fi

    local count
    count=$(echo "$changed_files" | wc -l | tr -d ' ')

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] Would deploy $count changed files:"
        echo "$changed_files" | head -20
        if [[ "$count" -gt 20 ]]; then
            log_info "[dry-run] ... and $((count - 20)) more"
        fi
        return 0
    fi

    log_info "Deploying $count changed files..."

    local deployed=0
    local failed=0

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        # Strip .agents/ prefix to get relative path within target
        local rel_path="${file#.agents/}"
        local source_file="$REPO_DIR/$file"
        local target_file="$TARGET_DIR/$rel_path"

        # Skip custom/draft/loop-state
        case "$rel_path" in
            custom/*|draft/*|loop-state/*) continue ;;
        esac

        if [[ -f "$source_file" ]]; then
            # Create target directory if needed
            local target_parent
            target_parent=$(dirname "$target_file")
            mkdir -p "$target_parent"

            # Copy file
            cp "$source_file" "$target_file"

            # Set executable if it's a script
            if [[ "$target_file" == *.sh ]]; then
                chmod +x "$target_file"
            fi

            deployed=$((deployed + 1))
        elif [[ ! -e "$source_file" ]]; then
            # File was deleted in source — remove from target
            if [[ -f "$target_file" ]]; then
                rm -f "$target_file"
                log_info "Removed deleted file: $rel_path"
            fi
        fi
    done <<< "$changed_files"

    if [[ "$failed" -gt 0 ]]; then
        log_warn "Deployed $deployed files, $failed failed"
        return 1
    fi

    # Update VERSION
    if [[ -f "$REPO_DIR/VERSION" ]]; then
        cp "$REPO_DIR/VERSION" "$TARGET_DIR/VERSION"
    fi

    log_success "Deployed $deployed changed files"
    return 0
}

main() {
    parse_args "$@" || return 1
    validate_repo || return 1

    # Full deploy: delegate to setup.sh
    if [[ "$FULL_DEPLOY" == "true" ]]; then
        log_info "Running full deploy via setup.sh --non-interactive..."
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "[dry-run] Would run: AIDEVOPS_NON_INTERACTIVE=true $REPO_DIR/setup.sh --non-interactive"
            return 0
        fi
        AIDEVOPS_NON_INTERACTIVE=true bash "$REPO_DIR/setup.sh" --non-interactive
        return $?
    fi

    # Pull latest (only if on main)
    pull_latest

    # Scripts-only deploy
    if [[ "$SCRIPTS_ONLY" == "true" ]]; then
        deploy_scripts_only
        return $?
    fi

    # Diff-based deploy
    if [[ -n "$DIFF_COMMIT" ]]; then
        local changed
        changed=$(detect_changes "$DIFF_COMMIT")
        if [[ -z "$changed" ]]; then
            log_info "No agent changes since $DIFF_COMMIT"
            return 2
        fi

        # If many files changed, do a full agent sync instead of file-by-file
        local change_count
        change_count=$(echo "$changed" | wc -l | tr -d ' ')
        if [[ "$change_count" -gt 50 ]]; then
            log_info "Large changeset ($change_count files) — doing full agent sync"
            deploy_all_agents
            return $?
        fi

        # Check if only scripts changed
        local non_script_changes
        non_script_changes=$(echo "$changed" | grep -cv '^\.agents/scripts/' || echo "0")
        if [[ "$non_script_changes" -eq 0 ]]; then
            log_info "Only scripts changed — using fast scripts-only deploy"
            deploy_scripts_only
            return $?
        fi

        deploy_changed_files "$changed"
        return $?
    fi

    # Default: version-based detection
    local changed
    changed=$(detect_changes "")
    if [[ -z "$changed" ]]; then
        return 2
    fi

    # Version mismatch detected — full agent sync
    deploy_all_agents
    return $?
}

main "$@"
