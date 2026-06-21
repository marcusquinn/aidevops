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
  if ! command -v sips >/dev/null 2>&1 || ! command -v iconutil >/dev/null 2>&1; then
    printf 'macOS sips and iconutil are required to build the app icon\n' >&2
    return 1
  fi

  return 0
}

write_icon_assets() {
  local resources_dir="$1"
  local svg_path="${resources_dir}/aidevops.svg"
  local png_path="${resources_dir}/aidevops-source.png"
  local iconset_dir="${resources_dir}/aidevops.iconset"

  cat > "$svg_path" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <rect width="512" height="512" rx="64" fill="#0a0a0a"/>
  <path fill="#B2E969" d="M73.4 150.6c-12.5-12.5-12.5-32.8 0-45.3s32.8-12.5 45.3 0l160 160c12.5 12.5 12.5 32.8 0 45.3l-160 160c-12.5 12.5-32.8 12.5-45.3 0s-12.5-32.8 0-45.3L210.7 288 73.4 150.6zM240 400h192c17.7 0 32 14.3 32 32s-14.3 32-32 32H240c-17.7 0-32-14.3-32-32s14.3-32 32-32z"/>
</svg>
SVG

  rm -rf "$iconset_dir"
  mkdir -p "$iconset_dir"
  sips -s format png "$svg_path" --out "$png_path" >/dev/null
  sips -z 16 16 "$png_path" --out "${iconset_dir}/icon_16x16.png" >/dev/null
  sips -z 32 32 "$png_path" --out "${iconset_dir}/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$png_path" --out "${iconset_dir}/icon_32x32.png" >/dev/null
  sips -z 64 64 "$png_path" --out "${iconset_dir}/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$png_path" --out "${iconset_dir}/icon_128x128.png" >/dev/null
  sips -z 256 256 "$png_path" --out "${iconset_dir}/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$png_path" --out "${iconset_dir}/icon_256x256.png" >/dev/null
  sips -z 512 512 "$png_path" --out "${iconset_dir}/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$png_path" --out "${iconset_dir}/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$png_path" --out "${iconset_dir}/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$iconset_dir" -o "${resources_dir}/aidevops.icns"
  rm -rf "$iconset_dir"
  rm -f "$png_path"
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
  <key>CFBundleIconFile</key><string>aidevops.icns</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
  write_icon_assets "$resources_dir"

  cat > "${macos_dir}/aidevops-gui" <<LAUNCHER
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${root}"
API_PORT="\${AIDEVOPS_GUI_API_PORT:-8787}"
WEB_PORT="\${AIDEVOPS_GUI_WEB_PORT:-5173}"
LOG_DIR="\${HOME}/Library/Logs/aidevops-gui"
mkdir -p "\${LOG_DIR}"

cd "\${REPO_ROOT}"

notify() {
  local message="\$1"
  osascript -e "display notification \"\${message}\" with title \"aidevops\"" >/dev/null 2>&1 || true
  return 0
}

url_ready() {
  local url="\$1"
  curl --silent --fail --max-time 2 "\${url}" >/dev/null 2>&1
  return \$?
}

if [[ -f "\${HOME}/.aidevops/agents/VERSION" && -f "\${REPO_ROOT}/VERSION" ]]; then
  INSTALLED_VERSION="\$(tr -d '\n' < "\${HOME}/.aidevops/agents/VERSION")"
  RUNNING_VERSION="\$(tr -d '\n' < "\${REPO_ROOT}/VERSION")"
  if [[ "\${INSTALLED_VERSION}" != "\${RUNNING_VERSION}" ]]; then
    notify "Restart aidevops GUI after update: installed \${INSTALLED_VERSION}, app \${RUNNING_VERSION}."
  fi
fi

if ! url_ready "http://127.0.0.1:\${API_PORT}/api/status"; then
  nohup env AIDEVOPS_GUI_API_PORT="\${API_PORT}" bun run packages/gui-api/src/server.ts >"\${LOG_DIR}/api.log" 2>&1 &
fi
if ! url_ready "http://127.0.0.1:\${WEB_PORT}/"; then
  nohup bun ./node_modules/vite/bin/vite.js --host 127.0.0.1 --port "\${WEB_PORT}" packages/gui-web >"\${LOG_DIR}/web.log" 2>&1 &
fi

sleep 2
open "http://127.0.0.1:\${WEB_PORT}"
exit 0
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
