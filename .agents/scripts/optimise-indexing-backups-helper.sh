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
BACKBLAZE_BZINFO="${AIDEVOPS_BACKBLAZE_BZINFO:-/Library/Backblaze.bzpkg/bzdata/bzinfo.xml}"
BACKBLAZE_BZDATA="${AIDEVOPS_BACKBLAZE_BZDATA:-/Library/Backblaze.bzpkg/bzdata}"
BACKBLAZE_STALE_HOURS="${AIDEVOPS_BACKBLAZE_STALE_HOURS:-48}"
PLATFORM_WINDOWS="windows"

usage() {
cat <<'USAGE'
Usage: optimise-indexing-backups-helper.sh <macos|linux|windows> <scan|apply|status|reminder|health> [flags]

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
Native Windows support is limited and recommendation-first; WSL2 uses linux.
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
        windows) printf 'Windows' ;;
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
                "${HOME}/.bun" \
                "${HOME}/.rustup" \
                "${HOME}/.cargo/registry" \
                "${HOME}/.lmstudio" \
                "${HOME}/.local/share/opencode/snapshot" \
                "${HOME}/.local/share/opencode/storage" \
                "${HOME}/Library/Group Containers/HUAQ24HBR6.dev.orbstack" \
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
                "${HOME}/.bun" \
                "${HOME}/.rustup" \
                "${HOME}/.lmstudio" \
                "${HOME}/.local/share/opencode/snapshot" \
                "${HOME}/.local/share/opencode/storage" \
                "${HOME}/.aidevops/.agent-workspace" \
                "${HOME}/.aidevops/cache" \
                "${HOME}/.aidevops/logs" \
                "${HOME}/.aidevops/locks"
            ;;
        windows)
            printf '%s\n' \
                "%LOCALAPPDATA%\\Temp\\" \
                "%LOCALAPPDATA%\\npm-cache\\" \
                "%LOCALAPPDATA%\\pnpm\\store\\" \
                "%LOCALAPPDATA%\\pip\\Cache\\" \
                "%LOCALAPPDATA%\\Microsoft\\Windows\\INetCache\\" \
                "%USERPROFILE%\\.cache\\" \
                "%USERPROFILE%\\.npm\\" \
                "%USERPROFILE%\\.pnpm-store\\" \
                "%USERPROFILE%\\.cargo\\registry\\" \
                "%USERPROFILE%\\.cargo\\git\\" \
                "%USERPROFILE%\\.aidevops\\.agent-workspace\\" \
                "%USERPROFILE%\\.aidevops\\cache\\" \
                "%USERPROFILE%\\.aidevops\\logs\\" \
                "%USERPROFILE%\\.aidevops\\locks\\"
            ;;
    esac
    return 0
}

_project_patterns() {
    local platform="posix"
    if [[ "$#" -gt 0 ]]; then
        platform="$1"
    fi
    if [[ "$platform" == "$PLATFORM_WINDOWS" ]]; then
        printf '%s\n' \
            "<repo-root>\\**\\node_modules\\" \
            "<repo-root>\\**\\.next\\" \
            "<repo-root>\\**\\.nuxt\\" \
            "<repo-root>\\**\\.turbo\\" \
            "<repo-root>\\**\\.vite\\" \
            "<repo-root>\\**\\dist\\" \
            "<repo-root>\\**\\build\\" \
            "<repo-root>\\**\\coverage\\" \
            "<repo-root>\\**\\target\\" \
            "<repo-root>\\**\\__pycache__\\" \
            "<repo-root>\\**\\.pytest_cache\\" \
            "<repo-root>\\**\\.mypy_cache\\" \
            "<repo-root>\\**\\.ruff_cache\\" \
            "<repo-root>\\**\\.tox\\" \
            "<repo-root>\\**\\.venv\\" \
            "<repo-root>\\**\\venv\\" \
            "<repo-root>\\**\\.git\\worktrees\\"
        return 0
    fi
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
        windows)
            if command -v powershell.exe >/dev/null 2>&1 || command -v pwsh >/dev/null 2>&1; then
                printf 'available:PowerShell\n'
                printf 'available:Windows Search\n'
            else
                printf 'missing:PowerShell\n'
                printf 'missing:Windows Search\n'
            fi
            _tool_status_line fhmanagew.exe FileHistory
            _tool_status_line wbadmin.exe WindowsBackup
            if [[ -n "${OneDrive:-}${OneDriveConsumer:-}${OneDriveCommercial:-}" ]]; then
                printf 'available:OneDrive\n'
            else
                printf 'missing:OneDrive\n'
            fi
            if [[ -n "${ProgramData:-}" && -d "${ProgramData}/Backblaze" ]]; then
                printf 'available:Backblaze\n'
            else
                printf 'missing:Backblaze\n'
            fi
            if [[ -n "${LOCALAPPDATA:-}" && -d "${LOCALAPPDATA}/Dropbox" ]]; then
                printf 'available:Dropbox\n'
            else
                printf 'missing:Dropbox\n'
            fi
            if [[ -n "${LOCALAPPDATA:-}" && -d "${LOCALAPPDATA}/Google/DriveFS" ]]; then
                printf 'available:Google Drive\n'
            else
                printf 'missing:Google Drive\n'
            fi
            _tool_status_line rclone rclone
            ;;
    esac
    return 0
}

