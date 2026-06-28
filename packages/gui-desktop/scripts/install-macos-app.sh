#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

APP_NAME="aidevops.app"
DEFAULT_APP_DIR="/Applications"

usage() {
  printf 'Usage: %s [--check] [--app-dir DIR]\n' "$0"
  printf 'Environment: AIDEVOPS_GUI_DESKTOP_APP_DIR overrides the default app directory.\n'
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
  if [[ ! -f "${root}/VERSION" ]]; then
    printf 'repo root missing VERSION: %s\n' "$root" >&2
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
  if ! command -v swiftc >/dev/null 2>&1; then
    printf 'macOS swiftc is required to build the native WebKit app wrapper\n' >&2
    return 1
  fi

  return 0
}

gui_dependencies_present() {
  local root="$1"

  [[ -f "${root}/node_modules/vite/bin/vite.js" && -d "${root}/node_modules/react" && -d "${root}/node_modules/react-icons" ]]
  return $?
}

ensure_gui_dependencies() {
  local root="$1"

  if gui_dependencies_present "$root"; then
    return 0
  fi

  if [[ ! -f "${root}/bun.lock" ]]; then
    printf 'GUI dependencies are missing and bun.lock was not found in %s\n' "$root" >&2
    return 1
  fi

  printf 'Installing GUI dependencies with bun install --frozen-lockfile...\n'
  if ! (cd "$root" && bun install --frozen-lockfile); then
    printf 'GUI dependency installation failed in %s\n' "$root" >&2
    return 1
  fi

  if ! gui_dependencies_present "$root"; then
    printf 'GUI dependencies are still missing after bun install in %s\n' "$root" >&2
    return 1
  fi

  return 0
}

