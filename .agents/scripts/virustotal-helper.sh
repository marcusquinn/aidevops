#!/usr/bin/env bash
# virustotal-helper.sh - VirusTotal API v3 integration for skill security scanning
# Scans skill files, URLs, and domains against VirusTotal's 70+ AV engines
#
# Usage:
#   virustotal-helper.sh scan-file <file>          Scan a file by SHA256 hash lookup
#   virustotal-helper.sh scan-url <url>            Scan a URL for threats
#   virustotal-helper.sh scan-domain <domain>      Check domain reputation
#   virustotal-helper.sh scan-skill <path>         Scan all files in a skill directory
#   virustotal-helper.sh status                    Check API key and quota
#   virustotal-helper.sh help                      Show this help
#
# Environment:
#   VIRUSTOTAL_API_KEY - API key (loaded from credentials.sh or gopass)
#
# Rate limits (free tier): 4 requests/minute, 500 requests/day, 15.5K requests/month
set -euo pipefail

# shellcheck source=/dev/null
[[ -f "${HOME}/.config/aidevops/credentials.sh" ]] && source "${HOME}/.config/aidevops/credentials.sh"

# Constants
readonly VT_API_BASE="https://www.virustotal.com/api/v3"
readonly VERSION="1.0.0"
readonly RATE_LIMIT_DELAY=16  # 4 req/min = 1 every 15s, add 1s buffer

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    local msg="$1"
    echo -e "${BLUE}[virustotal]${NC} ${msg}" >&2
    return 0
}

log_success() {
    local msg="$1"
    echo -e "${GREEN}[OK]${NC} ${msg}" >&2
    return 0
}

log_warning() {
    local msg="$1"
    echo -e "${YELLOW}[WARN]${NC} ${msg}" >&2
    return 0
}

log_error() {
    local msg="$1"
    echo -e "${RED}[ERROR]${NC} ${msg}" >&2
    return 0
}

print_usage() {
    cat << 'EOF'
VirusTotal Helper - Skill Security Scanning via VT API v3

USAGE:
    virustotal-helper.sh <command> [options]

COMMANDS:
    scan-file <file>         Scan a file by SHA256 hash lookup
    scan-url <url>           Scan a URL for threats
    scan-domain <domain>     Check domain reputation
    scan-skill <path>        Scan all files in a skill directory
    status                   Check API key configuration and quota
    help                     Show this help message

OPTIONS:
    --json                   Output raw JSON response
    --quiet                  Only output verdict (SAFE/MALICIOUS/SUSPICIOUS/UNKNOWN)

ENVIRONMENT:
    VIRUSTOTAL_API_KEY       API key (from credentials.sh or gopass)

RATE LIMITS (free tier):
    4 requests/minute, 500 requests/day, 15.5K requests/month

EXAMPLES:
    virustotal-helper.sh scan-file .agents/tools/browser/playwright-skill.md
    virustotal-helper.sh scan-url https://example.com/skill.md
    virustotal-helper.sh scan-domain github.com
    virustotal-helper.sh scan-skill .agents/tools/browser/playwright-skill/
    virustotal-helper.sh status
EOF
    return 0
}

# Resolve VT API key from gopass or credentials.sh
resolve_api_key() {
    # Already set in environment (from credentials.sh source or export)
    if [[ -n "${VIRUSTOTAL_API_KEY:-}" ]]; then
        echo "${VIRUSTOTAL_API_KEY}"
        return 0
    fi

    # Try gopass (encrypted storage)
    if command -v gopass &>/dev/null; then
        local key=""
        # Try user-specific key first, then generic
        key=$(gopass show -o "aidevops/VIRUSTOTAL_MARCUSQUINN" 2>/dev/null || true)
        if [[ -z "$key" ]]; then
            key=$(gopass show -o "aidevops/VIRUSTOTAL_API_KEY" 2>/dev/null || true)
        fi
        if [[ -n "$key" ]]; then
            echo "$key"
            return 0
        fi
    fi

    # Try aidevops secret helper
    local script_dir=""
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
source "${SCRIPT_DIR}/shared-constants.sh"

    if [[ -x "${script_dir}/secret-helper.sh" ]]; then
        local key=""
        key=$("${script_dir}/secret-helper.sh" get VIRUSTOTAL_MARCUSQUINN 2>/dev/null || true)
        if [[ -z "$key" ]]; then
            key=$("${script_dir}/secret-helper.sh" get VIRUSTOTAL_API_KEY 2>/dev/null || true)
        fi
        if [[ -n "$key" ]]; then
            echo "$key"
            return 0
        fi
    fi

    return 1
}

