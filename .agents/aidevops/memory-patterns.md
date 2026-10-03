---
description: AI memory files system patterns
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: false
  glob: true
  grep: true
  webfetch: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# AI Memory Files System

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Legacy memory files**: Some existing AI CLI memory files may instruct tools to read `~/AGENTS.md`; setup no longer creates them.
- **Current config**: `.agents/scripts/ai-cli-config.sh` configures OpenAPI search MCP, not memory files.
- **Migration**: `_home_agents_md_is_referenced` in `.agents/scripts/setup/modules/migrations.sh` preserves `~/AGENTS.md` while a legacy memory file still points at it.

<!-- AI-CONTEXT-END -->

## Historical Memory File Locations

These are historical locations, not files created by current setup. Existing files may contain: `At the beginning of each session, read ~/AGENTS.md to get additional context and instructions.`

| Tool | Home directory | Project-level |
|------|---------------|---------------|
| Qwen CLI | `~/.qwen/QWEN.md` | -- |
| Claude Code | `~/CLAUDE.md` | `CLAUDE.md` |
| Gemini CLI | `~/GEMINI.md` | `GEMINI.md` |
| Cursor AI | `~/.cursorrules` | `.cursorrules` |
| GitHub Copilot | `~/.github/copilot-instructions.md` | -- |
| Factory.ai Droid | `~/.factory/DROID.md` | -- |
