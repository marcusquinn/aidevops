#!/usr/bin/env bash
# shellcheck disable=SC2059
set -euo pipefail

# shannon-helper.sh - Shannon AI pentester integration
#
# Wraps the Shannon CLI for autonomous penetration testing of web applications.
# Shannon uses Docker + Temporal for multi-agent exploit workflows.
#
# Usage:
#   shannon-helper.sh install                     # Clone Shannon repo
#   shannon-helper.sh start <url> <repo> [config] # Start a pentest
#   shannon-helper.sh stop [--clean]              # Stop containers
#   shannon-helper.sh status                      # Check Shannon status
#   shannon-helper.sh query <workflow-id>          # Query workflow progress
#   shannon-helper.sh logs [workflow-id]           # Tail workflow logs
#   shannon-helper.sh reports [hostname]           # List available reports
#   shannon-helper.sh help                         # Show this help
#
# Prerequisites:
#   - Docker (with docker compose)
#   - Anthropic API key (ANTHROPIC_API_KEY)
#
# Part of: aidevops framework (https://aidevops.sh)
# Task: t023 - Integrate Shannon AI pentester

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR
# shellcheck source=/dev/null
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true

readonly SHANNON_DIR="${SHANNON_DIR:-${HOME}/.aidevops/tools/shannon}"
readonly SHANNON_REPO="https://github.com/KeygraphHQ/shannon.git"