# Make authenticated VT API request
# Args: method endpoint [data]
vt_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local api_key=""
    api_key=$(resolve_api_key) || {
        log_error "VirusTotal API key not found"
        log_info "Set with: aidevops secret set VIRUSTOTAL_MARCUSQUINN"
        log_info "Or export VIRUSTOTAL_API_KEY in credentials.sh"
        return 1
    }

    local curl_args=(
        -s
        --connect-timeout 10
        --max-time 30
        -H "x-apikey: ${api_key}"
        -H "Accept: application/json"
    )

    if [[ "$method" == "POST" ]]; then
        if [[ -n "$data" ]]; then
            curl_args+=(-X POST -d "$data")
        else
            curl_args+=(-X POST)
        fi
    fi

    local response=""
    response=$(curl "${curl_args[@]}" "${VT_API_BASE}${endpoint}" 2>/dev/null) || {
        log_error "API request failed: ${endpoint}"
        return 1
    }

    # Check for API errors
    # Exit codes: 0=success, 1=general error, 2=not found (allows callers to distinguish)
    local error_code=""
    error_code=$(echo "$response" | jq -r '.error.code // empty' 2>/dev/null || echo "")
    if [[ -n "$error_code" ]]; then
        local error_msg=""
        error_msg=$(echo "$response" | jq -r '.error.message // "Unknown error"' 2>/dev/null || echo "Unknown error")
        log_error "VT API error: ${error_code} - ${error_msg}"
        if [[ "$error_code" == "NotFoundError" ]]; then
            return 2
        fi
        return 1
    fi

    echo "$response"
    return 0
}

# Compute SHA256 hash of a file
file_sha256() {
    local file="$1"
    if command -v shasum &>/dev/null; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif command -v sha256sum &>/dev/null; then
        sha256sum "$file" | awk '{print $1}'
    else
        log_error "No SHA256 tool found (need shasum or sha256sum)"
        return 1
    fi
    return 0
}

# Parse VT analysis stats into a verdict
# Args: json_response
parse_verdict() {
    local response="$1"

    local malicious harmless suspicious undetected timeout
    malicious=$(echo "$response" | jq -r '.data.attributes.last_analysis_stats.malicious // 0' 2>/dev/null || echo "0")
    harmless=$(echo "$response" | jq -r '.data.attributes.last_analysis_stats.harmless // 0' 2>/dev/null || echo "0")
    suspicious=$(echo "$response" | jq -r '.data.attributes.last_analysis_stats.suspicious // 0' 2>/dev/null || echo "0")
    undetected=$(echo "$response" | jq -r '.data.attributes.last_analysis_stats.undetected // 0' 2>/dev/null || echo "0")
    timeout=$(echo "$response" | jq -r '.data.attributes.last_analysis_stats.timeout // 0' 2>/dev/null || echo "0")

    local total=$((malicious + harmless + suspicious + undetected + timeout))

    if [[ "$malicious" -gt 0 ]]; then
        echo "MALICIOUS|${malicious}/${total} engines detected threats"
    elif [[ "$suspicious" -gt 0 ]]; then
        echo "SUSPICIOUS|${suspicious}/${total} engines flagged as suspicious"
    else
        echo "SAFE|${harmless}/${total} engines found no threats"
    fi
    return 0
}

