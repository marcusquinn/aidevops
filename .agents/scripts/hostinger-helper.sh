#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# Hostinger Helper Script
# Manages Hostinger shared hosting sites and API operations

# Source shared constants if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "$SCRIPT_DIR/shared-constants.sh" 2>/dev/null || true

# HTTP Constants
# Error message constants
readonly HELP_SHOW_MESSAGE="Show this help"
readonly HELP_USAGE_INFO="Use '$0 help' for usage information"

# Configuration file (legacy site commands): resolved from the script location,
# not the caller's working directory.
CONFIG_FILE="${HOSTINGER_CONFIG_FILE:-$SCRIPT_DIR/../configs/hostinger-config.json}"

# Check if config file exists
check_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "$ERROR_CONFIG_NOT_FOUND: $CONFIG_FILE"
        print_info "Copy and customize: cp $SCRIPT_DIR/../configs/hostinger-config.json.txt $CONFIG_FILE"
        exit 1
    fi

    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        print_error "$ERROR_INVALID_JSON"
        exit 1
    fi

    return 0
}

# List all sites
list_sites() {
    check_config
    print_info "Available Hostinger sites:"
    
    sites=$(jq -r '.sites | keys[]' "$CONFIG_FILE")
    for site in $sites; do
        description=$(jq -r ".sites.$site.description" "$CONFIG_FILE")
        path=$(jq -r ".sites.$site.domain_path" "$CONFIG_FILE")
        echo "  - $site: $description ($path)"
    done

    return 0
}

# Connect to a specific site
connect_site() {
    local site="$1"
    check_config
    
    if [[ -z "$site" ]]; then
        print_error "Please specify a site name"
        list_sites
        exit 1
    fi
    
    # Get site configuration
    local server
    local port
    local username
    local password_file
    local ssh_identity_file
    local domain_path
    server=$(jq -r ".sites.$site.server" "$CONFIG_FILE")
    port=$(jq -r ".sites.$site.port" "$CONFIG_FILE")
    username=$(jq -r ".sites.$site.username" "$CONFIG_FILE")
    password_file=$(jq -r ".sites.$site.password_file // empty" "$CONFIG_FILE")
    ssh_identity_file=$(jq -r ".sites.$site.ssh_identity_file // empty" "$CONFIG_FILE")
    domain_path=$(jq -r ".sites.$site.domain_path" "$CONFIG_FILE")

    if [[ "$server" == "null" ]]; then
        print_error "Site not found: $site"
        list_sites
        exit 1
    fi

    print_info "Connecting to $site..."

    # Prefer SSH key auth if configured (Hostinger recommends it)
    if [[ -n "$ssh_identity_file" ]]; then
        local expanded_identity="${ssh_identity_file/#\~/$HOME}"
        ssh -i "$expanded_identity" -p "$port" "$username@$server" -t "cd $domain_path && bash" || exit
        return 0
    fi

    # Fallback: sshpass with password file (backward compatible)
    password_file="${password_file/\~/$HOME}"
    if [[ ! -f "$password_file" ]]; then
        print_error "Password file not found: $password_file"
        print_info "Create password file: echo 'your-password' > $password_file && chmod 600 $password_file"
        exit 1
    fi

    # Connect with sshpass
    sshpass -f "$password_file" ssh -p "$port" "$username@$server" -t "cd $domain_path && bash" || exit
    return 0
}

# Execute command on site
exec_on_site() {
    local site="$1"
    local command="$2"
    check_config
    
    if [[ -z "$site" || -z "$command" ]]; then
        print_error "Usage: exec [site] [command]"
        exit 1
    fi
    
    # Get site configuration
    local server
    local port
    local username
    local password_file
    local ssh_identity_file
    local domain_path
    server=$(jq -r ".sites.$site.server" "$CONFIG_FILE")
    port=$(jq -r ".sites.$site.port" "$CONFIG_FILE")
    username=$(jq -r ".sites.$site.username" "$CONFIG_FILE")
    password_file=$(jq -r ".sites.$site.password_file // empty" "$CONFIG_FILE")
    ssh_identity_file=$(jq -r ".sites.$site.ssh_identity_file // empty" "$CONFIG_FILE")
    domain_path=$(jq -r ".sites.$site.domain_path" "$CONFIG_FILE")

    if [[ "$server" == "null" ]]; then
        print_error "Site not found: $site"
        exit 1
    fi

    print_info "Executing '$command' on $site..."

    # Prefer SSH key auth if configured (Hostinger recommends it)
    if [[ -n "$ssh_identity_file" ]]; then
        local expanded_identity="${ssh_identity_file/#\~/$HOME}"
        ssh -i "$expanded_identity" -p "$port" "$username@$server" "cd $domain_path && $command" || exit
        return 0
    fi

    # Fallback: sshpass with password file (backward compatible)
    password_file="${password_file/\~/$HOME}"
    sshpass -f "$password_file" ssh -p "$port" "$username@$server" "cd $domain_path && $command" || exit
    return 0
}

