#!/bin/bash

# System Cleanup & Maintenance Script
# 
# Performs garbage collection, removes cruft, and maintains system hygiene
# for the AI DevOps Framework. Includes lock file protection and 90-day logging.
#
# Usage: ./system-cleanup.sh [--force] [--dry-run]
#
# Author: AI DevOps Framework
# Version: 1.0.0

# Strict mode
set -euo pipefail

# Constants
readonly SCRIPT_NAME="system-cleanup"
# VERSION is kept for reference and future use
# shellcheck disable=SC2034
readonly VERSION="1.0.0"
readonly LOG_DIR="$HOME/.agent/logs"
readonly LOG_FILE="${LOG_DIR}/operations.log"
readonly LOCK_FILE="/tmp/aidevops-${SCRIPT_NAME}.lock"
readonly TMP_DIR="$HOME/.agent/tmp"
readonly AGENT_DIR="$HOME/.agent"
readonly PROJECT_DIR="$HOME/git/aidevops"
readonly RETENTION_DAYS_LOGS=90
readonly RETENTION_DAYS_TMP=7

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Global state
DRY_RUN=true

# -----------------------------------------------------------------------------
# Logging & Output
# -----------------------------------------------------------------------------

setup_logging() {
    # Create log directory if it doesn't exist
    if [[ ! -d "$LOG_DIR" ]]; then
        mkdir -p "$LOG_DIR"
    fi
}

log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%dT%H:%M:%S%z")
    timestamp=$(date "+%Y-%m-%dT%H:%M:%S%z")
    
    # Console output
    local color="$NC"
    case "$level" in
        "INFO") color="$GREEN" ;;
        "WARN") color="$YELLOW" ;;
        "ERROR") color="$RED" ;;
        "DEBUG") color="$BLUE" ;;
    esac
    
    echo -e "${color}[${level}] ${message}${NC}"
    
    # File output (append)
    if [[ -d "$LOG_DIR" ]]; then
        echo "${timestamp} [${level}] ${message}" >> "$LOG_FILE"
    fi
    
    return 0
}

rotate_logs() {
    log "INFO" "Checking log retention policy (${RETENTION_DAYS_LOGS} days)..."
    
    if [[ ! -f "$LOG_FILE" ]]; then
        return 0
    fi
    
    # Use a temporary file to filter logs
    local temp_log="${LOG_FILE}.tmp"
    local cutoff_date
    
    # Calculate cutoff date timestamp for comparison (cross-platform compatible approximation)
    # Note: Precise date math in bash across OS versions is tricky.
    # Here we'll rely on finding lines that don't match old dates if possible, 
    # or simply use find to remove archived log files if we were rotating files.
    # Since we are appending to a single file, we'll inspect the file content.
    
    # For this implementation, we will archive the log file if it gets too large 
    # or just rely on the user to not have massive logs. 
    # A simpler robust approach for a single file is difficult without external tools.
    # Let's stick to the requirement: "keeps 90 days of records".
    
    # We will use a simple grep strategy assuming ISO dates: YYYY-MM-DD
    # Current date minus 90 days
    if date -v -90d > /dev/null 2>&1; then
        # BSD/macOS date
        cutoff_date=$(date -v -${RETENTION_DAYS_LOGS}d +%Y-%m-%d)
    else
        # GNU date
        cutoff_date=$(date -d "${RETENTION_DAYS_LOGS} days ago" +%Y-%m-%d)
    fi
    
    log "DEBUG" "Pruning logs older than $cutoff_date"
    
    # Filter the log file: Keep lines where date >= cutoff_date
    # This is a string comparison which works for ISO 8601 dates
    awk -v cutoff="$cutoff_date" '$1 >= cutoff' "$LOG_FILE" > "$temp_log"
    
    mv "$temp_log" "$LOG_FILE"
    
    return 0
}

# -----------------------------------------------------------------------------
# Lock File Management
# -----------------------------------------------------------------------------

acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        # Check if process is still running
        local pid
        pid=$(cat "$LOCK_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            log "ERROR" "Script is already running (PID: $pid). Lock file exists at $LOCK_FILE"
            return 1
        else
            log "WARN" "Found stale lock file from PID $pid. Removing..."
            rm -f "$LOCK_FILE"
        fi
    fi
    
    echo $$ > "$LOCK_FILE"
    return 0
}

release_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
    fi
    return 0
}

cleanup_exit() {
    local exit_code=$?
    release_lock
    if [[ $exit_code -eq 0 ]]; then
        log "INFO" "Cleanup completed successfully"
    else
        log "ERROR" "Cleanup finished with error (Code: $exit_code)"
    fi
    exit "$exit_code"
}