# Rate limit: sleep between requests to stay within free tier
rate_limit_wait() {
    sleep "$RATE_LIMIT_DELAY"
    return 0
}

# =============================================================================
# Commands
# =============================================================================

cmd_scan_file() {
    local file="$1"
    local output_json="${2:-false}"
    local quiet="${3:-false}"

    if [[ ! -f "$file" ]]; then
        log_error "File not found: ${file}"
        return 1
    fi

    local sha256=""
    sha256=$(file_sha256 "$file") || return 1

    if [[ "$quiet" != "true" ]]; then
        log_info "Scanning file: ${file}"
        log_info "SHA256: ${sha256}"
    fi

    local response=""
    local vt_exit=0
    response=$(vt_request "GET" "/files/${sha256}") || vt_exit=$?

    if [[ $vt_exit -eq 2 ]]; then
        # NotFoundError: file not in VT database -- normal for text/markdown files
        if [[ "$quiet" == "true" ]]; then
            echo "UNKNOWN"
        else
            log_info "File not found in VirusTotal database (never submitted)"
            log_info "This is normal for text/markdown skill files"
        fi
        echo "UNKNOWN|File not in VT database"
        return 0
    elif [[ $vt_exit -ne 0 ]]; then
        # Real API error (quota exceeded, network failure, etc.)
        if [[ "$quiet" == "true" ]]; then
            echo "UNKNOWN"
        else
            log_error "API request failed for file: ${file}"
        fi
        return 1
    fi

    if [[ "$output_json" == "true" ]]; then
        echo "$response"
        return 0
    fi

    local verdict=""
    verdict=$(parse_verdict "$response")
    local status="${verdict%%|*}"
    local detail="${verdict#*|}"

    if [[ "$quiet" == "true" ]]; then
        echo "$status"
        return 0
    fi

    case "$status" in
        MALICIOUS)
            echo -e "${RED}MALICIOUS${NC}: ${detail}"
            # Show which engines detected it
            echo "$response" | jq -r '.data.attributes.last_analysis_results | to_entries[] | select(.value.category == "malicious") | "  [\(.key)] \(.value.result)"' 2>/dev/null || true
            ;;
        SUSPICIOUS)
            echo -e "${YELLOW}SUSPICIOUS${NC}: ${detail}"
            echo "$response" | jq -r '.data.attributes.last_analysis_results | to_entries[] | select(.value.category == "suspicious") | "  [\(.key)] \(.value.result)"' 2>/dev/null || true
            ;;
        SAFE)
            echo -e "${GREEN}SAFE${NC}: ${detail}"
            ;;
        *)
            echo -e "${BLUE}UNKNOWN${NC}: ${detail}"
            ;;
    esac

    return 0
}

