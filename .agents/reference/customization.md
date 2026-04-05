<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Customization Guide

aidevops is an opinionated framework. The deployed directory (`~/.aidevops/agents/`) is a build artifact that is overwritten on every update. This guide explains how to customize without fighting the update cycle.

## Extension Points

| Directory | Purpose | Survives updates | Survives clean mode |
|-----------|---------|:---:|:---:|
| `~/.aidevops/agents/custom/` | Your permanent personal agents and scripts | Yes | Yes |
| `~/.aidevops/agents/draft/` | R&D, experimental agents (may be promoted) | Yes | Yes |
| `~/.aidevops/agents/` (root) | Shared framework agents | No | No |
| `~/.aidevops/agents/scripts/` | Deployed framework scripts | No | No |

## Custom Scripts

To add a personal script that survives updates:

```bash
mkdir -p ~/.aidevops/agents/custom/scripts
cp my-script.sh ~/.aidevops/agents/custom/scripts/
chmod +x ~/.aidevops/agents/custom/scripts/my-script.sh
```

Run it: `~/.aidevops/agents/custom/scripts/my-script.sh`

To override a framework script's behaviour without modifying the original, create a wrapper in `custom/scripts/` that calls the framework script with your preferred options or pre/post-processing.

## Custom Agents

To add a personal agent:

```bash
mkdir -p ~/.aidevops/agents/custom
```

Create `~/.aidevops/agents/custom/my-agent.md` with standard frontmatter:

```yaml
---
name: my-agent
description: My personal agent for X
tools:
  read: true
  bash: true
---

Your agent instructions here.
```

Custom agents are discoverable by the framework like any other agent.

## Draft Agents

`draft/` is for experimental work — agents you're developing or testing before deciding whether to contribute upstream:

```bash
mkdir -p ~/.aidevops/agents/draft
```

The difference from `custom/` is intent: `custom/` is permanent personal tooling; `draft/` is work-in-progress that may be promoted to the shared framework or discarded.

## What NOT to Do

**Do not edit files in `~/.aidevops/agents/scripts/`** — these are deployed copies overwritten by every `aidevops update` (runs automatically every ~10 minutes). Your edits will be silently lost.

**Do not edit files in `~/.aidevops/agents/` (root level)** — same reason. These are framework agents deployed from the canonical source.

If you see a drift warning during deployment:

```text
Deployed scripts differ from canonical source (local edits will be overwritten):
  ~/.aidevops/agents/scripts/some-script.sh
    -> canonical: ~/Git/aidevops/.agents/scripts/some-script.sh
```

This means someone (or an AI session) edited the deployed copy. The fix is:

1. **Personal need?** Move your version to `custom/scripts/`
2. **Bug fix?** Edit the canonical source at `~/Git/aidevops/.agents/scripts/` and run `setup.sh --non-interactive`
3. **Framework improvement?** Fork, edit canonical source, open a PR (see "Contributing vs Customizing" below)

## Contributing vs Customizing

Before filing an issue or opening a PR, ask: **is this a personal preference or a framework gap?**

| Signal | Action |
|--------|--------|
| "I want this script to work differently for my workflow" | Customize locally (`custom/`) |
| "This script has a bug that affects everyone" | File a bug report or fix via PR |
| "The framework should support X" | File a feature request (maintainers assess fit) |
| "The framework's architecture should change" | Discuss in an issue first — architectural decisions require maintainer approval |

### What the framework accepts from everyone

- Bug reports (especially destructive behaviour)
- Bug fixes via PR
- Documentation improvements

### What requires maintainer approval before implementation

- Adding integrations with third-party tools
- Changing default behaviours or configuration structure
- Adding new dependencies
- Modifying the agent framework architecture (deploy pipeline, update cycle, directory structure)

See [CONTRIBUTING.md](../../CONTRIBUTING.md#scope-of-contributions) for the full policy.

### For AI sessions

If your AI assistant encounters a limitation or unexpected behaviour:

1. **Check if `custom/` solves it** — most "I want it to work differently" needs are customization, not bugs
2. **Use `/log-issue-aidevops`** — it includes an architectural alignment check that routes customization needs away from the issue tracker
3. **Do not implement architectural changes** without maintainer approval, even if the change seems obviously beneficial

## Configuration Files

User configuration files (`~/.config/aidevops/`) are never overwritten by updates:

- `repos.json` — registered repositories
- `credentials.sh` — secrets (600 permissions)
- `plugins.json` — enabled plugins
- `settings.json` — user preferences

These are the correct place for per-user settings. See `reference/configuration.md` and `reference/settings.md`.