# -----------------------------------------------------------------------------
# Garbage Collection
# -----------------------------------------------------------------------------

cleanup_directory() {
    local dir="$1"
    local pattern="$2"
    local days="${3:-0}" # 0 means ignore age
    local desc="$4"
    
    if [[ ! -d "$dir" ]]; then
        log "DEBUG" "Directory not found, skipping: $dir"
        return 0
    fi
    
    log "INFO" "Scanning $desc ($dir)..."
    
    local find_cmd="find \"$dir\" -name \"$pattern\""
    
    # Add depth limit to avoid scanning entire system if path is wrong
    find_cmd="$find_cmd -maxdepth 4"
    
    # Add age filter if specified
    if [[ "$days" -gt 0 ]]; then
         # BSD/macOS find uses +7d, GNU uses -mtime +7
         find_cmd="$find_cmd -mtime +${days}"
    fi
    
    # Exclude common directories
    find_cmd="$find_cmd -not -path \"*/.git/*\" -not -path \"*/node_modules/*\""
    
    # Execute find
    local files_found
    files_found=$(eval "$find_cmd" || echo "")
    
    if [[ -z "$files_found" ]]; then
        log "DEBUG" "No matching files found for $desc"
        return 0
    fi
    
    # Process matches
    local count=0
    while IFS= read -r file; do
        if [[ -z "$file" ]]; then continue; fi
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log "INFO" "[DRY-RUN] Would delete: $file"
        else
            if rm -f "$file"; then
                log "INFO" "Deleted: $file"
            else
                log "ERROR" "Failed to delete: $file"
            fi
        fi
        count=$((count + 1))
    done <<< "$files_found"
    
    if [[ "$count" -gt 0 ]]; then
        log "INFO" "Processed $count files in $desc"
    fi
    
    return 0
}

cleanup_tmp_dir() {
    # Special handling for tmp directory to clean everything older than X days
    # Not just specific patterns
    
    if [[ ! -d "$TMP_DIR" ]]; then return 0; fi
    
    log "INFO" "Cleaning temporary directory ($TMP_DIR) - items older than $RETENTION_DAYS_TMP days..."
    
    # Using -mindepth 1 to not delete the dir itself
    local find_cmd="find \"$TMP_DIR\" -mindepth 1 -mtime +${RETENTION_DAYS_TMP}"
    
    # Exclude README.md
    find_cmd="$find_cmd -not -name \"README.md\""
    
    local items
    items=$(eval "$find_cmd" || echo "")
    
    if [[ -z "$items" ]]; then
        log "DEBUG" "No old temporary items found"
        return 0
    fi
    
    while IFS= read -r item; do
        if [[ -z "$item" ]]; then continue; fi
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log "INFO" "[DRY-RUN] Would delete: $item"
        else
             # Use rm -rf for directories
            if rm -rf "$item"; then
                log "INFO" "Deleted: $item"
            else
                log "ERROR" "Failed to delete: $item"
            fi
        fi
    done <<< "$items"
    
    return 0
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------

show_help() {
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  --force      Execute deletions (disable dry-run)"
    echo "  --dry-run    Simulate deletions (default)"
    echo "  --help       Show this help message"
    echo
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                DRY_RUN=false
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
    
    setup_logging
    
    # Trap signals for cleanup
    trap cleanup_exit INT TERM EXIT
    
    log "INFO" "Starting System Cleanup (Dry Run: $DRY_RUN)"
    
    if ! acquire_lock; then
        exit 1
    fi
    
    # 1. Log Rotation
    rotate_logs
    
    # 2. Clean Agent Directory Cruft
    cleanup_directory "$AGENT_DIR" ".DS_Store" 0 "Agent Directory System Files"
    cleanup_directory "$AGENT_DIR" "*.backup.*" 0 "Agent Directory Backups"
    cleanup_directory "$AGENT_DIR" "*.bak" 0 "Agent Directory Bak Files"
    
    # 3. Clean Project Directory Cruft
    cleanup_directory "$PROJECT_DIR" ".DS_Store" 0 "Project Directory System Files"
    cleanup_directory "$PROJECT_DIR" "*.backup" 0 "Project Directory Backups"
    cleanup_directory "$PROJECT_DIR" "*.bak" 0 "Project Directory Bak Files"
    cleanup_directory "$PROJECT_DIR" "*~" 0 "Project Directory Swap Files"
    
    # 4. Clean Temporary Directory (Age-based)
    cleanup_tmp_dir
    
    # 5. Clean Stale Lock Files (globally in /tmp related to this project)
    # Be careful here, only target our specific locks
    cleanup_directory "/tmp" "aidevops-*.lock" 1 "Stale Lock Files (>24h)"
    
    return 0
}

main "$@"