# Prints true|false|unknown|not-installed for Backblaze's
# "Also exclude Apple-specified exclusions" setting. Reads only the
# use_time_machine_excludes attribute; identity fields are never printed.
_backblaze_apple_exclusions() {
    if [[ ! -e "$BACKBLAZE_BZINFO" ]]; then
        printf 'not-installed\n'
        return 0
    fi
    if [[ ! -r "$BACKBLAZE_BZINFO" ]]; then
        printf 'unknown\n'
        return 0
    fi
    local value
    value="$(grep -Eo 'use_time_machine_excludes="(true|false)"' "$BACKBLAZE_BZINFO" 2>/dev/null | head -n 1 || true)"
    case "$value" in
        *'"true"') printf 'true\n' ;;
        *'"false"') printf 'false\n' ;;
        *) printf 'unknown\n' ;;
    esac
    return 0
}

# Prints one Backblaze status per path argument (excluded|included|unknown),
# using the longest case-insensitive bzdirfilter prefix match.
_backblaze_path_statuses() {
    if [[ ! -r "$BACKBLAZE_BZINFO" ]] || ! command -v python3 >/dev/null 2>&1; then
        local path
        for path in "$@"; do
            printf 'unknown\n'
        done
        return 0
    fi
    python3 - "$BACKBLAZE_BZINFO" "$@" <<'PY'
import re, sys
config, paths = sys.argv[1], sys.argv[2:]
try:
    with open(config, "r", encoding="utf-8", errors="replace") as handle:
        text = handle.read()
except Exception:
    for _ in paths:
        print("unknown")
    sys.exit(0)
filters = [
    (match.group(1).lower(), match.group(2).lower())
    for match in re.finditer(r'<bzdirfilter\s+dir="([^"]*)"\s+whichfiles="([^"]*)"', text)
]
for path in paths:
    key = path.lower().rstrip("/") + "/"
    best = None
    for directory, which in filters:
        if key.startswith(directory) and (best is None or len(directory) > len(best[0])):
            best = (directory, which)
    print("excluded" if best is not None and best[1] == "none" else "included")
PY
    return 0
}

# Prints the last-upload epoch seconds from gmt_millis, or nothing when absent.
# Reads only that attribute; account identifiers are never printed.
_backblaze_last_upload_epoch() {
    local file="$BACKBLAZE_BZDATA/bzreports_lastfilestransmitted/bzstat_lastfile_transmitted.xml"
    [[ -r "$file" ]] || return 0
    local millis
    millis="$(grep -Eo 'gmt_millis="[0-9]+"' "$file" 2>/dev/null | sed -n '1p' | grep -Eo '[0-9]+' || true)"
    [[ -n "$millis" ]] && printf '%s\n' "$((millis / 1000))"
    return 0
}

