#!/bin/bash

# Shared Constants for AI DevOps Framework Provider Scripts
# This file contains common strings, error messages, and configuration constants
# to reduce duplication and improve maintainability across provider scripts.
#
# Usage: source providers/shared-constants.sh
#
# Author: AI DevOps Framework
# Version: 1.6.0

# =============================================================================
# HTTP and API Constants
# =============================================================================

readonly CONTENT_TYPE_JSON="Content-Type: application/json"
readonly CONTENT_TYPE_FORM="Content-Type: application/x-www-form-urlencoded"
readonly USER_AGENT="User-Agent: AI-DevOps-Framework/1.6.0"

# HTTP Status Codes
readonly HTTP_OK=200
readonly HTTP_CREATED=201
readonly HTTP_BAD_REQUEST=400
readonly HTTP_UNAUTHORIZED=401
readonly HTTP_FORBIDDEN=403
readonly HTTP_NOT_FOUND=404
readonly HTTP_INTERNAL_ERROR=500

# =============================================================================
# Common Error Messages
# =============================================================================

readonly ERROR_CONFIG_NOT_FOUND="Configuration file not found"
readonly ERROR_INPUT_FILE_NOT_FOUND="Input file not found"
readonly ERROR_INPUT_FILE_REQUIRED="Input file is required"
readonly ERROR_REPO_NAME_REQUIRED="Repository name is required"
readonly ERROR_DOMAIN_NAME_REQUIRED="Domain name is required"
readonly ERROR_ACCOUNT_NAME_REQUIRED="Account name is required"
readonly ERROR_INSTANCE_NAME_REQUIRED="Instance name is required"
readonly ERROR_PROJECT_NOT_FOUND="Project not found in configuration"
readonly ERROR_UNKNOWN_COMMAND="Unknown command"
readonly ERROR_UNKNOWN_PLATFORM="Unknown platform"
readonly ERROR_PERMISSION_DENIED="Permission denied"
readonly ERROR_NETWORK_UNAVAILABLE="Network unavailable"
readonly ERROR_API_KEY_MISSING="API key is missing or invalid"
readonly ERROR_INVALID_CREDENTIALS="Invalid credentials"

# =============================================================================
# Success Messages
# =============================================================================

readonly SUCCESS_REPO_CREATED="Repository created successfully"
readonly SUCCESS_DEPLOYMENT_COMPLETE="Deployment completed successfully"
readonly SUCCESS_CONFIG_UPDATED="Configuration updated successfully"
readonly SUCCESS_BACKUP_CREATED="Backup created successfully"
readonly SUCCESS_CONNECTION_ESTABLISHED="Connection established successfully"
readonly SUCCESS_OPERATION_COMPLETE="Operation completed successfully"

# =============================================================================
# Common Usage Patterns
# =============================================================================

readonly USAGE_PATTERN="Usage: \$0 [command] [options]"
readonly HELP_PATTERN="Use '\$0 help' for more information"
readonly CONFIG_PATTERN="Edit configuration file: \$CONFIG_FILE"

# =============================================================================
# File and Directory Patterns
# =============================================================================

readonly BACKUP_SUFFIX=".backup"
readonly LOG_SUFFIX=".log"
readonly CONFIG_SUFFIX=".json"
readonly TEMPLATE_SUFFIX=".txt"
readonly TEMP_PREFIX="tmp_"

# =============================================================================
# Common Validation Patterns
# =============================================================================

readonly DOMAIN_REGEX="^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$"
readonly EMAIL_REGEX="^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"
readonly IP_REGEX="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
readonly PORT_REGEX="^[0-9]{1,5}$"

# =============================================================================
# Common Timeouts and Limits
# =============================================================================

readonly DEFAULT_TIMEOUT=30
readonly LONG_TIMEOUT=300
readonly SHORT_TIMEOUT=10
readonly MAX_RETRIES=3
readonly DEFAULT_PORT=80
readonly SECURE_PORT=443

# =============================================================================
# Color Constants (for consistent output formatting)
# =============================================================================

readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_PURPLE='\033[0;35m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_WHITE='\033[1;37m'
readonly COLOR_RESET='\033[0m'

# =============================================================================
# Common Functions for Error Handling
# =============================================================================

# Print error message with consistent formatting
print_shared_error() {
    local msg="$1"
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $msg" >&2
    return 0
}

# Print success message with consistent formatting
print_shared_success() {
    local msg="$1"
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $msg"
    return 0
}

# Print warning message with consistent formatting
print_shared_warning() {
    local msg="$1"
    echo -e "${COLOR_YELLOW}[WARNING]${COLOR_RESET} $msg"
    return 0
}

# Print info message with consistent formatting
print_shared_info() {
    local msg="$1"
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $msg"
    return 0
}

# Validate required parameter
validate_required_param() {
    local param_name="$1"
    local param_value="$2"
    
    if [[ -z "$param_value" ]]; then
        print_shared_error "$param_name is required"
        return 1
    fi
    return 0
}

# Check if file exists and is readable
validate_file_exists() {
    local file_path="$1"
    local file_description="${2:-File}"
    
    if [[ ! -f "$file_path" ]]; then
        print_shared_error "$file_description not found: $file_path"
        return 1
    fi
    
    if [[ ! -r "$file_path" ]]; then
        print_shared_error "$file_description is not readable: $file_path"
        return 1
    fi
    
    return 0
}

# Check if command exists
validate_command_exists() {
    local command_name="$1"
    
    if ! command -v "$command_name" &> /dev/null; then
        print_shared_error "Required command not found: $command_name"
        return 1
    fi
    return 0
}

# =============================================================================
# Export all constants for use in other scripts
# =============================================================================

# This ensures all constants are available when this file is sourced
export CONTENT_TYPE_JSON CONTENT_TYPE_FORM USER_AGENT
export HTTP_OK HTTP_CREATED HTTP_BAD_REQUEST HTTP_UNAUTHORIZED HTTP_FORBIDDEN HTTP_NOT_FOUND HTTP_INTERNAL_ERROR
export ERROR_CONFIG_NOT_FOUND ERROR_INPUT_FILE_NOT_FOUND ERROR_INPUT_FILE_REQUIRED
export ERROR_REPO_NAME_REQUIRED ERROR_DOMAIN_NAME_REQUIRED ERROR_ACCOUNT_NAME_REQUIRED
export SUCCESS_REPO_CREATED SUCCESS_DEPLOYMENT_COMPLETE SUCCESS_CONFIG_UPDATED
export USAGE_PATTERN HELP_PATTERN CONFIG_PATTERN
export DEFAULT_TIMEOUT LONG_TIMEOUT SHORT_TIMEOUT MAX_RETRIES
export COLOR_RED COLOR_GREEN COLOR_YELLOW COLOR_BLUE COLOR_PURPLE COLOR_CYAN COLOR_WHITE COLOR_RESET
