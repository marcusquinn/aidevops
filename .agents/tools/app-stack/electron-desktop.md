---
description: Electron desktop defaults and safety rules for TypeScript app stacks
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Electron Desktop

Electron is the default desktop shell when the app benefits from Chromium fidelity, DevTools, browser automation, extension reuse, or rich web UI reuse.

## Use Electron when

- The desktop app is primarily a web app with local capabilities.
- Chromium behaviour, DevTools, or browser automation/debugging is valuable.
- You need extension-adjacent code reuse or web platform APIs.
- PGlite/filesystem storage can run in the main process.

## Consider Tauri/native when

- Bundle size, native platform integration, or strict attack-surface minimisation dominates.
- The UI is small and does not need Chromium-specific behaviour.
- The team is prepared to maintain Rust/native integration code.

## Architecture rules

- Main process owns filesystem, secrets, database, OS integration, and migrations.
- Renderer owns UI only.
- Preload exposes a typed, narrow API.
- Never expose raw SQL or filesystem paths over IPC.
- Prefer named operations (`items:list`, `settings:update`) over generic RPC.
- Validate every IPC payload at the boundary.
- Keep secrets in OS/aidevops secret storage, not renderer local storage.

## Local data

- Use Postgres on the server as the canonical store.
- Use PGlite in Electron main process only when shared Postgres schema is useful.
- Bundle migrations as app resources and run them from the main process.
- Use a mutex/queue around local writes; PGlite has single-connection constraints.

## Verification

- Typecheck main/preload/renderer boundaries.
- Test packaged and dev migration paths.
- Verify renderer cannot call arbitrary SQL, filesystem, or shell commands.
- Verify app launch handles database startup latency with a loading state.
