#!/usr/bin/env bash

# AI DevOps Framework - Template Deployment Script
# Securely deploys minimal AGENTS.md templates to user's home directory

set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Backup configuration
readonly BACKUP_KEEP_COUNT=5
readonly BACKUP_BASE_DIR="$HOME/.aidevops/template-backups"

# Print functions
print_info() { local msg="$1"; echo -e "${BLUE}[INFO]${NC} $msg"; return 0; }
print_success() { local msg="$1"; echo -e "${GREEN}[SUCCESS]${NC} $msg"; return 0; }
print_warning() { local msg="$1"; echo -e "${YELLOW}[WARNING]${NC} $msg"; return 0; }
print_error() { local msg="$1"; echo -e "${RED}[ERROR]${NC} $msg" >&2; return 0; }

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Validate we're in the correct repository
if [[ ! -f "$REPO_ROOT/AGENTS.md" ]] || [[ ! -d "$REPO_ROOT/.agents" ]]; then
    print_error "This script must be run from within the aidevops repository"
    exit 1
fi

# Create a backup with rotation (keeps last N backups in centralized location)
# Usage: create_backup_with_rotation <source_path> <backup_name>
create_backup_with_rotation() {
    local source_path="$1"
    local backup_name="$2"
    local backup_dir
    # Use nanoseconds to avoid collisions on rapid successive invocations
    backup_dir="$BACKUP_BASE_DIR/$backup_name/$(date +%Y%m%d_%H%M%S%N)"

    # Validate source exists before attempting backup
    if [[ -d "$source_path" ]]; then
        mkdir -p "$backup_dir"
        cp -R "$source_path" "$backup_dir/"
    elif [[ -f "$source_path" ]]; then
        mkdir -p "$backup_dir"
        cp "$source_path" "$backup_dir/"
    else
        print_warning "Source path does not exist: $source_path"
        return 1
    fi

    print_info "Backed up to $backup_dir"

    # Rotate old backups (keep last N)
    local backup_type_dir="$BACKUP_BASE_DIR/$backup_name"
    local backup_count
    backup_count=$(find "$backup_type_dir" -maxdepth 1 -type d -name "20*" 2>/dev/null | wc -l)

    if (( backup_count > BACKUP_KEEP_COUNT )); then
        local to_delete=$((backup_count - BACKUP_KEEP_COUNT))
        # Delete oldest backups (sorted by name = sorted by date)
        find "$backup_type_dir" -maxdepth 1 -type d -name "20*" 2>/dev/null | sort | head -n "$to_delete" | while read -r old_backup; do rm -rf "$old_backup"; done
        print_info "Rotated backups: removed $to_delete old backup(s)"
    fi

    return 0
}

# Clean up old in-place backup files from previous versions
# Uses find -delete to safely remove only files (not directories)
cleanup_old_backups() {
    local cleaned=0
    local count
    
    # Clean ~/AGENTS.md.backup.* files
    count=$(find "$HOME" -maxdepth 1 -name "AGENTS.md.backup.*" -type f 2>/dev/null | wc -l)
    if (( count > 0 )); then
        find "$HOME" -maxdepth 1 -name "AGENTS.md.backup.*" -type f -delete 2>/dev/null
        (( cleaned += count ))
    fi
    
    # Clean ~/git/AGENTS.md.backup.* or ~/Git/AGENTS.md.backup.* files
    for git_dir in "$HOME/git" "$HOME/Git"; do
        if [[ -d "$git_dir" ]]; then
            count=$(find "$git_dir" -maxdepth 1 -name "AGENTS.md.backup.*" -type f 2>/dev/null | wc -l)
            if (( count > 0 )); then
                find "$git_dir" -maxdepth 1 -name "AGENTS.md.backup.*" -type f -delete 2>/dev/null
                (( cleaned += count ))
            fi
        fi
    done
    
    # Clean ~/.aidevops/.agent-workspace/README.md.backup.* files
    local workspace="$HOME/.aidevops/.agent-workspace"
    if [[ -d "$workspace" ]]; then
        count=$(find "$workspace" -maxdepth 1 -name "README.md.backup.*" -type f 2>/dev/null | wc -l)
        if (( count > 0 )); then
            find "$workspace" -maxdepth 1 -name "README.md.backup.*" -type f -delete 2>/dev/null
            (( cleaned += count ))
        fi
    fi
    
    if (( cleaned > 0 )); then
        print_success "Cleaned up $cleaned old backup file(s)"
    fi
    
    return 0
}