# API operations: api [METHOD] ENDPOINT [JSON_BODY]
# The token comes from HOSTINGER_API_TOKEN, else the aidevops secret store
# (re-exec with injection, like fleet/cron), else the legacy config file.
# It is passed to curl on stdin, never on the command line.
api_call() {
    local first="${1:-}"
    local second="${2:-}"
    local third="${3:-}"
    local method="GET"
    local endpoint="$first"
    local body=""
    local api_token="${HOSTINGER_API_TOKEN:-}"
    local base_url="${HOSTINGER_API_BASE_URL:-https://developers.hostinger.com}"

    case "$first" in
    GET | POST | PUT | PATCH | DELETE)
        method="$first"
        endpoint="$second"
        body="$third"
        ;;
    esac
    if [[ -z "$endpoint" ]]; then
        print_error "Usage: api [GET|POST|PUT|PATCH|DELETE] ENDPOINT [JSON_BODY]"
        return 1
    fi

    if [[ -z "$api_token" && -z "${HOSTINGER_API_REEXEC:-}" ]] &&
        command -v aidevops >/dev/null 2>&1 &&
        aidevops secret check HOSTINGER_API_TOKEN >/dev/null 2>&1; then
        local status=0
        HOSTINGER_API_REEXEC=1 aidevops secret HOSTINGER_API_TOKEN -- \
            "$SCRIPT_DIR/hostinger-helper.sh" api "$method" "$endpoint" "$body" || status=$?
        return "$status"
    fi

    if [[ -z "$api_token" ]]; then
        if [[ ! -f "$CONFIG_FILE" ]]; then
            print_error "Hostinger API token not found"
            print_info "Store it with: aidevops secret set HOSTINGER_API_TOKEN"
            return 1
        fi
        check_config
        api_token=$(jq -r '.api.token // empty' "$CONFIG_FILE")
        base_url=$(jq -r --arg d "$base_url" '.api.base_url // $d' "$CONFIG_FILE")
        if [[ -z "$api_token" || "$api_token" == "YOUR_HOSTINGER_API_TOKEN_HERE" ]]; then
            print_error "API token not configured"
            return 1
        fi
    fi

    endpoint="${endpoint#/}"
    local -a curl_args=(-sS -K - -X "$method" -H "Accept: application/json")
    if [[ "${HOSTINGER_API_BOUNDED:-}" == "1" ]]; then
        curl_args+=(--fail --connect-timeout 5 --max-time 10)
    fi
    if [[ -n "$body" ]]; then
        curl_args+=(-H "Content-Type: application/json" --data-binary "$body")
    fi
    printf 'header = "%s %s"\n' "$AUTH_HEADER_PREFIX" "$api_token" |
        curl "${curl_args[@]}" "${base_url%/}/$endpoint"
    return $?
}

# Read-only SSL status; resolve the hosting username without caller substitution.
ssl_status() {
    local domain="${1:-}"
    local encoded_domain
    local websites
    local username
    local encoded_username
    local response

    if [[ -z "$domain" || ! "$domain" =~ ^[[:alnum:]]([[:alnum:].-]*[[:alnum:]])?$ || "$domain" == *..* ]]; then
        print_error "Usage: ssl-status DOMAIN (hostname only)" >&2
        return 1
    fi

    encoded_domain=$(jq -rn --arg domain "$domain" '$domain | @uri') || return 1
    websites=$(api_call GET "api/hosting/v1/websites?domain=$encoded_domain") || return 1
    if ! username=$(printf '%s' "$websites" | jq -er '.data[0].username | select(type == "string" and length > 0)'); then
        print_error "Could not resolve hosting username for: $domain" >&2
        return 1
    fi
    encoded_username=$(jq -rn --arg username "$username" '$username | @uri') || return 1
    response=$(api_call GET "api/hosting/v1/accounts/$encoded_username/websites/$encoded_domain/ssl/status") || return 1
    printf '%s\n' "$response" | jq -e . || return 1
    return 0
}

