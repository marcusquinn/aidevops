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

- **Purpose**: Persistent memory files that instruct AI CLI tools to read `~/AGENTS.md`
- **Config script**: `.agents/scripts/ai-cli-config.sh`
- **Setup**: `setup.sh` auto-creates all memory files (detects installed tools, preserves existing)
- **Warp AI / Amp Code**: Use project context only (no memory files)

<!-- AI-CONTEXT-END -->

## Memory File Locations

All files contain: `At the beginning of each session, read ~/AGENTS.md to get additional context and instructions.`

| Tool | Home directory | Project-level |
|------|---------------|---------------|
| Qwen CLI | `~/.qwen/QWEN.md` | -- |
| Claude Code | `~/CLAUDE.md` | `CLAUDE.md` |
| Gemini CLI | `~/GEMINI.md` | `GEMINI.md` |
| Cursor AI | `~/.cursorrules` | `.cursorrules` |
| GitHub Copilot | `~/.github/copilot-instructions.md` | -- |
| Factory.ai Droid | `~/.factory/DROID.md` | -- |

## Setup Integration

`ai-cli-config.sh` functions:

- `configure_qwen_cli()` — QWEN.md creation/verification
- `create_ai_memory_files()` — all home directory memory files
- `create_project_memory_files()` — all project-level memory files
