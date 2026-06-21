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

OPT_DESKTOP_SOURCE_BINARY="--source-binary"

usage() {
    cat <<'EOF'
Usage: aidevops opencode [options] [--] [opencode args...]
       aidevops opencode-desktop [launch options]
       aidevops opencode-desktop install-shortcut [options]
       aidevops opencode-desktop status [options]

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
  aidevops opencode-desktop
  aidevops opencode-desktop install-shortcut
EOF
    return 0
}

desktop_usage() {
    cat <<EOF
Usage: aidevops opencode-desktop [launch options]
       aidevops opencode-desktop install-shortcut [options]
       aidevops opencode-desktop status [options]

Launch OpenCode Desktop with an aidevops-managed XDG_DATA_HOME so the Desktop
app does not write to the shared ~/.local/share/opencode/opencode.db hot spot.

Launch options:
  --dir PATH             Working directory for Desktop (default: cwd; app bundle: HOME)
  --session-id ID        Explicit isolated DB name (default: desktop-default or per-project)
  --data-dir PATH        Explicit XDG_DATA_HOME for Desktop
  ${OPT_DESKTOP_SOURCE_BINARY} PATH   OpenCode.app executable path
  --dry-run              Print the command without launching

Shortcut options:
  --name NAME            App display name (default: OpenCode AIDevOps)
  --app-dir PATH         Parent directory for the generated .app (default: ~/Applications)
  ${OPT_DESKTOP_SOURCE_BINARY} PATH   OpenCode.app executable path
  --dry-run              Print the target path without writing

Environment overrides:
  AIDEVOPS_OPENCODE_DESKTOP_APP_DIR       Parent directory for generated .app
  AIDEVOPS_OPENCODE_DESKTOP_BINARY        OpenCode Desktop executable path
  AIDEVOPS_OPENCODE_DESKTOP_DATA_DIR      Explicit Desktop XDG_DATA_HOME
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
    XDG_DATA_HOME="${target_data_dir}" opencode db path >/dev/null 2>&1 || true
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

build_desktop_data_dir() {
    local session_id="$1"
    local launch_dir="${2:-}"
    local safe_id=""

    if [[ -z "${session_id}" ]]; then
        if [[ -n "${launch_dir}" ]]; then
            session_id="desktop-$(build_project_session_id "${launch_dir}")"
        else
            session_id="desktop-default"
        fi
    fi
    safe_id=$(sql_escape_label "${session_id}")
    printf '%s/opencode-desktop/%s' "${AIDEVOPS_WORK_DIR:-${HOME}/.aidevops/.agent-workspace/work}" "${safe_id}"
    return 0
}

xml_escape() {
    local value="$1"
    value=${value//&/\&amp;}
    value=${value//</\&lt;}
    value=${value//>/\&gt;}
    value=${value//\"/\&quot;}
    value=${value//\'/\&apos;}
    printf '%s' "${value}"
    return 0
}

write_file_if_changed() {
    local path="$1"
    local content="$2"
    local tmp_path="${path}.tmp.$$"

    if [[ -f "${path}" ]]; then
        printf '%s' "${content}" >"${tmp_path}" || return 1
        if cmp -s "${tmp_path}" "${path}"; then
            rm -f "${tmp_path}" || true
            return 0
        fi
        mv "${tmp_path}" "${path}" || return 1
        return 0
    fi
    printf '%s' "${content}" >"${path}" || return 1
    return 0
}

is_macos() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        return 0
    fi
    return 1
}

detect_desktop_binary() {
    local explicit_binary="${1:-}"

    if [[ -n "${explicit_binary}" ]]; then
        [[ -x "${explicit_binary}" ]] || return 1
        printf '%s' "${explicit_binary}"
        return 0
    fi
    if [[ -n "${AIDEVOPS_OPENCODE_DESKTOP_BINARY:-}" ]]; then
        [[ -x "${AIDEVOPS_OPENCODE_DESKTOP_BINARY}" ]] || return 1
        printf '%s' "${AIDEVOPS_OPENCODE_DESKTOP_BINARY}"
        return 0
    fi
    if [[ -x "/Applications/OpenCode.app/Contents/MacOS/OpenCode" ]]; then
        printf '%s' "/Applications/OpenCode.app/Contents/MacOS/OpenCode"
        return 0
    fi
    if [[ -x "${HOME}/Applications/OpenCode.app/Contents/MacOS/OpenCode" ]]; then
        printf '%s' "${HOME}/Applications/OpenCode.app/Contents/MacOS/OpenCode"
        return 0
    fi
    return 1
}

desktop_app_path() {
    local app_name="$1"
    local app_dir="$2"
    local safe_name=""

    safe_name=${app_name//\//-}
    safe_name=${safe_name:-OpenCode AIDevOps}
    printf '%s/%s.app' "${app_dir}" "${safe_name}"
    return 0
}

desktop_wrapper_content() {
    cat <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

helper="${AIDEVOPS_OPENCODE_LAUNCHER_HELPER:-${HOME}/.aidevops/agents/scripts/opencode-launcher-helper.sh}"
if [[ ! -x "${helper}" ]]; then
    osascript -e 'display alert "OpenCode AIDevOps launcher is not installed" message "Run aidevops update, then open this app again."' >/dev/null 2>&1 || true
    exit 1
fi

exec "${helper}" desktop launch --from-app "$@"
EOF
    return 0
}

desktop_plist_content() {
    local app_name="$1"
    local bundle_id="$2"
    local executable_name="$3"

    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>$(xml_escape "${app_name}")</string>
  <key>CFBundleDisplayName</key>
  <string>$(xml_escape "${app_name}")</string>
  <key>CFBundleIdentifier</key>
  <string>$(xml_escape "${bundle_id}")</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>$(xml_escape "${executable_name}")</string>
  <key>LSMinimumSystemVersion</key>
  <string>10.13</string>
</dict>
</plist>
EOF
    return 0
}

cmd_desktop_install_shortcut() {
    local app_name="OpenCode AIDevOps"
    local app_dir="${AIDEVOPS_OPENCODE_DESKTOP_APP_DIR:-${HOME}/Applications}"
    local source_binary=""
    local dry_run=0

    while (($# > 0)); do
        case "$1" in
        --name)
            [[ $# -ge 2 ]] || { print_error "--name requires a value"; return 1; }
            app_name="$2"
            shift 2
            ;;
        --app-dir)
            [[ $# -ge 2 ]] || { print_error "--app-dir requires a path"; return 1; }
            app_dir="$2"
            shift 2
            ;;
        "${OPT_DESKTOP_SOURCE_BINARY}")
            [[ $# -ge 2 ]] || { print_error "${OPT_DESKTOP_SOURCE_BINARY} requires a path"; return 1; }
            source_binary="$2"
            shift 2
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        --help | -h)
            desktop_usage
            return 0
            ;;
        *)
            print_error "Unknown install-shortcut option: $1"
            return 1
            ;;
        esac
    done

    if ! is_macos; then
        print_info "OpenCode Desktop app shortcut install is currently macOS-only"
        return 0
    fi
    if ! detect_desktop_binary "${source_binary}" >/dev/null 2>&1; then
        print_info "OpenCode Desktop app not found; skipping shortcut install"
        return 3
    fi

    local app_path=""
    local contents_dir=""
    local macos_dir=""
    local plist_path=""
    local executable_name="opencode-aidevops"
    local executable_path=""
    local bundle_id="sh.aidevops.opencode.desktop"

    app_path=$(desktop_app_path "${app_name}" "${app_dir}")
    contents_dir="${app_path}/Contents"
    macos_dir="${contents_dir}/MacOS"
    plist_path="${contents_dir}/Info.plist"
    executable_path="${macos_dir}/${executable_name}"

    if ((dry_run == 1)); then
        printf '%s\n' "${app_path}"
        return 0
    fi

    mkdir -p "${macos_dir}" || return 1
    write_file_if_changed "${plist_path}" "$(desktop_plist_content "${app_name}" "${bundle_id}" "${executable_name}")" || return 1
    write_file_if_changed "${executable_path}" "$(desktop_wrapper_content)" || return 1
    chmod 755 "${executable_path}" || return 1
    print_success "Installed ${app_name}.app at ${app_path}"
    return 0
}

cmd_desktop_status() {
    local app_name="OpenCode AIDevOps"
    local app_dir="${AIDEVOPS_OPENCODE_DESKTOP_APP_DIR:-${HOME}/Applications}"
    local source_binary=""
    local app_path=""

    while (($# > 0)); do
        case "$1" in
        --name)
            [[ $# -ge 2 ]] || { print_error "--name requires a value"; return 1; }
            app_name="$2"
            shift 2
            ;;
        --app-dir)
            [[ $# -ge 2 ]] || { print_error "--app-dir requires a path"; return 1; }
            app_dir="$2"
            shift 2
            ;;
        "${OPT_DESKTOP_SOURCE_BINARY}")
            [[ $# -ge 2 ]] || { print_error "${OPT_DESKTOP_SOURCE_BINARY} requires a path"; return 1; }
            source_binary="$2"
            shift 2
            ;;
        --help | -h)
            desktop_usage
            return 0
            ;;
        *)
            print_error "Unknown status option: $1"
            return 1
            ;;
        esac
    done

    app_path=$(desktop_app_path "${app_name}" "${app_dir}")
    if [[ -d "${app_path}" ]]; then
        print_success "Desktop shortcut installed: ${app_path}"
    else
        print_info "Desktop shortcut not installed: ${app_path}"
    fi
    if detect_desktop_binary "${source_binary}" >/dev/null 2>&1; then
        print_success "OpenCode Desktop source app found"
    else
        print_info "OpenCode Desktop source app not found"
    fi
    return 0
}

cmd_desktop_launch() {
    local dry_run=0
    local launch_dir="$PWD"
    local launch_dir_set=0
    local from_app=0
    local session_id=""
    local data_dir="${AIDEVOPS_OPENCODE_DESKTOP_DATA_DIR:-}"
    local source_binary=""
    local -a desktop_args=()

    while (($# > 0)); do
        case "$1" in
        --dir)
            [[ $# -ge 2 ]] || { print_error "--dir requires a path"; return 1; }
            launch_dir="$2"
            launch_dir_set=1
            shift 2
            ;;
        --session-id)
            [[ $# -ge 2 ]] || { print_error "--session-id requires a value"; return 1; }
            session_id="$2"
            shift 2
            ;;
        --data-dir)
            [[ $# -ge 2 ]] || { print_error "--data-dir requires a path"; return 1; }
            data_dir="$2"
            shift 2
            ;;
        "${OPT_DESKTOP_SOURCE_BINARY}")
            [[ $# -ge 2 ]] || { print_error "${OPT_DESKTOP_SOURCE_BINARY} requires a path"; return 1; }
            source_binary="$2"
            shift 2
            ;;
        --from-app)
            from_app=1
            shift
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        --help | -h)
            desktop_usage
            return 0
            ;;
        --)
            shift
            desktop_args+=("$@")
            break
            ;;
        *)
            desktop_args+=("$1")
            shift
            ;;
        esac
    done

    if ! is_macos; then
        print_error "OpenCode Desktop launch is currently macOS-only"
        return 1
    fi

    local desktop_binary=""
    if ! desktop_binary=$(detect_desktop_binary "${source_binary}"); then
        print_error "OpenCode Desktop app not found. Install OpenCode.app or pass --source-binary PATH."
        return 1
    fi

    if ((from_app == 1 && launch_dir_set == 0)); then
        launch_dir="${HOME}"
    fi
    [[ -d "${launch_dir}" ]] || { print_error "Directory not found: ${launch_dir}"; return 1; }

    if [[ -z "${data_dir}" ]]; then
        if ((launch_dir_set == 1)); then
            data_dir=$(build_desktop_data_dir "${session_id}" "${launch_dir}")
        else
            data_dir=$(build_desktop_data_dir "${session_id}" "")
        fi
    fi
    mkdir -p "${data_dir}/opencode" || return 1
    copy_auth_json "${data_dir}" || true
    prewarm_opencode_data_dir "${data_dir}"

    if ((dry_run == 1)); then
        printf 'cd %q && XDG_DATA_HOME=%q AIDEVOPS_OPENCODE_ISOLATED_DB=1 %q' "${launch_dir}" "${data_dir}" "${desktop_binary}"
        printf ' %q' "${desktop_args[@]}"
        printf '\n'
        return 0
    fi

    cd "${launch_dir}" || return 1
    export XDG_DATA_HOME="${data_dir}"
    export AIDEVOPS_OPENCODE_ISOLATED_DB=1
    exec "${desktop_binary}" "${desktop_args[@]}"
    return 1
}

cmd_desktop() {
    local subcommand="${1:-launch}"
    case "${subcommand}" in
    launch)
        shift || true
        cmd_desktop_launch "$@"
        ;;
    install-shortcut | install-app | install)
        shift || true
        cmd_desktop_install_shortcut "$@"
        ;;
    status)
        shift || true
        cmd_desktop_status "$@"
        ;;
    help | --help | -h)
        desktop_usage
        ;;
    *)
        cmd_desktop_launch "$@"
        ;;
    esac
    return $?
}

main() {
    if [[ "${1:-}" == "desktop" ]]; then
        shift || true
        cmd_desktop "$@"
        return $?
    fi

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
        printf 'cd %q && XDG_DATA_HOME=%q AIDEVOPS_OPENCODE_ISOLATED_DB=1 opencode' "${launch_dir}" "${data_dir}"
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