cmd_scan_url() {
    local url="$1"
    local output_json="${2:-false}"
    local quiet="${3:-false}"

    if [[ -z "$url" ]]; then
        log_error "URL required"
        return 1
    fi

    if [[ "$quiet" != "true" ]]; then
        log_info "Scanning URL: ${url}"
    fi

    # VT URL ID is base64url-encoded URL (without padding)
    local url_id=""
    url_id=$(printf '%s' "$url" | base64 | tr '+/' '-_' | tr -d '=')

    # Try to get existing report first
    local response=""
    response=$(vt_request "GET" "/urls/${url_id}" 2>/dev/null) || {
        # No existing report, submit for scanning
        if [[ "$quiet" != "true" ]]; then
            log_info "No existing report, submitting URL for scanning..."
        fi
        local submit_response=""
        submit_response=$(vt_request "POST" "/urls" "url=${url}") || return 1

        # Get analysis ID and poll for results
        local analysis_id=""
        analysis_id=$(echo "$submit_response" | jq -r '.data.id // empty' 2>/dev/null || echo "")
        if [[ -z "$analysis_id" ]]; then
            log_error "Failed to submit URL for scanning"
            return 1
        fi

        if [[ "$quiet" != "true" ]]; then
            log_info "Analysis submitted, waiting for results..."
        fi

        # Wait and retry (VT typically processes URLs in a few seconds)
        rate_limit_wait
        response=$(vt_request "GET" "/urls/${url_id}") || {
            echo "UNKNOWN|URL submitted but results not yet available"
            return 0
        }
    }

    if [[ "$output_json" == "true" ]]; then
        echo "$response"
        return 0
    fi

    local verdict=""
    verdict=$(parse_verdict "$response")
    local status="${verdict%%|*}"
    local detail="${verdict#*|}"

    if [[ "$quiet" == "true" ]]; then
        echo "$status"
        return 0
    fi

    case "$status" in
        MALICIOUS)
            echo -e "${RED}MALICIOUS${NC}: ${detail}"
            echo "$response" | jq -r '.data.attributes.last_analysis_results | to_entries[] | select(.value.category == "malicious") | "  [\(.key)] \(.value.result)"' 2>/dev/null || true
            ;;
        SUSPICIOUS)
            echo -e "${YELLOW}SUSPICIOUS${NC}: ${detail}"
            ;;
        SAFE)
            echo -e "${GREEN}SAFE${NC}: ${detail}"
            ;;
        *)
            echo -e "${BLUE}UNKNOWN${NC}: ${detail}"
            ;;
    esac

    return 0
}

cmd_scan_domain() {
    local domain="$1"
    local output_json="${2:-false}"
    local quiet="${3:-false}"

    if [[ -z "$domain" ]]; then
        log_error "Domain required"
        return 1
    fi

    # Strip protocol and path if present
    domain="${domain#https://}"
    domain="${domain#http://}"
    domain="${domain%%/*}"

    if [[ "$quiet" != "true" ]]; then
        log_info "Checking domain reputation: ${domain}"
    fi

    local response=""
    response=$(vt_request "GET" "/domains/${domain}") || return 1

    if [[ "$output_json" == "true" ]]; then
        echo "$response"
        return 0
    fi

    local verdict=""
    verdict=$(parse_verdict "$response")
    local status="${verdict%%|*}"
    local detail="${verdict#*|}"

    # Also extract reputation score
    local reputation=""
    reputation=$(echo "$response" | jq -r '.data.attributes.reputation // "N/A"' 2>/dev/null || echo "N/A")

    if [[ "$quiet" == "true" ]]; then
        echo "$status"
        return 0
    fi

    case "$status" in
        MALICIOUS)
            echo -e "${RED}MALICIOUS${NC}: ${detail} (reputation: ${reputation})"
            ;;
        SUSPICIOUS)
            echo -e "${YELLOW}SUSPICIOUS${NC}: ${detail} (reputation: ${reputation})"
            ;;
        SAFE)
            echo -e "${GREEN}SAFE${NC}: ${detail} (reputation: ${reputation})"
            ;;
        *)
            echo -e "${BLUE}UNKNOWN${NC}: ${detail} (reputation: ${reputation})"
            ;;
    esac

    return 0
}

