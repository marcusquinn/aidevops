#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# optimise-indexing-backups-helper.sh — safe local indexing/backup optimisation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

STATE_DIR="${AIDEVOPS_STATE_DIR:-${HOME}/.aidevops/state}"
LOG_DIR="${AIDEVOPS_LOG_DIR:-${HOME}/.aidevops/logs}"
CONFIG_DIR="${AIDEVOPS_CONFIG_DIR:-${HOME}/.aidevops/configs}"
STATE_FILE="${AIDEVOPS_OPTIMISE_STATE_FILE:-${STATE_DIR}/optimise-indexing-backups.json}"
LOG_FILE="${AIDEVOPS_OPTIMISE_LOG_FILE:-${LOG_DIR}/optimise-indexing-backups.log}"
REMINDER_DAYS="${AIDEVOPS_OPTIMISE_REMINDER_DAYS:-30}"
NOTIFY_INTERVAL_SECONDS="${AIDEVOPS_OPTIMISE_NOTIFY_INTERVAL_SECONDS:-86400}"

usage() {
cat <<'USAGE'
Usage: optimise-indexing-backups-helper.sh <macos|linux> <scan|apply|status|reminder> [flags]

Flags:
  --dry-run                 Recommend only (default for scan)
  --apply                   Apply safe user-owned changes
  --json                    Emit JSON for scan/status
  --format=human|toast|json Reminder output format
  --path DIR                Include an additional project/workspace root
  --include-backup-client N Record backup-client focus in output
  --skip-backup-client N    Record backup-client skip in output
  --no-notify               Do not send desktop notification for stale reminder

Commands default to safe dry-run behaviour and never require sudo.
USAGE
return 0
}

_now_epoch() {
    if [[ -n "${AIDEVOPS_OPTIMISE_NOW:-}" ]]; then
        printf '%s\n' "$AIDEVOPS_OPTIMISE_NOW"
        return 0
    fi
    date +%s
    return 0
}

_iso_now() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
    return 0
}

_ensure_dirs() {
    mkdir -p "$STATE_DIR" "$LOG_DIR" "$CONFIG_DIR"
    return 0
}

_log_run() {
    local platform="$1"
    local mode="$2"
    local applied="$3"
    local warnings="$4"
    _ensure_dirs
    printf '%s platform=%s mode=%s applied=%s warnings=%s\n' \
        "$(_iso_now)" "$platform" "$mode" "$applied" "$warnings" >>"$LOG_FILE"
    return 0
}

_json_escape() {
    local value="$1"
    python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$value"
    return 0
}

_state_value() {
    local platform="$1"
    local key="$2"
    if [[ ! -f "$STATE_FILE" ]] || ! command -v python3 >/dev/null 2>&1; then
        printf '0\n'
        return 0
    fi
    python3 - "$STATE_FILE" "$platform" "$key" <<'PY'
import json, sys
path, platform, key = sys.argv[1:4]
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}
entry = data.get(platform, {})
if not isinstance(entry, dict):
    entry = {}
value = entry.get(key, 0)
print(value if value not in (None, "") else 0)
PY
    return 0
}

_state_update() {
    local platform="$1"
    local last_success_at="$2"
    local last_mode="$3"
    local applied="$4"
    local warnings="$5"
    local notified_at="$6"
    _ensure_dirs
    python3 - "$STATE_FILE" "$platform" "$last_success_at" "$last_mode" "$applied" "$warnings" "$notified_at" <<'PY'
import json, os, sys
path, platform, success, mode, applied, warnings, notified = sys.argv[1:8]
try:
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}
entry = data.get(platform, {})
if not isinstance(entry, dict):
    entry = {}
if success != "-":
    entry["last_success_at"] = int(success)
if mode != "-":
    entry["last_mode"] = mode
if applied != "-":
    entry["last_applied_count"] = int(applied)
if warnings != "-":
    entry["last_warning_count"] = int(warnings)
entry["last_version"] = "1.0.0"
if notified != "-":
    entry["last_notified_at"] = int(notified)
data[platform] = entry
tmp = path + ".tmp"
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(data, handle, sort_keys=True, indent=2)
    handle.write("\n")
os.replace(tmp, path)
PY
    return 0
}

