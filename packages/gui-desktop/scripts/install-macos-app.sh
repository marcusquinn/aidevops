#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

APP_NAME="aidevops.app"
DEFAULT_APP_DIR="/Applications"

usage() {
  printf 'Usage: %s [--check] [--app-dir DIR]\n' "$0"
  return 0
}

repo_root() {
  git rev-parse --show-toplevel
  return 0
}

validate_environment() {
  local root="$1"

  if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'gui desktop install currently supports macOS only\n' >&2
    return 1
  fi
  if [[ ! -f "${root}/package.json" ]]; then
    printf 'repo root missing package.json: %s\n' "$root" >&2
    return 1
  fi
  if ! command -v bun >/dev/null 2>&1; then
    printf 'bun is required to launch the current GUI scaffold\n' >&2
    return 1
  fi

  return 0
}

write_app_bundle() {
  local root="$1"
  local app_dir="$2"
  local app_path="${app_dir}/${APP_NAME}"
  local contents_dir="${app_path}/Contents"
  local macos_dir="${contents_dir}/MacOS"
  local resources_dir="${contents_dir}/Resources"

  mkdir -p "$macos_dir" "$resources_dir"
  cat > "${contents_dir}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>aidevops</string>
  <key>CFBundleDisplayName</key><string>aidevops</string>
  <key>CFBundleIdentifier</key><string>sh.aidevops.gui</string>
  <key>CFBundleVersion</key><string>3.21.7</string>
  <key>CFBundleShortVersionString</key><string>3.21.7</string>
  <key>CFBundleExecutable</key><string>aidevops-gui</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST

  cat > "${macos_dir}/aidevops-gui" <<LAUNCHER
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${root}"
API_PORT="\${AIDEVOPS_GUI_API_PORT:-8787}"
WEB_PORT="\${AIDEVOPS_GUI_WEB_PORT:-5173}"
LOG_DIR="\${HOME}/Library/Logs/aidevops-gui"
mkdir -p "\${LOG_DIR}"

cd "\${REPO_ROOT}"

if [[ -f "\${HOME}/.aidevops/agents/VERSION" && -f "\${REPO_ROOT}/VERSION" ]]; then
  INSTALLED_VERSION="\$(tr -d '\n' < "\${HOME}/.aidevops/agents/VERSION")"
  RUNNING_VERSION="\$(tr -d '\n' < "\${REPO_ROOT}/VERSION")"
  if [[ "\${INSTALLED_VERSION}" != "\${RUNNING_VERSION}" ]]; then
    osascript -e "display notification \"Restart aidevops GUI after update: installed \${INSTALLED_VERSION}, app \${RUNNING_VERSION}.\" with title \"aidevops update ready\"" >/dev/null 2>&1 || true
  fi
fi

AIDEVOPS_GUI_API_PORT="\${API_PORT}" bun run packages/gui-api/src/server.ts >"\${LOG_DIR}/api.log" 2>&1 &
API_PID="\$!"
bun ./node_modules/vite/bin/vite.js --host 127.0.0.1 --port "\${WEB_PORT}" packages/gui-web >"\${LOG_DIR}/web.log" 2>&1 &
WEB_PID="\$!"

sleep 2
open "http://127.0.0.1:\${WEB_PORT}"

wait "\${API_PID}" "\${WEB_PID}"
LAUNCHER
  chmod 755 "${macos_dir}/aidevops-gui"
  printf 'Installed %s\n' "$app_path"
  return 0
}

main() {
  local mode="install"
  local app_dir="$DEFAULT_APP_DIR"
  local root=""

  while [[ $# -gt 0 ]]; do
    local arg="$1"
    case "$arg" in
      --check)
        mode="check"
        shift
        ;;
      --app-dir)
        if [[ $# -lt 2 ]]; then
          usage >&2
          return 1
        fi
        local next_arg="$2"
        app_dir="$next_arg"
        shift 2
        ;;
      --help|-h)
        usage
        return 0
        ;;
      *)
        usage >&2
        return 1
        ;;
    esac
  done

  root="$(repo_root)"
  validate_environment "$root"
  if [[ "$mode" == "check" ]]; then
    printf 'macOS app bundle check passed for %s\n' "$root"
    return 0
  fi
  write_app_bundle "$root" "$app_dir"
  return 0
}

main "$@"