# Colors (only set if not already defined by shared-constants.sh)
if [[ -z "${RED:-}" ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly CYAN='\033[0;36m'
    readonly NC='\033[0m'
fi

print_usage() {
    cat << 'EOF'
Usage: shannon-helper.sh <command> [options]

Commands:
  install                       Clone/update Shannon repository
  start <url> <repo> [config]   Start a penetration test
  stop [--clean]                Stop Shannon containers (--clean removes volumes)
  status                        Check Shannon installation and container status
  query <workflow-id>           Query workflow progress
  logs [workflow-id]            Tail workflow logs (latest if no ID)
  reports [hostname]            List available pentest reports
  help                          Show this help

Environment:
  ANTHROPIC_API_KEY             Required for Shannon (or CLAUDE_CODE_OAUTH_TOKEN)
  SHANNON_DIR                   Override install location (default: ~/.aidevops/tools/shannon)

Examples:
  shannon-helper.sh install
  shannon-helper.sh start https://myapp.local:3000 /path/to/repo
  shannon-helper.sh start https://myapp.local:3000 /path/to/repo ./config.yaml
  shannon-helper.sh status
  shannon-helper.sh logs
  shannon-helper.sh reports myapp.local

Notes:
  - Shannon runs entirely in Docker containers
  - Pentests take 1-1.5 hours and cost ~$50 in API usage
  - NEVER run against production environments
  - Reports are saved to SHANNON_DIR/audit-logs/
EOF
    return 0
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        printf "${RED}Error: Docker is required but not installed.${NC}\n" >&2
        printf "Install Docker: https://docs.docker.com/get-docker/\n" >&2
        return 1
    fi
    if ! docker info &>/dev/null 2>&1; then
        printf "${RED}Error: Docker daemon is not running.${NC}\n" >&2
        printf "Start Docker and try again.\n" >&2
        return 1
    fi
    return 0
}

check_api_key() {
    # Source credentials if available
    # shellcheck source=/dev/null
    [[ -f "${HOME}/.config/aidevops/credentials.sh" ]] && source "${HOME}/.config/aidevops/credentials.sh"

    if [[ -z "${ANTHROPIC_API_KEY:-}" ]] && [[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        printf "${RED}Error: ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN required.${NC}\n" >&2
        printf "Set via: aidevops secret set ANTHROPIC_API_KEY\n" >&2
        printf "Or add to ~/.config/aidevops/credentials.sh\n" >&2
        return 1
    fi
    return 0
}

cmd_install() {
    check_docker || return 1

    if [[ -d "${SHANNON_DIR}/.git" ]]; then
        printf "${BLUE}Updating Shannon...${NC}\n"
        git -C "${SHANNON_DIR}" pull --ff-only 2>/dev/null || {
            printf "${YELLOW}!${NC} Pull failed, trying reset to origin/main\n"
            git -C "${SHANNON_DIR}" fetch origin
            git -C "${SHANNON_DIR}" reset --hard origin/main
        }
        printf "${GREEN}+${NC} Shannon updated at %s\n" "${SHANNON_DIR}"
    else
        printf "${BLUE}Cloning Shannon...${NC}\n"
        mkdir -p "$(dirname "${SHANNON_DIR}")"
        git clone "${SHANNON_REPO}" "${SHANNON_DIR}"
        printf "${GREEN}+${NC} Shannon installed at %s\n" "${SHANNON_DIR}"
    fi

    chmod +x "${SHANNON_DIR}/shannon"

    # Write .env if API key is available and .env doesn't exist
    if [[ ! -f "${SHANNON_DIR}/.env" ]]; then
        # shellcheck source=/dev/null
        [[ -f "${HOME}/.config/aidevops/credentials.sh" ]] && source "${HOME}/.config/aidevops/credentials.sh"
        if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
            cat > "${SHANNON_DIR}/.env" << ENVEOF
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000
ENVEOF
            chmod 600 "${SHANNON_DIR}/.env"
            printf "${GREEN}+${NC} Created .env with API key\n"
        else
            printf "${YELLOW}!${NC} No ANTHROPIC_API_KEY found. Create %s/.env manually.\n" "${SHANNON_DIR}"
        fi
    fi

    printf "\n${GREEN}Shannon installed!${NC}\n"
    printf "Next: shannon-helper.sh start <url> <repo>\n"
    return 0
}

cmd_start() {
    local url="${1:-}"
    local repo="${2:-}"
    local config="${3:-}"

    if [[ -z "${url}" ]] || [[ -z "${repo}" ]]; then
        printf "${RED}Error: URL and REPO are required.${NC}\n" >&2
        printf "Usage: shannon-helper.sh start <url> <repo> [config]\n" >&2
        return 1
    fi

    check_docker || return 1
    check_api_key || return 1

    if [[ ! -d "${SHANNON_DIR}/.git" ]]; then
        printf "${YELLOW}Shannon not installed. Installing...${NC}\n"
        cmd_install || return 1
    fi

    # Resolve repo to absolute path
    if [[ "${repo}" != /* ]]; then
        repo="$(cd "${repo}" 2>/dev/null && pwd)" || {
            printf "${RED}Error: Repository path not found: %s${NC}\n" "${repo}" >&2
            return 1
        }
    fi

    printf "${CYAN}Starting Shannon pentest...${NC}\n"
    printf "  Target: %s\n" "${url}"
    printf "  Repo:   %s\n" "${repo}"
    [[ -n "${config}" ]] && printf "  Config: %s\n" "${config}"
    printf "\n"
    printf "${YELLOW}WARNING: This will actively exploit the target application.${NC}\n"
    printf "${YELLOW}NEVER run against production environments.${NC}\n"
    printf "${YELLOW}Estimated time: 1-1.5 hours. Estimated cost: ~\$50 USD.${NC}\n"
    printf "\n"

    local -a args=("URL=${url}" "REPO=${repo}")
    [[ -n "${config}" ]] && args+=("CONFIG=${config}")

    # Run Shannon
    "${SHANNON_DIR}/shannon" start "${args[@]}"
    return $?
}

cmd_stop() {
    local clean_flag=""
    if [[ "${1:-}" == "--clean" ]]; then
        clean_flag="CLEAN=true"
    fi

    if [[ ! -d "${SHANNON_DIR}/.git" ]]; then
        printf "${YELLOW}Shannon not installed.${NC}\n"
        return 0
    fi

    printf "${BLUE}Stopping Shannon containers...${NC}\n"
    if [[ -n "${clean_flag}" ]]; then
        "${SHANNON_DIR}/shannon" stop "${clean_flag}"
    else
        "${SHANNON_DIR}/shannon" stop
    fi
    printf "${GREEN}+${NC} Shannon stopped\n"
    return 0
}

cmd_status() {
    printf "${CYAN}Shannon Status${NC}\n"
    printf "══════════════════════════════════════\n"

    # Installation
    if [[ -d "${SHANNON_DIR}/.git" ]]; then
        local sha
        sha=$(git -C "${SHANNON_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        local date
        date=$(git -C "${SHANNON_DIR}" log -1 --format='%ci' 2>/dev/null || echo "unknown")
        printf "${GREEN}Installed${NC}: %s (commit %s, %s)\n" "${SHANNON_DIR}" "${sha}" "${date}"
    else
        printf "${RED}Not installed${NC}. Run: shannon-helper.sh install\n"
        return 0
    fi

    # Docker
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        printf "${GREEN}Docker${NC}: running\n"
    else
        printf "${RED}Docker${NC}: not available\n"
        return 0
    fi

    # Containers
    local containers
    containers=$(docker compose -f "${SHANNON_DIR}/docker-compose.yml" ps --format json 2>/dev/null || echo "")
    if [[ -n "${containers}" ]]; then
        printf "\nContainers:\n"
        docker compose -f "${SHANNON_DIR}/docker-compose.yml" ps 2>/dev/null || true
    else
        printf "Containers: ${YELLOW}not running${NC}\n"
    fi

    # API key
    # shellcheck source=/dev/null
    [[ -f "${HOME}/.config/aidevops/credentials.sh" ]] && source "${HOME}/.config/aidevops/credentials.sh"
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]] || [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        printf "API key: ${GREEN}configured${NC}\n"
    else
        printf "API key: ${RED}not set${NC}\n"
    fi

    # Reports
    local report_count=0
    if [[ -d "${SHANNON_DIR}/audit-logs" ]]; then
        report_count=$(find "${SHANNON_DIR}/audit-logs" -name "comprehensive_security_assessment_report.md" 2>/dev/null | wc -l | tr -d ' ')
    fi
    printf "Reports: %s available\n" "${report_count}"

    return 0
}

cmd_query() {
    local workflow_id="${1:-}"
    if [[ -z "${workflow_id}" ]]; then
        printf "${RED}Error: Workflow ID required.${NC}\n" >&2
        printf "Usage: shannon-helper.sh query <workflow-id>\n" >&2
        return 1
    fi

    if [[ ! -d "${SHANNON_DIR}/.git" ]]; then
        printf "${RED}Shannon not installed.${NC}\n" >&2
        return 1
    fi

    "${SHANNON_DIR}/shannon" query "ID=${workflow_id}"
    return $?
}

cmd_logs() {
    local workflow_id="${1:-}"

    if [[ ! -d "${SHANNON_DIR}/.git" ]]; then
        printf "${RED}Shannon not installed.${NC}\n" >&2
        return 1
    fi

    if [[ -n "${workflow_id}" ]]; then
        "${SHANNON_DIR}/shannon" logs "ID=${workflow_id}"
    else
        # Find the latest workflow log
        local latest_log
        latest_log=$(find "${SHANNON_DIR}/audit-logs" -name "workflow.log" -type f -print0 2>/dev/null | \
            xargs -0 ls -t 2>/dev/null | head -1)
        if [[ -n "${latest_log}" ]]; then
            printf "${BLUE}Tailing latest workflow log: %s${NC}\n" "${latest_log}"
            tail -f "${latest_log}"
        else
            printf "${YELLOW}No workflow logs found.${NC}\n"
            printf "Start a pentest first: shannon-helper.sh start <url> <repo>\n"
        fi
    fi
    return 0
}

cmd_reports() {
    local hostname_filter="${1:-}"
    local audit_dir="${SHANNON_DIR}/audit-logs"

    if [[ ! -d "${audit_dir}" ]]; then
        printf "${YELLOW}No reports found. Run a pentest first.${NC}\n"
        return 0
    fi

    printf "${CYAN}Shannon Pentest Reports${NC}\n"
    printf "══════════════════════════════════════\n"

    local found=0
    while IFS= read -r report; do
        local dir
        dir=$(dirname "${report}")
        local session_name
        session_name=$(basename "${dir}")

        if [[ -n "${hostname_filter}" ]] && [[ "${session_name}" != *"${hostname_filter}"* ]]; then
            continue
        fi

        local session_json="${dir}/session.json"
        local date_str="unknown"
        if [[ -f "${session_json}" ]]; then
            date_str=$(python3 -c "
import json
with open('${session_json}') as f:
    d = json.load(f)
print(d.get('startTime', d.get('start_time', 'unknown'))[:19])
" 2>/dev/null || echo "unknown")
        fi

        printf "\n${GREEN}%s${NC}\n" "${session_name}"
        printf "  Date:   %s\n" "${date_str}"
        printf "  Report: %s\n" "${report}"
        found=$((found + 1)) || true
    done < <(find "${audit_dir}" -name "comprehensive_security_assessment_report.md" -type f 2>/dev/null | sort -r)

    if [[ "${found}" -eq 0 ]]; then
        printf "${YELLOW}No reports found"
        [[ -n "${hostname_filter}" ]] && printf " matching '%s'" "${hostname_filter}"
        printf ".${NC}\n"
    else
        printf "\nTotal: %d report(s)\n" "${found}"
    fi

    return 0
}

main() {
    local command="${1:-help}"
    shift 2>/dev/null || true

    case "${command}" in
        install)    cmd_install "$@" ;;
        start)      cmd_start "$@" ;;
        stop)       cmd_stop "$@" ;;
        status)     cmd_status "$@" ;;
        query)      cmd_query "$@" ;;
        logs)       cmd_logs "$@" ;;
        reports)    cmd_reports "$@" ;;
        help|--help|-h)
            print_usage
            ;;
        *)
            printf "${RED}Unknown command: %s${NC}\n" "${command}" >&2
            print_usage >&2
            return 1
            ;;
    esac
}

main "$@"