# Queue a non-destructive account scan, then print only matching installation metadata.
wordpress_detect() {
    local domain="${1:-}"
    local encoded_domain
    local websites
    local username
    local encoded_username
    local response
    local installations
    local attempt
    # Export through secret-store re-execution too; raw api/ssl-status stay unchanged.
    local -x HOSTINGER_API_BOUNDED=1

    if [[ -z "$domain" || ! "$domain" =~ ^[[:alnum:]]([[:alnum:].-]*[[:alnum:]])?$ || "$domain" == *..* ]]; then
        print_error "Usage: wordpress-detect DOMAIN (hostname only)" >&2
        return 1
    fi

    domain=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')
    encoded_domain=$(jq -rn --arg domain "$domain" '$domain | @uri') || return 1
    websites=$(api_call GET "api/hosting/v1/websites?domain=$encoded_domain") || return 1
    if ! username=$(printf '%s' "$websites" | jq -er --arg domain "$domain" '
        [.data[] | select((.domain | ascii_downcase) == $domain)]
        | select(length == 1) | .[0].username
        | select(type == "string" and length > 0)'); then
        print_error "Could not resolve a unique hosting account for: $domain" >&2
        return 1
    fi
    encoded_username=$(jq -rn --arg username "$username" '$username | @uri') || return 1
    api_call POST "api/hosting/v1/accounts/$encoded_username/wordpress/installations/detect" >/dev/null || return 1

    for ((attempt = 1; attempt <= 12; attempt++)); do
        response=$(api_call GET "api/hosting/v1/wordpress/installations?username=$encoded_username&domain=$encoded_domain&ownership=all") || return 1
        installations=$(printf '%s' "$response" | jq -ce --arg domain "$domain" '
            (if type == "array" then . else .data end)
            | if type != "array" then error("Expected installations array") else . end
            | [.[] | select((.domain | ascii_downcase) == $domain)
                | {id, domain, is_valid: (if has("is_valid") then .is_valid else .valid end)}]') || return 1
        if [[ "$installations" != "[]" ]]; then
            printf '%s\n' "$installations"
            return 0
        fi
        if ((attempt < 12)); then
            sleep 5
        fi
    done
    print_error "Detection queued but no installation found within 12 checks; inspect hPanel or use api to check again (do not reinstall)." >&2
    return 1
}

# Read-only fleet inventory, onboarding plan and drift check (hosting_fleet.py).
# Module names avoid the credential ignore pattern 'hostinger_*' in .gitignore.
fleet_command() {
    local subcommand="${1:-help}"
    local engine="${SCRIPT_DIR}/hosting_fleet.py"
    local discovery_lib="${SCRIPT_DIR}/aidevops-cli/repo-discovery-lib.sh"
    local status=0
    local argument=""
    local offline=0

    case "$subcommand" in
    inventory)
        shift
        for argument in "$@"; do
            [[ "$argument" == "--api-response" ]] && offline=1
        done
        # Inject the token from the secret store without exposing it.
        if [[ "$offline" -eq 0 && -z "${HOSTINGER_API_TOKEN:-}" ]] &&
            command -v aidevops >/dev/null 2>&1 &&
            aidevops secret check HOSTINGER_API_TOKEN >/dev/null 2>&1; then
            aidevops secret HOSTINGER_API_TOKEN -- python3 "$engine" inventory "$@" || status=$?
            return "$status"
        fi
        python3 "$engine" inventory "$@" || status=$?
        return "$status"
        ;;
    plan | drift | ready | move)
        shift
        python3 "$engine" "$subcommand" --discovery-lib "$discovery_lib" "$@" || status=$?
        return "$status"
        ;;
    privacy-sync | provision)
        shift
        python3 "$engine" "$subcommand" "$@" || status=$?
        return "$status"
        ;;
    help | -h | --help)
        echo "Usage: $0 fleet <inventory|plan|drift|ready|provision|move|privacy-sync> [options]"
        echo ""
        echo "  inventory [--username U] [--discover-networks --ssh ALIAS] [--network-map FILE]"
        echo "      GET-only website inventory; groups shared roots; optional read-only"
        echo "      SSH 'wp site list' adds multisite blogs that have no panel entry"
        echo "  plan  [--owner ORG] [--owner-exception DOMAIN=OWNER]... [--site-repo HOST=REPO]..."
        echo "        [--ignore DOMAIN]... [--config FILE]"
        echo "      Write a content-hashed onboarding plan (no mutations)"
        echo "  drift [plan options] [--json] [--fail-on-drift]"
        echo "      Compare hosting, repos.json and canonical layout (exit 3 on drift)"
        echo "  ready [plan options] [--worker-evidence] [--json] [--fail-on-not-ready]"
        echo "      Read-only configured readiness per repo: private remote, owner, push,"
        echo "      default-branch heads, effective project config, Pulse/maintenance,"
        echo "      gh auth; writes a private receipt (exit 4 if not all ready)"
        echo "  provision [--plan FILE] [--site DOMAIN]... [--apply --plan-sha256 HASH]"
        echo "      Preview (default) or apply the saved plan: create/adopt private repo,"
        echo "      clone, native init, push + issue + PR (never merges); resumable,"
        echo "      append-only private receipt (exit 5 if any repository failed)"
        echo "  move --site DOMAIN... [plan options] [--apply --confirm HASH]"
        echo "      Preview named misplaced sites (read-only). Apply: snapshot maintenance/"
        echo "      Pulse, pause, scoped native migrate-layout plan + apply, restore both"
        echo "      by slug; partial moves stay paused (exit 6 on failure)"
        echo "  move --restore SNAPSHOT"
        echo "      Restore a paused move once every repository moved (or none did)"
        echo "  privacy-sync [--inventory FILE] [--config FILE]"
        echo "      Offline sync to the local private entity guard (counts only)"
        echo "      Also runs automatically after inventory"
        echo ""
        echo "Fleet config (optional, 0600): ~/.config/aidevops/hosting-fleet.json"
        echo "  {\"owner\": ORG, \"owner_exceptions\": {DOMAIN: OWNER},"
        echo "   \"site_repos\": {HOST: REPO}, \"ignore\": [DOMAIN]}  -- flags add to it"
        echo "Private output: ~/.aidevops/.agent-workspace/work/hostinger-fleet/"
        echo "Details: services/hosting/hostinger.md 'Fleet inventory and drift'"
        return 0
        ;;
    *)
        print_error "Unknown fleet command: $subcommand"
        return 1
        ;;
    esac
}