app_version() {
  local root="$1"

  tr -d '\n' < "${root}/VERSION"
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
  <g transform="translate(36 36) scale(0.86)">
    <path fill="#B2E969" d="M73.4 150.6c-12.5-12.5-12.5-32.8 0-45.3s32.8-12.5 45.3 0l160 160c12.5 12.5 12.5 32.8 0 45.3l-160 160c-12.5 12.5-32.8 12.5-45.3 0s-12.5-32.8 0-45.3L210.7 288 73.4 150.6zM240 400h192c17.7 0 32 14.3 32 32s-14.3 32-32 32H240c-17.7 0-32-14.3-32-32s14.3-32 32-32z"/>
  </g>
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

write_service_helper() {
  local root="$1"
  local resources_dir="$2"
  local helper_path="${resources_dir}/aidevops-gui-services.sh"

  cat > "$helper_path" <<LAUNCHER
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${root}"
API_PORT="\${AIDEVOPS_GUI_API_PORT:-8787}"
WEB_PORT="\${AIDEVOPS_GUI_WEB_PORT:-5173}"
API_HEALTH_URL="http://127.0.0.1:\${API_PORT}/api/health"
WEB_HEALTH_URL="http://127.0.0.1:\${WEB_PORT}/"
LOG_DIR="\${HOME}/Library/Logs/aidevops-gui"
LAUNCHER_LOG="\${LOG_DIR}/launcher.log"
BUN_BIN=""
MODE="\${1:-start}"
PATH="\${HOME}/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\${PATH:-}"
export PATH
mkdir -p "\${LOG_DIR}"

cd "\${REPO_ROOT}"

notify() {
  local message="\$1"
  osascript -e "display notification \"\${message}\" with title \"aidevops\"" >/dev/null || true
  return 0
}

url_ready() {
  local url="\$1"
  curl --silent --fail --max-time 2 "\${url}" >/dev/null 2>&1
  return \$?
}

wait_for_url() {
  local url="\$1"
  local attempts="\$2"
  local delay="\$3"
  local attempt=1

  while [[ "\${attempt}" -le "\${attempts}" ]]; do
    if url_ready "\${url}"; then
      return 0
    fi
    sleep "\${delay}"
    attempt=\$((attempt + 1))
  done

  return 1
}

require_bun() {
  local found=""

  found="\$(command -v bun || true)"
  if [[ -z "\${found}" ]]; then
    printf 'bun is required to launch aidevops GUI; PATH=%s\n' "\${PATH}" >"\${LAUNCHER_LOG}"
    notify "aidevops GUI cannot find bun. Install bun or add it to ~/.bun/bin."
    return 1
  fi
  BUN_BIN="\${found}"
  return 0
}

port_pids() {
  local port="\$1"

  lsof -t -nP -iTCP:"\${port}" -sTCP:LISTEN 2>/dev/null || true
  return 0
}

pid_cwd() {
  local pid="\$1"
  local line=""

  while IFS= read -r line; do
    case "\${line}" in
      n*)
        printf '%s\n' "\${line#n}"
        return 0
        ;;
    esac
  done < <(lsof -a -p "\${pid}" -d cwd -Fn 2>/dev/null)

  return 1
}

is_aidevops_checkout() {
  local candidate="\$1"

  [[ -f "\${candidate}/aidevops.sh" && -f "\${candidate}/packages/gui-web/vite.config.ts" ]]
  return \$?
}

replace_stale_gui_on_port() {
  local port="\$1"
  local health_url="\$2"
  local pid=""
  local cwd=""

  if url_ready "\${health_url}"; then
    while IFS= read -r pid; do
      if [[ -z "\${pid}" ]]; then
        continue
      fi
      cwd="\$(pid_cwd "\${pid}" || true)"
      if [[ "\${cwd}" == "\${REPO_ROOT}" ]]; then
        return 0
      fi
    done < <(port_pids "\${port}")
  fi

  while IFS= read -r pid; do
    if [[ -z "\${pid}" ]]; then
      continue
    fi
    cwd="\$(pid_cwd "\${pid}" || true)"
    if [[ -n "\${cwd}" ]] && is_aidevops_checkout "\${cwd}"; then
      kill "\${pid}" >/dev/null 2>&1 || true
    fi
  done < <(port_pids "\${port}")

  return 0
}

kill_gui_on_port_for_repo() {
  local port="\$1"
  local pid=""
  local cwd=""

  while IFS= read -r pid; do
    if [[ -z "\${pid}" ]]; then
      continue
    fi
    cwd="\$(pid_cwd "\${pid}" || true)"
    if [[ "\${cwd}" == "\${REPO_ROOT}" ]]; then
      kill "\${pid}" >/dev/null 2>&1 || true
    fi
  done < <(port_pids "\${port}")

  return 0
}

stop_gui_services() {
  kill_gui_on_port_for_repo "\${API_PORT}"
  kill_gui_on_port_for_repo "\${WEB_PORT}"
  return 0
}

if [[ "\${MODE}" == "stop" ]]; then
  stop_gui_services
  exit 0
fi

if [[ -f "\${HOME}/.aidevops/agents/VERSION" && -f "\${REPO_ROOT}/VERSION" ]]; then
  INSTALLED_VERSION="\$(tr -d '\n' < "\${HOME}/.aidevops/agents/VERSION")"
  RUNNING_VERSION="\$(tr -d '\n' < "\${REPO_ROOT}/VERSION")"
  if [[ "\${INSTALLED_VERSION}" != "\${RUNNING_VERSION}" ]]; then
    notify "Restart aidevops GUI after update: installed \${INSTALLED_VERSION}, app \${RUNNING_VERSION}."
  fi
fi

replace_stale_gui_on_port "\${API_PORT}" "\${API_HEALTH_URL}"
replace_stale_gui_on_port "\${WEB_PORT}" "\${WEB_HEALTH_URL}"
sleep 1

if ! url_ready "\${API_HEALTH_URL}" || ! url_ready "\${WEB_HEALTH_URL}"; then
  require_bun
fi

if ! url_ready "\${API_HEALTH_URL}"; then
  nohup env AIDEVOPS_GUI_API_PORT="\${API_PORT}" "\${BUN_BIN}" run packages/gui-api/src/server.ts >"\${LOG_DIR}/api.log" 2>&1 &
fi
if ! url_ready "\${WEB_HEALTH_URL}"; then
  nohup "\${BUN_BIN}" ./node_modules/vite/bin/vite.js --config packages/gui-web/vite.config.ts --host 127.0.0.1 --port "\${WEB_PORT}" >"\${LOG_DIR}/web.log" 2>&1 &
fi

if ! wait_for_url "\${API_HEALTH_URL}" 20 0.25; then
  printf 'aidevops GUI API did not become ready. Check %s/api.log.\n' "\${LOG_DIR}" >"\${LAUNCHER_LOG}"
  notify "aidevops GUI API did not become ready. Check \${LOG_DIR}/api.log."
  exit 1
fi
if ! wait_for_url "\${WEB_HEALTH_URL}" 30 0.25; then
  printf 'aidevops GUI web did not become ready. Check %s/web.log.\n' "\${LOG_DIR}" >"\${LAUNCHER_LOG}"
  notify "aidevops GUI web did not become ready. Check \${LOG_DIR}/web.log."
  exit 1
fi

printf 'aidevops GUI services ready: API %s, web %s\n' "\${API_HEALTH_URL}" "\${WEB_HEALTH_URL}" >"\${LAUNCHER_LOG}"
exit 0
LAUNCHER
  chmod 755 "$helper_path"
  return 0
}

