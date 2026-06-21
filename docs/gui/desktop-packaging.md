<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# GUI desktop packaging

The first desktop step is an unsigned macOS `.app` launcher that can be placed in
`/Applications` and opens the existing local read-only web/API scaffold. This is
not the final Tauri wrapper; it is the smallest local-first bridge so users can
open aidevops from the Applications folder while the web/API contract stabilises.

Install locally on macOS:

```bash
npm run gui:desktop:install:macos
```

The app starts the read-only Hono API on `127.0.0.1:8787`, starts the Vite web
dashboard on `127.0.0.1:5173`, opens the dashboard in the default browser, and
then exits so it does not leave a frozen Dock-only shell app. It reuses existing
servers when those local ports are already healthy. It does not add write,
destructive, Cloudron-control, pairing, shell, or exec routes.

The bundle icon is generated from the same terminal-glyph SVG used by the
`aidevops.sh` website favicon.

For test installs without writing to `/Applications`:

```bash
bash packages/gui-desktop/scripts/install-macos-app.sh --app-dir /tmp/aidevops-app-test
```

The eventual Tauri package must replace this launcher before signed desktop
release artifacts or auto-updates are published.