# Prints the hint from the last "safety_frozen with hint: <hint>" line of the
# newest bztransmit log only. Prints nothing when no freeze is logged.
_backblaze_frozen_hint() {
    local log_dir="$BACKBLAZE_BZDATA/bzlogs/bztransmit"
    local newest="" candidate
    for candidate in "$log_dir"/bztransmit*.log; do
        [[ -f "$candidate" ]] || continue
        if [[ -z "$newest" || "$candidate" -nt "$newest" ]]; then
            newest="$candidate"
        fi
    done
    [[ -n "$newest" && -r "$newest" ]] || return 0
    local line
    line="$(grep -E 'safety_frozen with hint: ' "$newest" 2>/dev/null | tail -n 1 || true)"
    [[ -n "$line" ]] || return 0
    line="${line##*safety_frozen with hint: }"
    line="${line%%[^A-Za-z0-9_-]*}"
    printf '%s\n' "${line:-unknown}"
    return 0
}

# Prints ok | stale:<hours> | safety_frozen:<hint> | unknown | not-installed.
# Read-only; threshold from AIDEVOPS_BACKBLAZE_STALE_HOURS (default 48).
_backblaze_health() {
    if [[ ! -d "${BACKBLAZE_BZDATA%/*}" ]]; then
        printf 'not-installed\n'
        return 0
    fi
    if [[ ! -d "$BACKBLAZE_BZDATA" || ! -r "$BACKBLAZE_BZDATA" ]]; then
        printf 'unknown\n'
        return 0
    fi
    local hint
    hint="$(_backblaze_frozen_hint)"
    if [[ -n "$hint" ]]; then
        printf 'safety_frozen:%s\n' "$hint"
        return 0
    fi
    local last
    last="$(_backblaze_last_upload_epoch)"
    if [[ -z "$last" ]]; then
        printf 'unknown\n'
        return 0
    fi
    local age=$(($(_now_epoch) - last))
    if [[ "$age" -lt 0 ]]; then
        printf 'unknown\n'
        return 0
    fi
    local hours=$((age / 3600))
    if [[ "$hours" -ge "$BACKBLAZE_STALE_HOURS" ]]; then
        printf 'stale:%s\n' "$hours"
    else
        printf 'ok\n'
    fi
    return 0
}

# Prints a one-line user action for a non-ok health result; nothing otherwise.
_backblaze_action_line() {
    local health="$1"
    local last since="its last upload"
    last="$(_backblaze_last_upload_epoch)"
    if [[ -n "$last" ]] && command -v python3 >/dev/null 2>&1; then
        since="$(python3 -c 'import sys,time; print(time.strftime("%Y-%m-%d", time.gmtime(int(sys.argv[1]))))' "$last" 2>/dev/null || printf 'its last upload')"
    fi
    case "$health" in
        safety_frozen:*) printf 'Backblaze backup frozen since %s; open Backblaze and resolve the safety freeze (needs your private encryption key)\n' "$since" ;;
        stale:*) printf 'Backblaze has not uploaded for %s hours (last upload %s); open Backblaze and check its status\n' "${health#stale:}" "$since" ;;
        unknown) printf 'Backblaze health could not be read; open Backblaze and confirm backups are uploading\n' ;;
    esac
    return 0
}

# Surfaces a non-ok Backblaze health result through the existing reminder
# channel (stdout line plus desktop notification, throttled once per interval).
_backblaze_surface() {
    local format="$1"
    local no_notify="$2"
    local health action
    health="$(_backblaze_health)"
    action="$(_backblaze_action_line "$health")"
    [[ -n "$action" ]] || return 0
    case "$format" in
        toast) printf '[WARN] %s\n' "$action" ;;
        json) printf '{"backblaze_health":%s,"action":%s}\n' "$(_json_escape "$health")" "$(_json_escape "$action")" ;;
        *) printf '%s.\n' "$action" ;;
    esac
    [[ "$no_notify" == "true" ]] && return 0
    command -v osascript >/dev/null 2>&1 && [[ -z "${AIDEVOPS_HEADLESS:-}" ]] || return 0
    local marker="${STATE_DIR}/backblaze-health-notified" now last=0
    now="$(_now_epoch)"
    [[ -r "$marker" ]] && last="$(<"$marker")"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if [[ "$last" -eq 0 || $((now - last)) -ge "$NOTIFY_INTERVAL_SECONDS" ]]; then
        osascript -e "display notification \"${action//\"/}\" with title \"Backblaze backup needs attention\"" >/dev/null 2>&1 || true
        _ensure_dirs
        printf '%s\n' "$now" >"$marker"
    fi
    return 0
}