# hPanel cron jobs via the Hostinger API (hosting_cron.py). SSH has no crontab on
# shared hosting, so this is the supported way to inspect and change jobs.
cron_command() {
    local subcommand="${1:-help}"
    local engine="${SCRIPT_DIR}/hosting_cron.py"
    local status=0

    case "$subcommand" in
    list | create | delete | output)
        if [[ -z "${HOSTINGER_API_TOKEN:-}" ]] &&
            command -v aidevops >/dev/null 2>&1 &&
            aidevops secret check HOSTINGER_API_TOKEN >/dev/null 2>&1; then
            aidevops secret HOSTINGER_API_TOKEN -- python3 "$engine" "$@" || status=$?
            return "$status"
        fi
        python3 "$engine" "$@" || status=$?
        return "$status"
        ;;
    help | -h | --help)
        echo "Usage: $0 cron <list|create|delete|output> --ssh ALIAS [options]"
        echo ""
        echo "  list   --ssh ALIAS [--json]"
        echo "  create --ssh ALIAS --time 'CRON' --command 'CMD' [--apply]"
        echo "  delete --ssh ALIAS --uid UID [--apply]"
        echo "  output --ssh ALIAS --uid UID"
        echo ""
        echo "create/delete preview unless --apply is given. Each change snapshots the"
        echo "job list (0600) to ~/.aidevops/.agent-workspace/work/hostinger-cron/ and"
        echo "prints the list afterwards. A failed change lists live jobs; never retry blindly."
        echo "Details: services/hosting/hostinger-wordpress-cron.md"
        return 0
        ;;
    *)
        print_error "Unknown cron command: $subcommand"
        return 1
        ;;
    esac
}