# Scan all files in a skill directory
# Hashes each file, checks URLs/domains found in content
cmd_scan_skill() {
    local skill_path="$1"
    local output_json="${2:-false}"
    local quiet="${3:-false}"

    if [[ ! -e "$skill_path" ]]; then
        log_error "Path not found: ${skill_path}"
        return 1
    fi

    # Determine files to scan
    local files=()
    if [[ -f "$skill_path" ]]; then
        files=("$skill_path")
    elif [[ -d "$skill_path" ]]; then
        while IFS= read -r -d '' f; do
            files+=("$f")
        done < <(find "$skill_path" -type f \( -name "*.md" -o -name "*.sh" -o -name "*.py" -o -name "*.js" -o -name "*.ts" -o -name "*.yaml" -o -name "*.yml" -o -name "*.json" \) -print0 2>/dev/null)
    fi

    if [[ ${#files[@]} -eq 0 ]]; then
        log_warning "No scannable files found in: ${skill_path}"
        return 0
    fi

    local skill_name=""
    skill_name=$(basename "$skill_path" | sed 's/-skill$//' | sed 's/\.md$//')

    if [[ "$quiet" != "true" ]]; then
        log_info "Scanning skill '${skill_name}': ${#files[@]} file(s)"
        echo ""
    fi

    local total_files=${#files[@]}
    local malicious_count=0
    local suspicious_count=0
    local safe_count=0
    local unknown_count=0
    local urls_found=()
    local domains_found=()
    local request_count=0
    local max_requests=8  # Limit per skill scan to avoid rate limiting

    # Phase 1: Hash-based file scanning
    for file in "${files[@]}"; do
        if [[ $request_count -ge $max_requests ]]; then
            log_warning "Rate limit reached (${max_requests} requests), skipping remaining file hashes"
            unknown_count=$((unknown_count + 1))
            continue
        fi

        local basename_file=""
        basename_file=$(basename "$file")

        local sha256=""
        sha256=$(file_sha256 "$file") || continue

        local response=""
        local vt_exit=0
        response=$(vt_request "GET" "/files/${sha256}" 2>/dev/null) || vt_exit=$?
        request_count=$((request_count + 1))

        if [[ $vt_exit -ne 0 ]]; then
            if [[ "$quiet" != "true" ]]; then
                if [[ $vt_exit -eq 2 ]]; then
                    echo -e "  ${BLUE}SKIP${NC} ${basename_file} (not in VT database)"
                else
                    echo -e "  ${YELLOW}SKIP${NC} ${basename_file} (API error)"
                fi
            fi
            unknown_count=$((unknown_count + 1))
            continue
        fi

        local verdict=""
        verdict=$(parse_verdict "$response")
        local status="${verdict%%|*}"
        local detail="${verdict#*|}"

        case "$status" in
            MALICIOUS)
                malicious_count=$((malicious_count + 1))
                if [[ "$quiet" != "true" ]]; then
                    echo -e "  ${RED}MALICIOUS${NC} ${basename_file}: ${detail}"
                fi
                ;;
            SUSPICIOUS)
                suspicious_count=$((suspicious_count + 1))
                if [[ "$quiet" != "true" ]]; then
                    echo -e "  ${YELLOW}SUSPICIOUS${NC} ${basename_file}: ${detail}"
                fi
                ;;
            SAFE)
                safe_count=$((safe_count + 1))
                if [[ "$quiet" != "true" ]]; then
                    echo -e "  ${GREEN}SAFE${NC} ${basename_file}: ${detail}"
                fi
                ;;
            *)
                unknown_count=$((unknown_count + 1))
                if [[ "$quiet" != "true" ]]; then
                    echo -e "  ${BLUE}UNKNOWN${NC} ${basename_file}: ${detail}"
                fi
                ;;
        esac

        # Rate limit between requests
        if [[ $request_count -lt $max_requests ]]; then
            rate_limit_wait
        fi
    done

    # Phase 2: Extract and scan URLs from skill content
    local -A domains_seen=()
    for file in "${files[@]}"; do
        while IFS= read -r url; do
            case "$url" in
                *github.com*|*githubusercontent.com*|*npmjs.com*|*pypi.org*|*docs.virustotal.com*)
                    continue
                    ;;
            esac
            urls_found+=("$url")

            local domain=""
            domain=$(echo "$url" | sed -E 's|https?://([^/]+).*|\1|')
            if [[ -z "${domains_seen[$domain]+x}" ]]; then
                domains_seen[$domain]=1
                domains_found+=("$domain")
            fi
        done < <(grep -oE 'https?://[^ "'"'"'<>]+' "$file" 2>/dev/null | sort -u || true)
    done

    # Scan unique domains (up to rate limit)
    if [[ ${#domains_found[@]} -gt 0 && $request_count -lt $max_requests ]]; then
        if [[ "$quiet" != "true" ]]; then
            echo ""
            log_info "Checking ${#domains_found[@]} domain(s) referenced in skill..."
        fi

        for domain in "${domains_found[@]}"; do
            if [[ $request_count -ge $max_requests ]]; then
                log_warning "Rate limit reached, skipping remaining domains"
                break
            fi

            rate_limit_wait

            local response=""
            local vt_exit=0
            response=$(vt_request "GET" "/domains/${domain}" 2>/dev/null) || vt_exit=$?
            request_count=$((request_count + 1))

            if [[ $vt_exit -ne 0 ]]; then
                if [[ "$quiet" != "true" ]]; then
                    echo -e "  ${BLUE}SKIP${NC} ${domain} (lookup failed)"
                fi
                continue
            fi

            local verdict=""
            verdict=$(parse_verdict "$response")
            local status="${verdict%%|*}"
            local detail="${verdict#*|}"

            case "$status" in
                MALICIOUS)
                    malicious_count=$((malicious_count + 1))
                    if [[ "$quiet" != "true" ]]; then
                        echo -e "  ${RED}MALICIOUS${NC} ${domain}: ${detail}"
                    fi
                    ;;
                SUSPICIOUS)
                    suspicious_count=$((suspicious_count + 1))
                    if [[ "$quiet" != "true" ]]; then
                        echo -e "  ${YELLOW}SUSPICIOUS${NC} ${domain}: ${detail}"
                    fi
                    ;;
                SAFE)
                    if [[ "$quiet" != "true" ]]; then
                        echo -e "  ${GREEN}SAFE${NC} ${domain}: ${detail}"
                    fi
                    ;;
                *)
                    if [[ "$quiet" != "true" ]]; then
                        echo -e "  ${BLUE}UNKNOWN${NC} ${domain}: ${detail}"
                    fi
                    ;;
            esac
        done
    fi

    # Summary
    if [[ "$quiet" != "true" ]]; then
        echo ""
        echo "═══════════════════════════════════════"
        echo -e "Skill: ${skill_name}"
        echo -e "Files scanned: ${total_files}"
        echo -e "Domains checked: ${#domains_found[@]}"
        echo -e "VT API requests: ${request_count}"
        if [[ $malicious_count -gt 0 ]]; then
            echo -e "Result: ${RED}MALICIOUS (${malicious_count} threat(s))${NC}"
        elif [[ $suspicious_count -gt 0 ]]; then
            echo -e "Result: ${YELLOW}SUSPICIOUS (${suspicious_count} flag(s))${NC}"
        else
            echo -e "Result: ${GREEN}SAFE${NC}"
        fi
        echo "═══════════════════════════════════════"
    fi

    # Output JSON summary if requested
    if [[ "$output_json" == "true" ]]; then
        cat << ENDJSON
{
  "skill": "${skill_name}",
  "files_scanned": ${total_files},
  "domains_checked": ${#domains_found[@]},
  "malicious": ${malicious_count},
  "suspicious": ${suspicious_count},
  "safe": ${safe_count},
  "unknown": ${unknown_count},
  "verdict": "$(if [[ $malicious_count -gt 0 ]]; then echo "MALICIOUS"; elif [[ $suspicious_count -gt 0 ]]; then echo "SUSPICIOUS"; else echo "SAFE"; fi)"
}
ENDJSON
    fi

    # Return non-zero if threats found
    if [[ $malicious_count -gt 0 ]]; then
        return 1
    fi
    return 0
}