_platform_label() {
    local platform="$1"
    case "$platform" in
        macos) printf 'macOS' ;;
        linux) printf 'Linux' ;;
        *) printf '%s' "$platform" ;;
    esac
    return 0
}

_candidate_paths() {
    local platform="$1"
    case "$platform" in
        macos)
            printf '%s\n' \
                "${HOME}/Library/Caches" \
                "${HOME}/Library/Logs" \
                "${HOME}/Library/pnpm" \
                "${HOME}/.cache" \
                "${HOME}/.npm" \
                "${HOME}/.bun/install/cache" \
                "${HOME}/.cargo/registry" \
                "${HOME}/Library/Developer/CoreSimulator/Caches" \
                "${HOME}/Library/Developer/CoreSimulator/Devices" \
                "${HOME}/.aidevops/.agent-workspace" \
                "${HOME}/.aidevops/cache" \
                "${HOME}/.aidevops/logs" \
                "${HOME}/.aidevops/locks" \
                "${HOME}/.aidevops/agents-backups"
            ;;
        linux)
            printf '%s\n' \
                "${HOME}/.cache" \
                "${HOME}/.local/share/Trash" \
                "${HOME}/.npm" \
                "${HOME}/.pnpm-store" \
                "${HOME}/.cache/pip" \
                "${HOME}/.cargo/registry" \
                "${HOME}/.cargo/git" \
                "${HOME}/.aidevops/.agent-workspace" \
                "${HOME}/.aidevops/cache" \
                "${HOME}/.aidevops/logs" \
                "${HOME}/.aidevops/locks"
            ;;
    esac
    return 0
}

_project_patterns() {
    printf '%s\n' \
        '<repo-root>/**/node_modules/' \
        '<repo-root>/**/.next/' \
        '<repo-root>/**/.nuxt/' \
        '<repo-root>/**/.turbo/' \
        '<repo-root>/**/.vite/' \
        '<repo-root>/**/dist/' \
        '<repo-root>/**/build/' \
        '<repo-root>/**/coverage/' \
        '<repo-root>/**/target/' \
        '<repo-root>/**/__pycache__/' \
        '<repo-root>/**/.pytest_cache/' \
        '<repo-root>/**/.mypy_cache/' \
        '<repo-root>/**/.ruff_cache/' \
        '<repo-root>/**/.tox/' \
        '<repo-root>/**/.venv/' \
        '<repo-root>/**/venv/' \
        '<repo-root>/**/.git/worktrees/'
    return 0
}

_tool_status_line() {
    local tool="$1"
    local label="$2"
    if command -v "$tool" >/dev/null 2>&1; then
        printf 'available:%s\n' "$label"
    else
        printf 'missing:%s\n' "$label"
    fi
    return 0
}

_detected_systems() {
    local platform="$1"
    case "$platform" in
        macos)
            _tool_status_line mdutil Spotlight
            _tool_status_line tmutil TimeMachine
            if [[ -d /Library/Backblaze.bzpkg ]]; then
                printf 'available:Backblaze\n'
            else
                printf 'missing:Backblaze\n'
            fi
            ;;
        linux)
            _tool_status_line tracker3 Tracker3
            _tool_status_line balooctl Baloo
            _tool_status_line recoll Recoll
            _tool_status_line updatedb Locate
            _tool_status_line restic restic
            _tool_status_line borg borg
            _tool_status_line kopia kopia
            _tool_status_line duplicity duplicity
            _tool_status_line rsnapshot rsnapshot
            _tool_status_line rclone rclone
            _tool_status_line timeshift Timeshift
            ;;
    esac
    return 0
}

_emit_scan_human() {
    local platform="$1"
    local apply_mode="$2"
    local label
    label="$(_platform_label "$platform")"
    printf '%s indexing/backup optimisation (%s)\n' "$label" "$apply_mode"
    printf 'State: %s\n' "$STATE_FILE"
    printf 'Log: %s\n\n' "$LOG_FILE"
    printf 'Detected systems:\n'
    _detected_systems "$platform" | while IFS=: read -r status name; do
        printf '%s\n' "- ${name}: ${status}"
    done
    printf '\nRecommended generated/cache exclusions:\n'
    _candidate_paths "$platform" | while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        printf '%s\n' "- ${path}"
    done
    printf '\nProject patterns:\n'
    _project_patterns | while IFS= read -r pattern; do
        printf '%s\n' "- ${pattern}"
    done
    printf '\nUnsafe exclusions avoided: home directory, source trees, Documents, Desktop, Downloads, .ssh, .gnupg, broad config directories.\n'
    return 0
}