# Read-only evidence, delivered over stdin without remote temporary files.
_image_libs_remote_script() {
    cat <<'REMOTE'
cfg=/opt/alt/alt-ImageMagick/etc/ImageMagick-7
trace() {
    printf '$'; printf ' %q' "$@"; printf '\n'
    return 0
}
run() {
    trace "$@" >&2
    "$@"
    return 0
}
debuglink() {
    local binary="$1"
    if command -v readelf >/dev/null 2>&1; then
        trace readelf --string-dump=.gnu_debuglink "$binary" >&2
        readelf --string-dump=.gnu_debuglink "$binary" | grep -o '[^ ]*\.debug' | sort -u
    else
        printf '(heuristic: whole-file debug names)\n' >&2
        printf '$ grep -ao [A-Za-z0-9._+~-]*\\.debug %s | sort -u\n' "$binary" >&2
        grep -ao '[A-Za-z0-9._+~-]*\.debug' "$binary" | sort -u
    fi
    return 0
}
run date -u '+checked: %Y-%m-%d %H:%M:%S UTC'
printf '$ uname -r\nkernel: %s\n' "$(uname -r)"
run /usr/bin/gs --version
debuglink /usr/bin/gs
run readlink /usr/lib64/libgs.so.9
debuglink /usr/lib64/libgs.so.9
run stat -L -c '%n built %y changed %z' /usr/bin/gs /usr/lib64/libgs.so.9 "$cfg/policy.xml" "$cfg/delegates.xml"
policy_php=
for php in /opt/alt/php[0-9]*/usr/bin/php; do
    [ -x "$php" ] || continue
    policy_php="$php"
    info=$(run "$php" -r 'if (extension_loaded("imagick")) { $v = Imagick::getVersion(); echo PHP_VERSION, " | ", $v["versionString"], " | imagick ", phpversion("imagick"), PHP_EOL; } else { echo PHP_VERSION, " | imagick not loaded", PHP_EOL; }')
    so="${php%/bin/php}/lib64/php/modules/imagick.so"
    release=
    if [ -f "$so" ]; then release=$(debuglink "$so"); fi
    printf '%s: %s | %s\n' "$php" "$info" "$release"
done
core_found=false
for core in /opt/alt/alt-ImageMagick/usr/lib64/libMagickCore-7.*.so.*; do
    [ -f "$core" ] || continue
    debuglink "$core"
    core_found=true
    break
done
if [ "$core_found" = false ]; then printf 'ImageMagick core: unavailable\n'; fi
if [ -n "$policy_php" ]; then
    printf 'Package policy rules (not effective account policy): %s\n' "$cfg/policy.xml"
    run "$policy_php" -r 'if (!class_exists("DOMDocument")) { echo "policy: DOM unavailable", PHP_EOL; exit; } $d = new DOMDocument(); if ($d->load($argv[1], LIBXML_NONET)) { foreach ($d->getElementsByTagName("policy") as $p) { echo $d->saveXML($p), PHP_EOL; } }' "$cfg/policy.xml"
else
    printf 'policy: PHP unavailable\n'
fi
if [ -n "$policy_php" ]; then
    run "$policy_php" -r 'if (!class_exists("DOMDocument")) { echo "delegates: DOM unavailable", PHP_EOL; exit; } $d = new DOMDocument(); if ($d->load($argv[1], LIBXML_NONET)) { foreach ($d->getElementsByTagName("delegate") as $p) { if (preg_match("/\\bgs\\b/", $p->getAttribute("command"))) { echo $d->saveXML($p), PHP_EOL; } } }' "$cfg/delegates.xml"
fi
run command -v gs
REMOTE
    _image_libs_workers_script
    return 0
}

_image_libs_workers_script() {
    cat <<'REMOTE'
workers() {
    local pid="" exe="" maps=""
    printf '$ pgrep -u "$(id -u)" lsphp; readlink /proc/PID/exe; grep imagick.so /proc/PID/maps | sort | uniq -c\n'
    for pid in $(pgrep -u "$(id -u)" lsphp); do
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || exe='executable unavailable (worker exited or access denied)'
        maps=$(grep -o '/[^ ]*imagick\.so\( (deleted)\)\?' "/proc/$pid/maps" 2>/dev/null | sort -u)
        if [ -z "$maps" ]; then
            maps='imagick mapping absent or unreadable'
        fi
        printf '%s | %s\n' "$exe" "$maps"
    done | sort | uniq -c
    return 0
}
workers
exit 0
REMOTE
    return 0
}

_image_libs_vendor() {
    local el="$1"
    printf '\nCloudLinux alt-ImageMagick (%s)\n' "${el:-unknown OS}"
    printf '$ curl -sS --fail --connect-timeout 5 --max-time 20 https://changelog.cloudlinux.com/api/packages/alt-ImageMagick | jq (newest stable/beta for %s)\n' "$el"
    if [[ ! "$el" =~ ^el[0-9]+$ ]] || ! curl -sS --fail --connect-timeout 5 --max-time 20 \
        https://changelog.cloudlinux.com/api/packages/alt-ImageMagick 2>/dev/null |
        jq -er --arg el "$el" '[.versions[] | select(.os | index($el))] | sort_by(.released_at) | reverse
            | (map(select(.channels | index("stable")))[0]), (map(select(.channels | index("beta")))[0])
            | select(. != null) | "\(.channels | join(",")) \(.version) \(.released_at[0:10]) is_security=\(.is_security)"' 2>/dev/null; then
        printf 'Vendor lookup unavailable (unknown OS, missing curl/jq, timeout or invalid response)\n'
    fi
    printf 'Ghostscript: compare the installed debug-link release with Red Hat VEX; see hostinger.md: Ghostscript fix status.\n'
    return 0
}