# Read-only, macOS only. RSS is KiB; use the largest daemon if pgrep finds
# multiple processes. Invalid/missing telemetry must never look healthy.
FSEVENTSD_UNKNOWN="unknown"
_fseventsd_health() {
    local pids sample
    [[ "$(uname -s)" == "Darwin" ]] || { printf '%s\n' "$FSEVENTSD_UNKNOWN"; return 0; }
    pids="$(pgrep -x fseventsd 2>/dev/null | paste -sd, - || true)"
    [[ -n "$pids" ]] || { printf '%s\n' "$FSEVENTSD_UNKNOWN"; return 0; }
    sample="$(LC_ALL=C ps -o rss=,pcpu= -p "$pids" 2>/dev/null || true)"
    LC_ALL=C awk -v threshold="${AIDEVOPS_FSEVENTSD_RSS_GB:-2}" -v unknown="$FSEVENTSD_UNKNOWN" '
        BEGIN { valid = (threshold ~ /^[0-9]+([.][0-9]+)?$/ && threshold > 0) }
        NF == 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+([.][0-9]+)?$/ {
            seen = 1; if ($1 > rss) rss = $1
        }
        END {
            if (!valid || !seen) print unknown
            else if (rss / 1048576 > threshold) printf "runaway:%.2f\n", rss / 1048576
            else print "ok"
        }' <<<"$sample"
    return 0
}

_fseventsd_action_line() {
    local health="$1"
    local swap
    case "$health" in
        runaway:*)
            swap="$(LC_ALL=C sysctl -n vm.swapusage 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i == "used" && $(i+1) == "=") {print $(i+2); exit}}' || true)"
            [[ "$swap" =~ ^[0-9]+([.][0-9]+)?[MGTP]$ ]] || swap="$FSEVENTSD_UNKNOWN"
            printf 'fseventsd is using %s GiB RSS (swap used: %s); please run sudo killall fseventsd in a terminal or reboot.\n' "${health#runaway:}" "$swap"
            ;;
    esac
    return 0
}

# Reminder consumers (including runner monitoring) record capacity loss without
# changing dispatch limits. Bound reports to once per day; retry failed writes.
_fseventsd_report() {
    local health="$1"
    local marker="${STATE_DIR}/fseventsd-runaway-reported" now last=0
    [[ "$health" == runaway:* ]] || return 0
    [[ -x "${SCRIPT_DIR}/throttle-report-helper.sh" ]] || return 0
    now="$(_now_epoch)"
    [[ -r "$marker" ]] && last="$(<"$marker")"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    [[ "$last" -eq 0 || $((now - last)) -ge 86400 ]] || return 0
    if "${SCRIPT_DIR}/throttle-report-helper.sh" report \
        --request "Restore macOS runner capacity after fseventsd memory runaway" \
        --root-cause "fseventsd memory runaway under filesystem churn" \
        --systemic-fix "Ask the operator to restart fseventsd or reboot; never run sudo automatically" \
        --throttle "None applied by this check" \
        --evidence "fseventsd_health=${health}; load-sensitive workers may be affected" >/dev/null 2>&1; then
        _ensure_dirs
        printf '%s\n' "$now" >"$marker"
    fi
    return 0
}