deploy_home_agents() {
    local target_file="$HOME/AGENTS.md"
    
    print_info "Deploying minimal AGENTS.md to home directory..."
    
    # Backup existing file if it exists (with rotation)
    if [[ -f "$target_file" ]]; then
        create_backup_with_rotation "$target_file" "home-agents"
    fi
    
    # Deploy template
    cp "$SCRIPT_DIR/home/AGENTS.md" "$target_file"
    print_success "Deployed: $target_file"
    return 0
}

deploy_git_agents() {
    local git_dir="$HOME/git"
    local target_file="$git_dir/AGENTS.md"
    
    print_info "Deploying minimal AGENTS.md to git directory..."
    
    # Create git directory if it doesn't exist
    if [[ ! -d "$git_dir" ]]; then
        mkdir -p "$git_dir"
        print_info "Created git directory: $git_dir"
    fi
    
    # Backup existing file if it exists (with rotation)
    if [[ -f "$target_file" ]]; then
        create_backup_with_rotation "$target_file" "git-agents"
    fi
    
    # Deploy template
    cp "$SCRIPT_DIR/home/git/AGENTS.md" "$target_file"
    print_success "Deployed: $target_file"
    return 0
}

deploy_agent_directory() {
    local agent_workspace="$HOME/.aidevops/.agent-workspace"
    local target_file="$agent_workspace/README.md"
    
    print_info "Deploying .agent-workspace directory structure..."
    
    # Create workspace directories if they don't exist
    if [[ ! -d "$agent_workspace" ]]; then
        mkdir -p "$agent_workspace"/{work,tmp,memory}
        print_info "Created workspace directory: $agent_workspace"
    fi
    
    # Backup existing README if it exists (with rotation)
    if [[ -f "$target_file" ]]; then
        create_backup_with_rotation "$target_file" "workspace-readme"
    fi
    
    # Deploy template
    cp "$SCRIPT_DIR/home/.agents/README.md" "$target_file"
    print_success "Deployed: $target_file"
    return 0
}

verify_deployment() {
    print_info "Verifying template deployment..."
    
    local files_to_check=(
        "$HOME/AGENTS.md"
        "$HOME/git/AGENTS.md"
        "$HOME/.aidevops/.agent-workspace/README.md"
    )
    
    local all_good=true
    for file in "${files_to_check[@]}"; do
        if [[ -f "$file" ]]; then
            print_success "✓ $file"
        else
            print_error "✗ $file"
            all_good=false
        fi
    done
    
    if [[ "$all_good" == true ]]; then
        print_success "All templates deployed successfully!"
        return 0
    else
        print_error "Some templates failed to deploy"
        return 1
    fi
}

main() {
    echo -e "${BLUE}🔒 AI DevOps Framework - Secure Template Deployment${NC}"
    echo -e "${BLUE}============================================================${NC}"
    
    print_info "Deploying minimal, secure AGENTS.md templates..."
    print_warning "These templates contain minimal instructions to prevent prompt injection attacks"
    
    # Clean up old in-place backups from previous versions
    cleanup_old_backups
    
    deploy_home_agents
    deploy_git_agents
    deploy_agent_directory
    verify_deployment
    
    echo ""
    print_success "Template deployment complete!"
    print_info "All templates reference the authoritative repository at: $REPO_ROOT"
    print_warning "Do not modify these templates beyond minimal references for security"
    
    return 0
}

main "$@"