image_libs_command() {
    local alias="" vendor=false output="" el="" status=0
    while [[ $# -gt 0 ]]; do
        local option="$1"
        local value="${2:-}"
        case "$option" in
        --ssh)
            if [[ $# -lt 2 ]]; then break; fi
            alias="$value"
            shift 2
            ;;
        --vendor) vendor=true; shift ;;
        *) break ;;
        esac
    done
    if [[ $# -ne 0 || ! "$alias" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$ ]]; then
        printf 'Usage: image-libs --ssh ALIAS [--vendor]\n' >&2
        return 1
    fi
    # Capture stderr too: SSH diagnostics can contain the remote account name.
    output=$(_image_libs_remote_script | ssh -o BatchMode=yes -o ConnectTimeout=15 "$alias" 'bash -s' 2>&1) || status=$?
    # Retry matches so IDs sharing a delimiter are all masked (BSD/GNU sed).
    printf '%s\n' "$output" | sed -E "s@(/home|/Users)/[^/[:space:]'\"]+@~@g; s/[[:alnum:]_.-]+@/@/g" |
        sed -E -e ':mask' -e 's/(^|[^[:alnum:]_])u[0-9]{6,}([^[:alnum:]_]|$)/\1[account]\2/g' -e 't mask'
    if [[ "$vendor" = true && "$status" -eq 0 ]]; then
        el=$(printf '%s\n' "$output" | sed -nE 's/^kernel: .*\.(el[0-9]+)([._-].*)?$/\1/p')
        _image_libs_vendor "$el"
    fi
    return "$status"
}

# origin-block (GH#37295): is LiteSpeed's per-client bot protection refusing
# this machine's address, or is the site down? Read-only and bounded: at most
# two public requests and two host-side direct requests per check. No IP
# addresses are printed. Details: services/hosting/hostinger.md
# "One client address refused at the origin".
readonly ORIGIN_DENY_MARKER="Access to this resource on the server is denied"
readonly ORIGIN_CHALLENGE_MARKER="/.lsrecap/"
readonly ORIGIN_PROBE_AGENT="aidevops-origin-block/1"
readonly ORIGIN_STATIC_PATH="/robots.txt"
readonly ORIGIN_UNAVAILABLE="unavailable"

# Map a status code and body markers to one state word.
_origin_state() {
    local code="$1"
    local denied="$2"
    local challenged="$3"
    if [[ "$denied" == "1" ]]; then
        printf 'denied'
    elif [[ "$challenged" == "1" ]]; then
        printf 'challenge'
    elif [[ "$code" == "408" ]]; then
        printf 'timeout'
    elif [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
        printf 'ok'
    elif [[ "$code" == "000" ]]; then
        printf 'unreachable'
    else
        printf 'error'
    fi
    return 0
}

# One public request from this machine; prints "<code> <state>".
_origin_probe_public() {
    local url="$1"
    local body_file=""
    local code="000"
    local denied=0
    local challenged=0
    body_file=$(mktemp) || return 1
    code=$(curl -sS -m 20 -A "$ORIGIN_PROBE_AGENT" -o "$body_file" -w '%{http_code}' "$url" 2>/dev/null) || code="000"
    grep -qF "$ORIGIN_DENY_MARKER" "$body_file" && denied=1
    grep -qF "$ORIGIN_CHALLENGE_MARKER" "$body_file" && challenged=1
    rm -f "$body_file"
    printf '%s %s\n' "$code" "$(_origin_state "$code" "$denied" "$challenged")"
    return 0
}

# Host-side direct requests to the origin, bypassing Cloudflare. The host's
# egress IPv4 comes from Cloudflare's /cdn-cgi/trace (answered at the edge,
# so it works during a block) and never leaves the host.
_origin_block_remote_script() {
    cat <<'REMOTE'
host=""
ip=""
# The first argument is the host; the rest are paths.
for path in "$@"; do
    if [ -z "$host" ]; then
        host="$path"
        ip=$(curl -4 -s -m 10 "https://$host/cdn-cgi/trace" | sed -n 's/^ip=//p')
        continue
    fi
    if [ -z "$ip" ]; then
        printf 'noip 0 0\n'
        continue
    fi
    f=$(mktemp)
    code=$(curl -sk -m 20 -A aidevops-origin-block/1 -o "$f" -w '%{http_code}' --resolve "$host:443:$ip" "https://$host$path" 2>/dev/null) || code=000
    d=0; c=0
    grep -qF "Access to this resource on the server is denied" "$f" && d=1
    grep -qF "/.lsrecap/" "$f" && c=1
    rm -f "$f"
    printf '%s %s %s\n' "$code" "$d" "$c"
done
exit 0
REMOTE
    return 0
}

# Prints one "<code> <state>" line per path for the direct requests.
_origin_probe_direct() {
    local alias="$1"
    local host="$2"
    shift 2
    local remote_cmd="bash -s --"
    local arg=""
    local line=""
    for arg in "$host" "$@"; do
        remote_cmd+=" $(printf '%q' "$arg")"
    done
    _origin_block_remote_script | ssh -o BatchMode=yes -o ConnectTimeout=15 "$alias" "$remote_cmd" 2>/dev/null |
        while read -r code denied challenged; do
            if [[ "$code" == "noip" ]]; then
                printf '%s %s\n' "-" "$ORIGIN_UNAVAILABLE"
                continue
            fi
            line="$code $(_origin_state "$code" "$denied" "$challenged")"
            printf '%s\n' "$line"
        done
    return 0
}

_origin_is_refusal() {
    local state="$1"
    [[ "$state" == "denied" || "$state" == "challenge" || "$state" == "timeout" ]]
    return $?
}

_origin_both_ok() {
    local first="$1"
    local second="$2"
    [[ "$first" == "ok" ]] || return 1
    [[ "$second" == "ok" ]]
    return $?
}

# Verdict from the four states; prints "<exit> <verdict>: <advice>".
_origin_verdict() {
    local pub_static="$1"
    local pub_dynamic="$2"
    local dir_static="$3"
    local dir_dynamic="$4"
    if ! _origin_is_refusal "$pub_static" && ! _origin_is_refusal "$pub_dynamic"; then
        if _origin_both_ok "$pub_static" "$pub_dynamic"; then
            printf '0 ok: no refusal from this address\n'
        elif _origin_both_ok "$dir_static" "$dir_dynamic"; then
            printf '13 inconclusive: the public path fails without a LiteSpeed refusal while the origin answers directly; check Cloudflare and DNS\n'
        else
            printf '12 site-error: no LiteSpeed refusal, but the site answers with errors; debug the site\n'
        fi
        return 0
    fi
    if _origin_both_ok "$dir_static" "$dir_dynamic"; then
        printf '10 refused-client: the origin refuses this machine'\''s address (LiteSpeed bot protection); the site is up for other visitors. Stop scripted requests from this address (each unsolved challenge extends the block) and wait with --wait\n'
    elif _origin_is_refusal "$dir_static" || _origin_is_refusal "$dir_dynamic"; then
        printf '11 refused-origin: the origin refuses its own host too; pause bulk jobs on the account and check hPanel resource usage\n'
    elif [[ "$dir_static" == "skipped" ]]; then
        printf '10 refused: the origin refuses this address; add --ssh ALIAS to confirm the site is up\n'
    else
        printf '13 inconclusive: the public request was refused, but the direct check did not answer cleanly\n'
    fi
    return 0
}

# One check: report lines on stdout; returns the verdict's exit code.
_origin_check_once() {
    local host="$1"
    local alias="$2"
    local dynamic_path=""
    local pub_static="" pub_dynamic="" direct="" dir_static="skipped" dir_dynamic="skipped"
    local colo="" result="" code=0

    dynamic_path="/?aidevops-origin-probe=$(date +%s)$$"
    colo=$(curl -sS -m 10 "https://$host/cdn-cgi/trace" 2>/dev/null | sed -n 's/^colo=//p') || colo=""
    if [[ -n "$colo" ]]; then
        printf 'origin-block %s (Cloudflare colo %s)\n' "$host" "$colo"
    else
        printf 'origin-block %s (no Cloudflare trace: direct and public paths are the same)\n' "$host"
    fi
    pub_static=$(_origin_probe_public "https://$host$ORIGIN_STATIC_PATH") || return 13
    printf 'public  static   %s %s\n' "$ORIGIN_STATIC_PATH" "$pub_static"
    # A denied static file means a hard block; a dynamic request would only
    # count as one more failed challenge.
    if _origin_is_refusal "${pub_static#* }" || [[ "${pub_static#* }" == "unreachable" ]]; then
        pub_dynamic="- skipped"
    else
        pub_dynamic=$(_origin_probe_public "https://$host$dynamic_path") || return 13
    fi
    printf 'public  dynamic  /?aidevops-origin-probe=… %s\n' "$pub_dynamic"
    if [[ -n "$alias" ]]; then
        direct=$(_origin_probe_direct "$alias" "$host" "$ORIGIN_STATIC_PATH" "$dynamic_path")
        dir_static=$(printf '%s\n' "$direct" | sed -n '1s/^[^ ]* //p')
        dir_dynamic=$(printf '%s\n' "$direct" | sed -n '2s/^[^ ]* //p')
        printf 'direct  static   %s\n' "$(printf '%s\n' "$direct" | sed -n 1p)"
        printf 'direct  dynamic  %s\n' "$(printf '%s\n' "$direct" | sed -n 2p)"
        [[ -n "$dir_static" ]] || dir_static="$ORIGIN_UNAVAILABLE"
        [[ -n "$dir_dynamic" ]] || dir_dynamic="$ORIGIN_UNAVAILABLE"
    fi
    result=$(_origin_verdict "${pub_static#* }" "${pub_dynamic#* }" "$dir_static" "$dir_dynamic")
    code="${result%% *}"
    printf 'verdict %s\n' "${result#* }"
    return "$code"
}

origin_block_command() {
    local host="" alias="" wait_limit=0 interval=60 waited=0 status=0
    local usage='Usage: origin-block HOST [--ssh ALIAS] [--wait SECONDS] [--interval SECONDS]'
    while [[ $# -gt 0 ]]; do
        local option="$1"
        local value="${2:-}"
        case "$option" in
        --ssh | --wait | --interval)
            if [[ $# -lt 2 ]]; then
                printf '%s\n' "$usage" >&2
                return 1
            fi
            case "$option" in
            --ssh) alias="$value" ;;
            --wait) wait_limit="$value" ;;
            --interval) interval="$value" ;;
            esac
            shift 2
            ;;
        -*)
            printf '%s\n' "$usage" >&2
            return 1
            ;;
        *)
            [[ -z "$host" ]] || { printf '%s\n' "$usage" >&2; return 1; }
            host="$option"
            shift
            ;;
        esac
    done
    if [[ ! "$host" =~ ^[[:alnum:]]([[:alnum:].-]*[[:alnum:]])?$ || "$host" == *..* ]] ||
        [[ -n "$alias" && ! "$alias" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$ ]] ||
        [[ ! "$wait_limit" =~ ^[0-9]+$ || ! "$interval" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$usage" >&2
        return 1
    fi
    ((interval >= 30)) || interval=30
    while :; do
        status=0
        _origin_check_once "$host" "$alias" || status=$?
        if ((status == 0 || waited >= wait_limit)); then
            return "$status"
        fi
        printf 'waiting %ss (%ss of %ss)\n' "$interval" "$waited" "$wait_limit"
        sleep "$interval"
        waited=$((waited + interval))
    done
    return "$status"
}
main() {
    # Assign positional parameters to local variables
    local command="${1:-help}"
    local param2="${2:-}"
    local param3="${3:-}"

    # Main command handler
    case "$command" in
    "list")
        list_sites
        ;;
    "connect")
        if [[ -z "$param2" ]]; then
            print_error "Usage: connect [site]"
            return 1
        fi
        connect_site "$param2"
        ;;
    "exec")
        if [[ -z "$param2" || -z "$param3" ]]; then
            print_error "Usage: exec [site] [command]"
            return 1
        fi
        exec_on_site "$param2" "$param3"
        ;;
    "api")
        shift
        api_call "$@"
        return $?
        ;;
    "ssl-status")
        ssl_status "$param2"
        return $?
        ;;
    "wordpress-detect")
        wordpress_detect "$param2"
        return $?
        ;;
    "fleet")
        shift
        fleet_command "$@"
        return $?
        ;;
    "cron")
        shift
        cron_command "$@"
        return $?
        ;;
    "image-libs")
        shift
        image_libs_command "$@"
        return $?
        ;;
    "origin-block")
        shift
        origin_block_command "$@"
        return $?
        ;;
    "help"|"-h"|"--help"|"")
        echo "Hostinger Helper Script"
        echo "Usage: $0 [command] [options]"
        echo ""
        echo "Commands:"
        echo "  list              - List all configured sites"
        echo "  connect [site]    - Connect to site directory via SSH"
        echo "  exec [site] [cmd] - Execute command on site"
        echo "  api [METHOD] ENDPOINT [JSON] - Hostinger API call (token from secret store)"
        echo "  ssl-status DOMAIN - Read-only SSL status (resolves hosting username)"
        echo "  wordpress-detect DOMAIN - Scan account for WordPress; bounded installation lookup"
        echo "  fleet [cmd]       - Read-only fleet inventory, plan and drift ('fleet help')"
        echo "  cron [cmd]        - hPanel cron list/create/delete/output via API ('cron help')"
        echo "  image-libs --ssh ALIAS [--vendor] - Read-only Ghostscript/ImageMagick releases, policy and workers"
        echo "  origin-block HOST [--ssh ALIAS] [--wait SECONDS] [--interval SECONDS]"
        echo "                    - Is LiteSpeed refusing this address (403/reCAPTCHA/408) or is the site down?"
        echo "                      Exit 0 ok, 10 refused-client, 11 refused-origin, 12 site-error, 13 inconclusive"
        echo "  help                 - $HELP_SHOW_MESSAGE"
        echo ""
        echo "Examples:"
        echo "  $0 list"
        echo "  $0 connect example.com"
        echo "  $0 exec example.com 'ls -la'"
        echo "  $0 api api/hosting/v1/websites"
        echo "  $0 origin-block www.example.com --ssh hostinger --wait 900"
        echo "  $0 api PATCH api/hosting/v1/accounts/USER/websites/DOMAIN/php/version '{\"version\":\"8.5\"}'"
        ;;
    *)
        print_error "$ERROR_UNKNOWN_COMMAND $command"
        print_info "$HELP_USAGE_INFO"
        exit 1
        ;;
esac
return 0
}

# Run main function
main "$@"