_fseventsd_surface() {
    local format="$1"
    local no_notify="$2"
    local health action
    health="$(_fseventsd_health)"
    action="$(_fseventsd_action_line "$health")"
    if [[ "$format" == "json" ]]; then
        printf '{"fseventsd_health":%s,"action":%s}\n' "$(_json_escape "$health")" "$(_json_escape "$action")"
    elif [[ -n "$action" ]]; then
        [[ "$format" == "toast" ]] && printf '[WARN] '
        printf '%s\n' "$action"
    fi
    [[ -n "$action" ]] || return 0
    _fseventsd_report "$health"
    [[ "$no_notify" == "true" ]] && return 0
    command -v osascript >/dev/null 2>&1 && [[ -z "${AIDEVOPS_HEADLESS:-}" ]] || return 0
    local marker="${STATE_DIR}/fseventsd-health-notified" now last=0
    now="$(_now_epoch)"
    [[ -r "$marker" ]] && last="$(<"$marker")"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if [[ "$last" -eq 0 || $((now - last)) -ge "$NOTIFY_INTERVAL_SECONDS" ]]; then
        osascript -e "display notification \"${action}\" with title \"macOS runner needs attention\"" >/dev/null 2>&1 || true
        _ensure_dirs
        printf '%s\n' "$now" >"$marker"
    fi
    return 0
}

_cmd_health() {
    local platform="$1"
    local format="${2:-}"
    local health fseventsd="$FSEVENTSD_UNKNOWN"
    health="$(_backblaze_health)"
    [[ "$platform" == "macos" ]] && fseventsd="$(_fseventsd_health)"
    if [[ "$format" == "--json" ]]; then
        printf '{"backblaze_health":%s,"fseventsd_health":%s}\n' "$(_json_escape "$health")" "$(_json_escape "$fseventsd")"
    else
        printf 'backblaze_health=%s\n' "$health"
        [[ "$platform" == "macos" ]] && printf 'fseventsd_health=%s\n' "$fseventsd"
    fi
    return 0
}

_time_machine_status() {
    local path="$1"
    if ! command -v tmutil >/dev/null 2>&1; then
        printf 'unknown\n'
        return 0
    fi
    local output
    output="$(tmutil isexcluded "$path" 2>/dev/null || true)"
    case "$output" in
        *"[Excluded]"*) printf 'excluded\n' ;;
        *"[Included]"*) printf 'included\n' ;;
        *) printf 'unknown\n' ;;
    esac
    return 0
}

# Emits "path<TAB>time_machine<TAB>backblaze" for existing macOS candidates.
# Read-only: never changes Time Machine or Backblaze configuration.
_macos_coverage_tsv() {
    local apple path status
    local -a paths=()
    local -a bz_statuses=()
    apple="$(_backblaze_apple_exclusions)"
    while IFS= read -r path; do
        [[ -n "$path" && -d "$path" ]] && paths+=("$path")
    done < <(_candidate_paths macos)
    [[ "${#paths[@]}" -gt 0 ]] || return 0
    if [[ "$apple" == "not-installed" ]]; then
        for path in "${paths[@]}"; do
            bz_statuses+=("n/a")
        done
    else
        while IFS= read -r status; do
            bz_statuses+=("$status")
        done < <(_backblaze_path_statuses "${paths[@]}")
    fi
    local index=0 tm_status bz_status
    for path in "${paths[@]}"; do
        tm_status="$(_time_machine_status "$path")"
        bz_status="${bz_statuses[$index]:-unknown}"
        if [[ "$bz_status" == "included" && "$apple" == "true" && "$tm_status" == "excluded" ]]; then
            bz_status="excluded-via-apple"
        fi
        printf '%s\t%s\t%s\n' "$path" "$tm_status" "$bz_status"
        index=$((index + 1))
    done
    return 0
}

_emit_macos_coverage_human() {
    local apple path tm_status bz_status
    printf '\nExclusion coverage for existing paths (tm=Time Machine, bz=Backblaze):\n'
    while IFS="$(printf '\t')" read -r path tm_status bz_status; do
        [[ -n "$path" ]] || continue
        printf '%s\n' "- ${path}: tm=${tm_status} bz=${bz_status}"
    done < <(_macos_coverage_tsv)
    apple="$(_backblaze_apple_exclusions)"
    [[ "$apple" == "not-installed" ]] && return 0
    printf '\nBackblaze "Also exclude Apple-specified exclusions": %s\n' "$apple"
    if [[ "$apple" == "false" ]]; then
        printf 'Recommendation: enable it in Backblaze Settings > Exclusions so Time Machine exclusions (for example node_modules) also apply to Backblaze.\n'
    fi
    return 0
}