_emit_scan_json() {
    local platform="$1"
    local mode="$2"
    if ! command -v jq >/dev/null 2>&1; then
        print_error "--json requires jq"
        return 1
    fi
    local candidates systems patterns
    candidates="$(_candidate_paths "$platform" | jq -R . | jq -s .)"
    systems="$(_detected_systems "$platform" | jq -R 'split(":") | {status: .[0], name: .[1]}' | jq -s .)"
    patterns="$(_project_patterns | jq -R . | jq -s .)"
    jq -n \
        --arg platform "$platform" \
        --arg mode "$mode" \
        --arg state_file "$STATE_FILE" \
        --arg log_file "$LOG_FILE" \
        --argjson candidates "$candidates" \
        --argjson systems "$systems" \
        --argjson patterns "$patterns" \
        '{platform:$platform, mode:$mode, state_file:$state_file, log_file:$log_file, detected_systems:$systems, candidate_paths:$candidates, project_patterns:$patterns, unsafe_exclusions:["home directory","source trees","Documents","Desktop","Downloads",".ssh",".gnupg","broad config directories"]}'
    return 0
}

_apply_macos_safe() {
    local applied=0
    local path
    while IFS= read -r path; do
        [[ -d "$path" && -w "$path" ]] || continue
        if [[ ! -e "$path/.metadata_never_index" ]]; then
            : >"$path/.metadata_never_index"
            applied=$((applied + 1))
        fi
    done < <(_candidate_paths macos)
    printf '%d\n' "$applied"
    return 0
}

_apply_linux_safe() {
    local exclude_file="${CONFIG_DIR}/optimise-indexing-backups-excludes.txt"
    _ensure_dirs
    {
        printf '# aidevops generated indexing/backup excludes\n'
        _candidate_paths linux
        _project_patterns
    } >"$exclude_file"
    printf '1\n'
    return 0
}

_cmd_scan() {
    local platform="$1"
    shift
    local subcommand=""
    if [[ "$#" -gt 0 ]]; then
        subcommand="$1"
        if [[ "$subcommand" == "status" ]]; then
            shift
            _cmd_status "$platform" "$@"
            return $?
        fi
        if [[ "$subcommand" == "reminder" ]]; then
            shift
            _cmd_reminder "$platform" "$@"
            return $?
        fi
    fi
    local mode="dry-run"
    local json="false"
    local arg
    while [[ "$#" -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --apply|apply) mode="apply" ;;
            --dry-run) mode="dry-run" ;;
            --json) json="true" ;;
            --path|--include-backup-client|--skip-backup-client) [[ "$#" -gt 1 ]] && shift ;;
            --path=*|--include-backup-client=*|--skip-backup-client=*) ;;
            *) ;;
        esac
        shift || true
    done
    local applied="0"
    if [[ "$mode" == "apply" ]]; then
        case "$platform" in
            macos) applied="$(_apply_macos_safe)" ;;
            linux) applied="$(_apply_linux_safe)" ;;
        esac
    fi
    _log_run "$platform" "$mode" "$applied" "0"
    _state_update "$platform" "$(_now_epoch)" "$mode" "$applied" "0" "-"
    if [[ "$json" == "true" ]]; then
        _emit_scan_json "$platform" "$mode"
    else
        _emit_scan_human "$platform" "$mode"
    fi
    return 0
}

_cmd_status() {
    local platform="$1"
    local json="false"
    local arg
    shift
    while [[ "$#" -gt 0 ]]; do
        arg="$1"
        if [[ "$arg" == "--json" ]]; then
            json="true"
        fi
        shift
    done
    local success notified label
    success="$(_state_value "$platform" last_success_at)"
    notified="$(_state_value "$platform" last_notified_at)"
    label="$(_platform_label "$platform")"
    if [[ "$json" == "true" ]]; then
        printf '{"platform":%s,"last_success_at":%s,"last_notified_at":%s,"state_file":%s}\n' \
            "$(_json_escape "$platform")" "$success" "$notified" "$(_json_escape "$STATE_FILE")"
    else
        printf '%s optimisation status\n' "$label"
        printf 'last_success_at=%s\n' "$success"
        printf 'last_notified_at=%s\n' "$notified"
        printf 'state_file=%s\n' "$STATE_FILE"
    fi
    return 0
}