cmd_status() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║           VirusTotal Helper v${VERSION}                      ║"
    echo "║   Skill security scanning via VT API v3                   ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Check API key
    local api_key=""
    api_key=$(resolve_api_key 2>/dev/null) || true

    if [[ -n "$api_key" ]]; then
        # Mask key for display
        local masked="${api_key:0:4}...${api_key: -4}"
        echo -e "  ${GREEN}✓${NC} API key configured (${masked})"

        # Check quota by making a lightweight request
        local response=""
        response=$(vt_request "GET" "/users/me" 2>/dev/null) || {
            echo -e "  ${YELLOW}○${NC} Could not verify API key (request failed)"
            return 0
        }

        local username=""
        username=$(echo "$response" | jq -r '.data.id // "unknown"' 2>/dev/null || echo "unknown")
        local api_type=""
        api_type=$(echo "$response" | jq -r '.data.attributes.privileges // {} | keys[0] // "public"' 2>/dev/null || echo "public")

        echo -e "  ${GREEN}✓${NC} Account: ${username}"
        echo -e "  ${GREEN}✓${NC} API type: ${api_type}"
    else
        echo -e "  ${RED}✗${NC} API key not configured"
        echo ""
        echo "  Set with:"
        echo "    aidevops secret set VIRUSTOTAL_MARCUSQUINN"
        echo "  Or:"
        echo "    export VIRUSTOTAL_API_KEY=<key> in ~/.config/aidevops/credentials.sh"
    fi

    echo ""

    # Check dependencies
    echo -e "${BLUE}Dependencies:${NC}"
    if command -v curl &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} curl"
    else
        echo -e "  ${RED}✗${NC} curl (required)"
    fi

    if command -v jq &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} jq"
    else
        echo -e "  ${RED}✗${NC} jq (required for JSON parsing)"
    fi

    if command -v shasum &>/dev/null || command -v sha256sum &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} SHA256 (shasum/sha256sum)"
    else
        echo -e "  ${RED}✗${NC} SHA256 tool (need shasum or sha256sum)"
    fi

    return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
    local command="${1:-help}"
    shift || true

    # Verify required dependencies (jq is needed for all scan commands)
    if [[ "$command" != "help" && "$command" != "--help" && "$command" != "-h" ]] && \
       ! command -v jq &>/dev/null; then
        log_error "jq is required but not installed (brew install jq)"
        return 1
    fi

    # Parse global flags
    local output_json=false
    local quiet=false
    local args=()

    local opt
    for opt in "$@"; do
        case "$opt" in
            --json) output_json=true ;;
            --quiet|-q) quiet=true ;;
            *) args+=("$opt") ;;
        esac
    done

    case "$command" in
        scan-file|file)
            if [[ ${#args[@]} -lt 1 ]]; then
                log_error "File path required"
                echo "Usage: virustotal-helper.sh scan-file <file>"
                return 1
            fi
            cmd_scan_file "${args[0]}" "$output_json" "$quiet"
            ;;
        scan-url|url)
            if [[ ${#args[@]} -lt 1 ]]; then
                log_error "URL required"
                echo "Usage: virustotal-helper.sh scan-url <url>"
                return 1
            fi
            cmd_scan_url "${args[0]}" "$output_json" "$quiet"
            ;;
        scan-domain|domain)
            if [[ ${#args[@]} -lt 1 ]]; then
                log_error "Domain required"
                echo "Usage: virustotal-helper.sh scan-domain <domain>"
                return 1
            fi
            cmd_scan_domain "${args[0]}" "$output_json" "$quiet"
            ;;
        scan-skill|skill)
            if [[ ${#args[@]} -lt 1 ]]; then
                log_error "Skill path required"
                echo "Usage: virustotal-helper.sh scan-skill <path>"
                return 1
            fi
            cmd_scan_skill "${args[0]}" "$output_json" "$quiet"
            ;;
        status)
            cmd_status
            ;;
        help|--help|-h)
            print_usage
            ;;
        *)
            log_error "Unknown command: ${command}"
            echo ""
            print_usage
            return 1
            ;;
    esac
}

main "$@"