_macos_coverage_json() {
    if [[ "$#" -gt 0 && "$1" != "macos" ]]; then
        printf '[]\n'
        return 0
    fi
    _macos_coverage_tsv | jq -R 'split("\t") | {path: .[0], time_machine: .[1], backblaze: .[2]}' | jq -s .
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
    _project_patterns "$platform" | while IFS= read -r pattern; do
        printf '%s\n' "- ${pattern}"
    done
    if [[ "$platform" == "macos" ]]; then
        _emit_macos_coverage_human
    fi
    if [[ "$platform" == "$PLATFORM_WINDOWS" ]]; then
        printf '\nNative Windows support posture: limited experimental optimisation command only; full aidevops support still recommends WSL2.\n'
        printf 'Apply mode writes reusable recommendation files only and does not mutate Windows Search, File History, OneDrive, Defender, or backup-client settings.\n'
    fi
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
    local candidates systems patterns coverage apple_exclusions="n/a"
    candidates="$(_candidate_paths "$platform" | jq -R . | jq -s .)"
    systems="$(_detected_systems "$platform" | jq -R 'split(":") | {status: .[0], name: .[1]}' | jq -s .)"
    patterns="$(_project_patterns "$platform" | jq -R . | jq -s .)"
    coverage="$(_macos_coverage_json "$platform")"
    if [[ "$platform" == "macos" ]]; then
        apple_exclusions="$(_backblaze_apple_exclusions)"
    fi
    jq -n \
        --arg platform "$platform" \
        --arg mode "$mode" \
        --arg state_file "$STATE_FILE" \
        --arg log_file "$LOG_FILE" \
        --arg support_posture "limited experimental optimisation command; WSL2 uses linux" \
        --argjson candidates "$candidates" \
        --argjson systems "$systems" \
        --argjson patterns "$patterns" \
        --argjson coverage "$coverage" \
        --arg apple_exclusions "$apple_exclusions" \
        '{platform:$platform, mode:$mode, state_file:$state_file, log_file:$log_file, support_posture:$support_posture, detected_systems:$systems, candidate_paths:$candidates, project_patterns:$patterns, coverage:$coverage, backblaze:{apple_exclusions:$apple_exclusions}, unsafe_exclusions:["home directory","source trees","Documents","Desktop","Downloads",".ssh",".gnupg","credential stores","broad config directories"]}'
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
        _project_patterns linux
    } >"$exclude_file"
    printf '1\n'
    return 0
}

_apply_windows_safe() {
    local exclude_file="${CONFIG_DIR}/optimise-indexing-backups-windows-excludes.txt"
    _ensure_dirs
    {
        printf '# aidevops generated native Windows indexing/backup recommendations\n'
        printf '# Safe apply scope: this file only. No Windows Search, File History, OneDrive, Defender, or backup-client settings were changed.\n'
        printf '# Review these placeholders before adding exclusions in Windows Search, File History/Windows Backup, OneDrive, or backup-client settings.\n'
        _candidate_paths windows
        _project_patterns windows
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
            windows) applied="$(_apply_windows_safe)" ;;
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
    if [[ "$platform" == "macos" ]]; then
        _backblaze_surface "$format" "$no_notify"
        _fseventsd_surface "$format" "$no_notify"
    fi
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
        windows-native) platform="$PLATFORM_WINDOWS" ;;
    esac
    case "$platform" in
        macos|linux|windows) ;;
        *) print_error "platform must be macos, linux, or windows"; return 2 ;;
    esac
    case "$command_name" in
        scan) _cmd_scan "$platform" "$@" ;;
        apply) _cmd_scan "$platform" --apply "$@" ;;
        status) _cmd_status "$platform" "$@" ;;
        reminder) _cmd_reminder "$platform" "$@" ;;
        health) _cmd_health "$platform" "$@" ;;
        help|--help) usage ;;
        *) print_error "unknown command: $command_name"; return 2 ;;
    esac
    return 0
}

main "$@"