_is_stale() {
    local platform="$1"
    local now success age limit
    now="$(_now_epoch)"
    success="$(_state_value "$platform" last_success_at)"
    limit=$((REMINDER_DAYS * 86400))
    if [[ "$success" == "0" ]]; then
        return 0
    fi
    age=$((now - success))
    [[ "$age" -ge "$limit" ]] && return 0
    return 1
}

_maybe_notify() {
    local platform="$1"
    local no_notify="$2"
    [[ "$no_notify" == "true" ]] && return 0
    local now notified age label command_name
    now="$(_now_epoch)"
    notified="$(_state_value "$platform" last_notified_at)"
    age=$((now - notified))
    [[ "$notified" != "0" && "$age" -lt "$NOTIFY_INTERVAL_SECONDS" ]] && return 0
    label="$(_platform_label "$platform")"
    command_name="/optimise-${platform}-indexing-backups"
    if [[ "$platform" == "macos" ]] && command -v osascript >/dev/null 2>&1 && [[ -z "${AIDEVOPS_HEADLESS:-}" ]]; then
        osascript -e "display notification \"Run ${command_name}\" with title \"${label} indexing/backup optimisation stale\"" >/dev/null 2>&1 || true
    elif [[ "$platform" == "linux" ]] && command -v notify-send >/dev/null 2>&1 && [[ -z "${AIDEVOPS_HEADLESS:-}" ]]; then
        notify-send "${label} indexing/backup optimisation stale" "Run ${command_name}" >/dev/null 2>&1 || true
    fi
    _state_update "$platform" "-" "reminder" "-" "-" "$now"
    return 0
}

_cmd_reminder() {
    local platform="$1"
    shift
    local format="human"
    local no_notify="false"
    local arg
    while [[ "$#" -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --format=*) format="${arg#--format=}" ;;
            --format)
                if [[ "$#" -gt 1 ]]; then
                    shift
                    arg="$1"
                    format="$arg"
                else
                    format="human"
                fi
                ;;
            --no-notify) no_notify="true" ;;
        esac
        shift || true
    done
    if ! _is_stale "$platform"; then
        [[ "$format" == "json" ]] && printf '{"stale":false,"platform":%s}\n' "$(_json_escape "$platform")"
        return 0
    fi
    _maybe_notify "$platform" "$no_notify"
    local label command_name
    label="$(_platform_label "$platform")"
    command_name="/optimise-${platform}-indexing-backups"
    case "$format" in
        toast) printf '[WARN] %s indexing/backup optimisation is stale — run %s\n' "$label" "$command_name" ;;
        json) printf '{"stale":true,"platform":%s,"command":%s}\n' "$(_json_escape "$platform")" "$(_json_escape "$command_name")" ;;
        *) printf '%s indexing/backup optimisation is stale. Run %s.\n' "$label" "$command_name" ;;
    esac
    return 0
}

main() {
    local platform=""
    local command_name="scan"
    local arg=""
    if [[ "$#" -gt 0 ]]; then
        arg="$1"
        platform="$arg"
        shift
    fi
    if [[ "$#" -gt 0 ]]; then
        arg="$1"
        command_name="$arg"
        shift
    fi
    if [[ -z "$platform" || "$platform" == "help" || "$platform" == "--help" ]]; then
        usage
        return 0
    fi
    case "$platform" in
        macos|linux) ;;
        *) print_error "platform must be macos or linux"; return 2 ;;
    esac
    case "$command_name" in
        scan) _cmd_scan "$platform" "$@" ;;
        apply) _cmd_scan "$platform" --apply "$@" ;;
        status) _cmd_status "$platform" "$@" ;;
        reminder) _cmd_reminder "$platform" "$@" ;;
        help|--help) usage ;;
        *) print_error "unknown command: $command_name"; return 2 ;;
    esac
    return 0
}

main "$@"
