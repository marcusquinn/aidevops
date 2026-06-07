#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Launch OpenCode with an aidevops-managed per-session data directory.
# This keeps interactive sessions off the shared ~/.local/share/opencode/opencode.db
# hot spot while preserving the user's normal config and copied auth tokens.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# shellcheck disable=SC1091
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
    source "${SCRIPT_DIR}/shared-constants.sh"
fi

[[ -z "${GREEN+x}" ]] && GREEN=$'\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW=$'\033[1;33m'
[[ -z "${RED+x}" ]] && RED=$'\033[0;31m'
[[ -z "${NC+x}" ]] && NC=$'\033[0m'

print_info() { printf '%b[INFO]%b %s\n' "${YELLOW}" "${NC}" "$*"; return 0; }
print_success() { printf '%b[OK]%b %s\n' "${GREEN}" "${NC}" "$*"; return 0; }
print_error() { printf '%b[ERROR]%b %s\n' "${RED}" "${NC}" "$*" >&2; return 0; }

usage() {
    cat <<'EOF'
Usage: aidevops opencode [options] [--] [opencode args...]

Launch OpenCode with an isolated per-project SQLite DB by default.

Options:
  --shared-db          Use OpenCode's normal shared data directory
  --dir PATH           Working directory for OpenCode (default: current dir)
  --session-id ID      Explicit isolated DB name (default: stable per-project shard)
  --dry-run            Print the environment/command without executing
  -h, --help           Show this help

Examples:
  aidevops opencode
  aidevops opencode --dir ~/Git/aidevops
  aidevops opencode -- --version
EOF
    return 0
}

sql_escape_label() {
    local value="$1"
    value=${value//[^A-Za-z0-9._-]/-}
    value=${value#-}
    value=${value%-}
    printf '%s' "${value:-session}"
    return 0
}

copy_auth_json() {
    local target_data_dir="$1"
    local source_auth="${XDG_DATA_HOME:-${HOME}/.local/share}/opencode/auth.json"
    local target_auth="${target_data_dir}/opencode/auth.json"

    [[ -f "${source_auth}" ]] || return 0
    mkdir -p "$(dirname "${target_auth}")" || return 1
    cp "${source_auth}" "${target_auth}" || return 1
    chmod 600 "${target_auth}" 2>/dev/null || true
    return 0
}

prewarm_opencode_data_dir() {
    local target_data_dir="$1"

    # OpenCode writes a first-run database migration progress bar to stderr
    # before the TUI starts when opencode.db is absent. Run that migration with
    # stderr/stdout detached so the subsequent interactive TUI starts on a clean
    # terminal frame.
    [[ -f "${target_data_dir}/opencode/opencode.db" ]] && return 0
    XDG_DATA_HOME="${target_data_dir}" opencode --version >/dev/null 2>&1 || true
    return 0
}

build_session_data_dir() {
    local session_id="$1"
    local safe_id
    safe_id=$(sql_escape_label "${session_id}")
    printf '%s/opencode-interactive/%s' "${AIDEVOPS_WORK_DIR:-${HOME}/.aidevops/.agent-workspace/work}" "${safe_id}"
    return 0
}

build_project_session_id() {
    local launch_dir="$1"
    local resolved_dir=""
    local base_name=""
    local checksum=""

    resolved_dir=$(cd "${launch_dir}" && pwd -P) || resolved_dir="${launch_dir}"
    base_name=$(basename "${resolved_dir}")
    checksum=$(printf '%s' "${resolved_dir}" | cksum)
    checksum=${checksum%% *}
    printf 'project-%s-%s' "$(sql_escape_label "${base_name}")" "${checksum}"
    return 0
}

main() {
    local use_shared_db=0
    local dry_run=0
    local launch_dir="$PWD"
    local session_id=""
    local -a opencode_args=()

    while (($# > 0)); do
        case "$1" in
        --shared-db)
            use_shared_db=1
            shift
            ;;
        --dir)
            [[ $# -ge 2 ]] || { print_error "--dir requires a path"; return 1; }
            launch_dir="$2"
            shift 2
            ;;
        --session-id)
            [[ $# -ge 2 ]] || { print_error "--session-id requires a value"; return 1; }
            session_id="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        -h | --help | help)
            usage
            return 0
            ;;
        --)
            shift
            opencode_args+=("$@")
            break
            ;;
        *)
            opencode_args+=("$1")
            shift
            ;;
        esac
    done

    [[ -d "${launch_dir}" ]] || { print_error "Directory not found: ${launch_dir}"; return 1; }
    command -v opencode >/dev/null 2>&1 || { print_error "opencode not found in PATH"; return 1; }
    if [[ -z "${session_id}" ]]; then
        session_id=$(build_project_session_id "${launch_dir}")
    fi

    if ((${#opencode_args[@]} == 0)); then
        opencode_args=()
    fi

    if ((use_shared_db == 1)); then
        if ((dry_run == 1)); then
            printf 'cd %s && opencode' "${launch_dir}"
            printf ' %q' "${opencode_args[@]}"
            printf '\n'
            return 0
        fi
        cd "${launch_dir}" || return 1
        exec opencode "${opencode_args[@]}"
        return 1
    fi

    local data_dir
    data_dir=$(build_session_data_dir "${session_id}")
    mkdir -p "${data_dir}/opencode" || return 1
    # Keep stdout/stderr clean before exec: OpenCode's TUI is sensitive to any
    # pre-launch terminal output and can leave visible redraw artifacts.
    copy_auth_json "${data_dir}" || true
    prewarm_opencode_data_dir "${data_dir}"

    if ((dry_run == 1)); then
        printf 'XDG_DATA_HOME=%q AIDEVOPS_OPENCODE_ISOLATED_DB=1 cd %q && opencode' "${data_dir}" "${launch_dir}"
        printf ' %q' "${opencode_args[@]}"
        printf '\n'
        return 0
    fi

    cd "${launch_dir}" || return 1
    export XDG_DATA_HOME="${data_dir}"
    export AIDEVOPS_OPENCODE_ISOLATED_DB=1
    exec opencode "${opencode_args[@]}"
    return 1
}

main "$@"
