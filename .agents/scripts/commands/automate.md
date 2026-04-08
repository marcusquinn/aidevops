---
description: Route work to the Automate primary agent
agent: Automate
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Execute this request with the Automate primary agent.

Request: $ARGUMENTS

Focus on orchestration, scheduling, dispatch, monitoring, recurring routines, and automation workflows.

Capabilities include:
- **Recurring routines**: Define in routines repo (`aidevops init-routines`), dispatch via pulse. `run:` for script-only (zero LLM tokens), `agent:` for LLM-requiring. See `reference/routines.md`.
- **Worker dispatch**: `headless-runtime-helper.sh run` for task execution
- **Scheduling**: launchd (macOS) / systemd (Linux) — not crontab
- **Monitoring**: worker health, provider backoff, circuit breaker