write_webview_source() {
  local resources_dir="$1"
  local swift_source="${resources_dir}/aidevops-gui.swift"

  cat > "$swift_source" <<'SWIFT'
import AppKit
import WebKit

final class DraggableTitlebarView: NSView {
    override var mouseDownCanMoveWindow: Bool {
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSMenuItemValidation, NSWindowDelegate {
    private var window: NSWindow!
    private var aboutWindow: NSWindow?
    private var titlebarToggleButton: NSButton?
    private var webView: WKWebView!
    private let apiPort = ProcessInfo.processInfo.environment["AIDEVOPS_GUI_API_PORT"] ?? "8787"
    private let webPort = ProcessInfo.processInfo.environment["AIDEVOPS_GUI_WEB_PORT"] ?? "5173"
    private let defaultAccentHue: CGFloat = 123
    private let mainWindowFrameAutosaveName = "aidevops-main-window"
    private let titlebarHeight: CGFloat = 24
    private let serviceQueue = DispatchQueue(label: "sh.aidevops.gui.services")
    private var hasLoadedDashboard = false
    private var servicesStopped = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        configureWindow()
        loadStatusHTML(title: "Starting aidevops", detail: "Preparing the local read-only GUI services…")
        startServicesAndLoadApp()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        saveMainWindowFrame()
        stopServices()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        saveMainWindowFrame()
        stopServices()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openDashboard(nil)
        }
        return true
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "accentHue" else {
            return
        }

        if let number = message.body as? NSNumber {
            updateTitlebarAccent(hue: CGFloat(number.doubleValue))
            return
        }

        if let value = message.body as? String, let hue = Double(value) {
            updateTitlebarAccent(hue: CGFloat(hue))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if isLocalAppURL(url) {
            decisionHandler(.allow)
            return
        }

        if url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else {
            return nil
        }

        if url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }

        return nil
    }

    private func isLocalAppURL(_ url: URL) -> Bool {
        let host = url.host ?? ""
        return (host == "127.0.0.1" || host == "localhost") && url.port == Int(webPort)
    }

    private func configureMenu() {
        let appName = "aidevops"
        let mainMenu = NSMenu(title: "Main Menu")

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: appName)
        appMenu.addItem(menuItem("About \(appName)", action: #selector(showAbout(_:)), target: self))
        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        appMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu

        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("Hide \(appName)", action: #selector(NSApplication.hide(_:)), key: "h", target: NSApp))
        appMenu.addItem(menuItem("Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option], target: NSApp))
        appMenu.addItem(menuItem("Show All", action: #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("Quit \(appName)", action: #selector(quitApplication(_:)), key: "q", target: self))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(menuItem("Open Dashboard", action: #selector(openDashboard(_:)), key: "n", target: self))
        fileMenu.addItem(.separator())
        fileMenu.addItem(menuItem("Close Window", action: #selector(NSWindow.performClose(_:)), key: "w"))
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(menuItem("Undo", action: Selector(("undo:")), key: "z"))
        editMenu.addItem(menuItem("Redo", action: Selector(("redo:")), key: "Z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem("Cut", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(menuItem("Copy", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(menuItem("Paste", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(menuItem("Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), key: "v", modifiers: [.command, .option, .shift]))
        editMenu.addItem(menuItem("Delete", action: #selector(NSText.delete(_:))))
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem("Select All", action: #selector(NSText.selectAll(_:)), key: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(menuItem("Reload Page", action: #selector(reloadPage(_:)), key: "r", target: self))
        viewMenu.addItem(menuItem("Stop Loading", action: #selector(stopLoading(_:)), key: ".", target: self))
        viewMenu.addItem(.separator())
        viewMenu.addItem(menuItem("Back", action: #selector(goBack(_:)), key: "[", target: self))
        viewMenu.addItem(menuItem("Forward", action: #selector(goForward(_:)), key: "]", target: self))
        viewMenu.addItem(.separator())
        viewMenu.addItem(menuItem("Actual Size", action: #selector(resetZoom(_:)), key: "0", target: self))
        viewMenu.addItem(menuItem("Zoom In", action: #selector(zoomIn(_:)), key: "+", target: self))
        viewMenu.addItem(menuItem("Zoom Out", action: #selector(zoomOut(_:)), key: "-", target: self))
        viewMenu.addItem(.separator())
        viewMenu.addItem(menuItem("Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control]))
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(menuItem("Minimize", action: #selector(NSWindow.miniaturize(_:)), key: "m"))
        windowMenu.addItem(menuItem("Zoom", action: #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(menuItem("Hide Window", action: #selector(hideWindow(_:)), key: "h", modifiers: [.command, .shift], target: self))
        windowMenu.addItem(.separator())
        windowMenu.addItem(menuItem("Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), target: NSApp))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(menuItem("aidevops Help", action: #selector(showHelp(_:)), key: "?", modifiers: [.command, .shift], target: self))
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    private func menuItem(_ title: String, action: Selector?, key: String = "", modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = target
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)):
            return webView?.canGoBack ?? false
        case #selector(goForward(_:)):
            return webView?.canGoForward ?? false
        case #selector(reloadPage(_:)), #selector(stopLoading(_:)), #selector(resetZoom(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)):
            return webView != nil
        default:
            return true
        }
    }

    @objc private func showAbout(_ sender: Any?) {
        if let existingWindow = aboutWindow {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let about = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        about.title = "About aidevops"
        about.isReleasedWhenClosed = false

        let content = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 28, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = aboutLabel("aidevops", font: .systemFont(ofSize: 28, weight: .bold), color: .labelColor)
        let versionLabel = aboutLabel("Version \(version)", font: .systemFont(ofSize: 13, weight: .semibold), color: .secondaryLabelColor)
        let detail = aboutLabel("Native macOS WebKit wrapper for the local read-only aidevops GUI. It provides AI-assisted development workflows, code quality, and deployment automation without exposing secrets or shell write routes.", font: .systemFont(ofSize: 13), color: .labelColor)
        let copyright = aboutLabel("Copyright © 2025-2026 Marcus Quinn. Licensed under the MIT License.", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY
        buttonRow.addArrangedSubview(aboutButton("Website", action: #selector(openWebsite(_:))))
        buttonRow.addArrangedSubview(aboutButton("GitHub Repository", action: #selector(openGitHub(_:))))

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(versionLabel)
        stack.addArrangedSubview(detail)
        stack.addArrangedSubview(buttonRow)
        stack.addArrangedSubview(copyright)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor)
        ])

        about.contentView = content
        about.center()
        aboutWindow = about
        about.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func aboutLabel(_ value: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(lessThanOrEqualToConstant: 462).isActive = true
        return field
    }

    private func aboutButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    @objc private func openWebsite(_ sender: Any?) {
        openExternalURL("https://aidevops.sh")
    }

    @objc private func openGitHub(_ sender: Any?) {
        openExternalURL("https://github.com/marcusquinn/aidevops")
    }

    private func openExternalURL(_ value: String) {
        guard let url = URL(string: value) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openDashboard(_ sender: Any?) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !hasLoadedDashboard {
            loadAppURL()
        }
    }

    @objc private func hideWindow(_ sender: Any?) {
        saveMainWindowFrame()
        window.orderOut(nil)
    }

    @objc private func quitApplication(_ sender: Any?) {
        saveMainWindowFrame()
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        saveMainWindowFrame()
    }

    @objc private func reloadPage(_ sender: Any?) {
        webView.reload()
    }

    @objc private func stopLoading(_ sender: Any?) {
        webView.stopLoading()
    }

    @objc private func goBack(_ sender: Any?) {
        if webView.canGoBack {
            webView.goBack()
        }
    }

    @objc private func goForward(_ sender: Any?) {
        if webView.canGoForward {
            webView.goForward()
        }
    }

    @objc private func resetZoom(_ sender: Any?) {
        webView.pageZoom = 1.0
    }

    @objc private func zoomIn(_ sender: Any?) {
        webView.pageZoom = min(webView.pageZoom + 0.1, 3.0)
    }

    @objc private func zoomOut(_ sender: Any?) {
        webView.pageZoom = max(webView.pageZoom - 0.1, 0.5)
    }

    @objc private func showHelp(_ sender: Any?) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        loadStatusHTML(title: "aidevops Help", detail: "Use the app menus for standard editing, view controls, reload/navigation, window management, and help. The desktop wrapper runs the local read-only aidevops GUI in WebKit.")
    }

    private func configureWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let userContentController = WKUserContentController()
        userContentController.add(self, name: "accentHue")
        configuration.userContentController = userContentController
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        let contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        let titlebarOverlay = makeTitlebarOverlay()
        contentContainer.addSubview(webView)
        contentContainer.addSubview(titlebarOverlay)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            webView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            titlebarOverlay.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            titlebarOverlay.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            titlebarOverlay.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            titlebarOverlay.heightAnchor.constraint(equalToConstant: titlebarHeight)
        ])

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "aidevops"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName(mainWindowFrameAutosaveName)
        window.contentView = contentContainer
        if !window.setFrameUsingName(mainWindowFrameAutosaveName) {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeTitlebarOverlay() -> NSView {
        let overlay = DraggableTitlebarView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        let defaultButtonAccent = accentColor(hueDegrees: defaultAccentHue, alpha: 0.9)

        let toggleButton = NSButton(frame: .zero)
        toggleButton.action = #selector(toggleMachineRail(_:))
        toggleButton.bezelStyle = .regularSquare
        toggleButton.contentTintColor = defaultButtonAccent
        toggleButton.image = sidebarToggleImage()
        toggleButton.imagePosition = .imageOnly
        toggleButton.isBordered = false
        toggleButton.setButtonType(.momentaryChange)
        toggleButton.target = self
        toggleButton.toolTip = "Hide or show the machine sidebar"
        toggleButton.translatesAutoresizingMaskIntoConstraints = false

        overlay.addSubview(toggleButton)
        titlebarToggleButton = toggleButton
        NSLayoutConstraint.activate([
            toggleButton.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 92),
            toggleButton.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: 3.5),
            toggleButton.heightAnchor.constraint(equalToConstant: 22),
            toggleButton.widthAnchor.constraint(equalToConstant: 22)
        ])

        return overlay
    }

    private func updateTitlebarAccent(hue: CGFloat) {
        let normalizedHue = min(359, max(0, hue))
        titlebarToggleButton?.contentTintColor = accentColor(hueDegrees: normalizedHue, alpha: 0.9)
    }

    private func accentColor(hueDegrees: CGFloat, alpha: CGFloat) -> NSColor {
        let hue = hueDegrees.truncatingRemainder(dividingBy: 360) / 360
        let saturation: CGFloat = 0.74
        let lightness: CGFloat = 0.66
        let chroma = (1 - abs((2 * lightness) - 1)) * saturation
        let huePrime = hue * 6
        let x = chroma * (1 - abs(huePrime.truncatingRemainder(dividingBy: 2) - 1))
        let match = lightness - (chroma / 2)
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        if huePrime < 1 {
            red = chroma
            green = x
            blue = 0
        } else if huePrime < 2 {
            red = x
            green = chroma
            blue = 0
        } else if huePrime < 3 {
            red = 0
            green = chroma
            blue = x
        } else if huePrime < 4 {
            red = 0
            green = x
            blue = chroma
        } else if huePrime < 5 {
            red = x
            green = 0
            blue = chroma
        } else {
            red = chroma
            green = 0
            blue = x
        }

        return NSColor(srgbRed: red + match, green: green + match, blue: blue + match, alpha: alpha)
    }

    private func sidebarToggleImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            let outer = NSBezierPath(roundedRect: NSRect(x: 3, y: 3, width: 14, height: 14), xRadius: 3, yRadius: 3)
            outer.lineWidth = 2.2
            NSColor.labelColor.setStroke()
            outer.stroke()

            let divider = NSBezierPath()
            divider.lineWidth = 2
            divider.move(to: NSPoint(x: 8, y: 4))
            divider.line(to: NSPoint(x: 8, y: 16))
            divider.stroke()

            let notchTop = NSBezierPath()
            notchTop.lineWidth = 1.7
            notchTop.move(to: NSPoint(x: 4.8, y: 12.4))
            notchTop.line(to: NSPoint(x: 6.1, y: 12.4))
            notchTop.stroke()

            let notchBottom = NSBezierPath()
            notchBottom.lineWidth = 1.7
            notchBottom.move(to: NSPoint(x: 4.8, y: 7.6))
            notchBottom.line(to: NSPoint(x: 6.1, y: 7.6))
            notchBottom.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func toggleMachineRail(_ sender: Any?) {
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('aidevops:toggle-machine-rail')); true;", completionHandler: nil)
    }

    private func saveMainWindowFrame() {
        guard window != nil else {
            return
        }
        window.saveFrame(usingName: mainWindowFrameAutosaveName)
    }

    private func startServicesAndLoadApp() {
        serviceQueue.async {
            if self.servicesStopped {
                return
            }
            let result = self.runServiceHelper()
            if self.servicesStopped {
                return
            }
            DispatchQueue.main.async {
                if result.ok {
                    self.loadAppURL()
                } else {
                    self.loadStatusHTML(title: "aidevops could not start", detail: result.message)
                }
            }
        }
    }

    private func runServiceHelper() -> (ok: Bool, message: String) {
        return runServiceHelper(arguments: [])
    }

    private func stopServices() {
        serviceQueue.sync {
            if servicesStopped {
                return
            }
            servicesStopped = true
            _ = runServiceHelper(arguments: ["stop"])
        }
    }

    private func runServiceHelper(arguments: [String]) -> (ok: Bool, message: String) {
        guard let helperPath = Bundle.main.path(forResource: "aidevops-gui-services", ofType: "sh") else {
            return (false, "The bundled service helper is missing from aidevops.app.")
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helperPath] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["AIDEVOPS_GUI_WRAPPER"] = "webkit"
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if process.terminationStatus == 0 {
                return (true, output)
            }
            if output.isEmpty {
                return (false, "The local GUI services exited with status \(process.terminationStatus). Check ~/Library/Logs/aidevops-gui/.")
            }
            return (false, output)
        } catch {
            return (false, "Could not launch the local GUI service helper: \(error.localizedDescription)")
        }
    }

    private func loadAppURL() {
        guard let url = URL(string: "http://127.0.0.1:\(webPort)/?desktop=macos") else {
            loadStatusHTML(title: "Invalid aidevops URL", detail: "The configured web port is not valid: \(webPort)")
            return
        }
        hasLoadedDashboard = true
        webView.load(URLRequest(url: url))
    }

    private func loadStatusHTML(title: String, detail: String) {
        let escapedTitle = escapeHTML(title)
        let escapedDetail = escapeHTML(detail).replacingOccurrences(of: "\n", with: "<br>")
        let contentHTML: String
        if title == "Starting aidevops" {
            contentHTML = """
            <main class="shell" aria-busy="true" aria-label="Loading aidevops interface">
              <section class="brand" aria-label="Starting aidevops"><strong><span>aidevops</span><b>&gt;</b><em>_</em></strong><small>Preparing local GUI</small></section>
              <aside class="rail panel"><i></i><i></i><i></i><i></i><i></i><i></i></aside>
              <aside class="sidebar panel"><header><b></b><span></span></header><nav><i></i><i></i><i></i><i></i><i></i><i></i><i></i><i></i></nav><footer><i></i><i></i></footer></aside>
              <section class="workspace panel"><header><b></b><span></span><i></i><i></i></header><article><h1>\(escapedTitle)</h1><p>\(escapedDetail)</p><div class="cards"><i></i><i></i><i></i><i></i><i></i><i></i></div><div class="block"></div></article></section>
              <footer class="status"><i></i><span></span><span></span><span></span><span></span><span></span></footer>
            </main>
            """
        } else {
            contentHTML = "<main class=\"message\"><h1>\(escapedTitle)</h1><p>\(escapedDetail)</p></main>"
        }
        let html = """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            :root { --accent: hsl(123 74% 66%); --border: rgb(255 255 255 / 11%); --panel: #151515; --muted: rgb(255 255 255 / 70%); }
            * { box-sizing: border-box; }
            body { background: radial-gradient(ellipse at top left, hsl(123 74% 66% / 16%), transparent 36%), #111; color: #fff; font: 15px -apple-system, BlinkMacSystemFont, sans-serif; height: 100vh; margin: 0; }
            .message { background: var(--panel); border: 1px solid var(--border); border-radius: 18px; left: 50%; max-width: 560px; padding: 28px; position: fixed; top: 50%; transform: translate(-50%, -50%); }
            h1 { font-size: 22px; margin: 0 0 10px; }
            p { color: #b9c3b0; line-height: 1.5; margin: 0; }
            code { color: var(--accent); }
            .shell { display: grid; gap: 8px; grid-template-columns: 72px 302px minmax(0, 1fr); grid-template-rows: minmax(0, 1fr) 30px; height: 100vh; padding: 30px 8px 8px; }
            .brand { align-items: center; backdrop-filter: blur(18px); background: rgb(10 10 10 / 78%); border: 1px solid hsl(123 74% 66% / 34%); border-radius: 24px; box-shadow: 0 24px 90px hsl(123 74% 66% / 14%), 0 24px 80px rgb(0 0 0 / 40%); display: grid; gap: 10px; justify-items: center; left: 50%; padding: 26px 30px; position: fixed; top: 50%; transform: translate(-50%, -50%); width: min(360px, calc(100vw - 48px)); z-index: 20; }
            .brand strong { align-items: baseline; display: inline-flex; font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; font-size: clamp(34px, 7vw, 64px); font-weight: 900; letter-spacing: -0.08em; line-height: .9; }
            .brand span { color: #f6f7f2; font-size: .48em; letter-spacing: -0.04em; margin-right: .18em; }
            .brand b, .brand em { color: var(--accent); font-style: normal; }
            .brand em { animation: cursor 0.95s steps(1, end) infinite; }
            .brand small { color: var(--muted); font-size: 11px; font-weight: 800; letter-spacing: .1em; text-transform: uppercase; }
            .panel, .status { background: rgb(17 19 15 / 92%); border: 1px solid var(--border); border-radius: 18px; box-shadow: inset 0 1px 0 rgb(255 255 255 / 8%); overflow: hidden; }
            .rail { align-content: start; display: grid; gap: 10px; justify-items: center; padding: 12px 8px; }
            .rail i, .sidebar b, .workspace b { border-radius: 12px; height: 44px; width: 44px; }
            .sidebar { display: grid; grid-template-rows: auto 1fr auto; }
            .sidebar header, .workspace header { align-items: center; display: flex; gap: 12px; padding: 16px; }
            .sidebar header span { flex: 1; height: 18px; }
            .sidebar nav, .sidebar footer, .workspace article { display: grid; gap: 12px; padding: 16px; }
            .sidebar nav i { height: 18px; }
            .sidebar footer { border-top: 1px solid var(--border); }
            .workspace { display: grid; grid-template-rows: auto 1fr; }
            .workspace header { border-bottom: 1px solid var(--border); }
            .workspace header span { flex: 1; height: 38px; }
            .workspace header i { border-radius: 999px; height: 34px; width: 34px; }
            .workspace article { align-content: start; gap: 18px; }
            .cards { display: grid; gap: 14px; grid-template-columns: repeat(3, minmax(0, 1fr)); }
            .cards i { border-radius: 18px; height: 128px; }
            .block { border-radius: 20px; height: 220px; }
            .status { align-items: center; display: flex; gap: 10px; grid-column: 1 / -1; justify-content: center; padding: 0 12px; }
            .status i { border-radius: 999px; height: 8px; width: 8px; }
            .status span { height: 10px; width: 96px; }
            .rail i, .sidebar b, .sidebar span, .sidebar i, .workspace b, .workspace span, .workspace i, .cards i, .block, .status i, .status span { animation: pulse 1.35s ease-in-out infinite; background: linear-gradient(90deg, #202020, hsl(123 74% 66% / 16%), #202020); background-size: 220% 100%; border: 1px solid var(--border); border-radius: 999px; display: block; }
            .block, .cards i { border-radius: 18px; }
            @keyframes pulse { 0% { background-position: 120% 0; opacity: .52; } 50% { opacity: .95; } 100% { background-position: -120% 0; opacity: .52; } }
            @keyframes cursor { 0%, 48% { opacity: 1; } 49%, 100% { opacity: 0; } }
            @media (prefers-reduced-motion: reduce) { .rail i, .sidebar b, .sidebar span, .sidebar i, .workspace b, .workspace span, .workspace i, .cards i, .block, .status i, .status span, .brand em { animation: none; } }
          </style>
        </head>
        <body>\(contentHTML)</body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func escapeHTML(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
SWIFT
  return 0
}

compile_webview_app() {
  local resources_dir="$1"
  local macos_dir="$2"
  local swift_source="${resources_dir}/aidevops-gui.swift"

  env MACOSX_DEPLOYMENT_TARGET=13.0 swiftc -framework AppKit -framework WebKit "$swift_source" -o "${macos_dir}/aidevops-gui"
  chmod 755 "${macos_dir}/aidevops-gui"
  return 0
}

write_app_bundle() {
  local root="$1"
  local app_dir="$2"
  local app_path="${app_dir}/${APP_NAME}"
  local contents_dir="${app_path}/Contents"
  local macos_dir="${contents_dir}/MacOS"
  local resources_dir="${contents_dir}/Resources"
  local version=""

  version="$(app_version "$root")"

  mkdir -p "$macos_dir" "$resources_dir"
  cat > "${contents_dir}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>aidevops</string>
  <key>CFBundleDisplayName</key><string>aidevops</string>
  <key>CFBundleIdentifier</key><string>sh.aidevops.gui</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleExecutable</key><string>aidevops-gui</string>
  <key>CFBundleIconFile</key><string>aidevops.icns</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
  write_icon_assets "$resources_dir"
  write_service_helper "$root" "$resources_dir"
  write_webview_source "$resources_dir"
  compile_webview_app "$resources_dir" "$macos_dir"
  printf 'Installed %s\n' "$app_path"
  return 0
}

main() {
  local mode="install"
  local app_dir="${AIDEVOPS_GUI_DESKTOP_APP_DIR:-$DEFAULT_APP_DIR}"
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
    if ! gui_dependencies_present "$root"; then
      printf 'GUI dependencies are missing; run bun install --frozen-lockfile in %s\n' "$root" >&2
      return 1
    fi
    printf 'macOS app bundle check passed for %s\n' "$root"
    return 0
  fi
  ensure_gui_dependencies "$root"
  write_app_bundle "$root" "$app_dir"
  return 0
}

main "$@"
