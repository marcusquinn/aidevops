---
description: Example runner templates for parallel agent dispatch
mode: reference
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Runner Templates

Ready-to-use AGENTS.md templates for common runner types. Copy and customize.

## Available Templates

| Template | Use Case |
|----------|----------|
| [code-reviewer.md](code-reviewer.md) | Security and quality code review |
| [seo-analyst.md](seo-analyst.md) | SEO analysis and recommendations |

## Creating a Runner from a Template

```bash
runner-helper.sh create my-runner --description "What it does"
runner-helper.sh edit my-runner   # paste template content
runner-helper.sh run my-runner "Your first task"
```

## Writing Your Own Runner Template

Four required sections — keep under 500 words (runners get the full prompt on every dispatch):

1. **Identity** — one sentence: who is this agent and what does it do
2. **Checklist** — specific items to check/do (not vague guidance)
3. **Output format** — exact structure of the response (tables, sections)
4. **Rules** — hard constraints (what to never do, when to escalate)

## Evolving Runners into Shared Agents

When a runner proves valuable across multiple projects:

1. **Draft** — save to `~/.aidevops/agents/draft/` with `status: draft` in frontmatter
2. **Custom** — move to `~/.aidevops/agents/custom/` for permanent private use
3. **Shared** — refine to framework standards and submit a PR to `.agents/` in the aidevops repo

Log a TODO when a runner has reuse potential: `- [ ] tXXX Review runner {name} for promotion #agent-review`

See `tools/build-agent/build-agent.md` "Agent Lifecycle Tiers" for the full promotion workflow.

## Parallel vs Sequential

See the [decision guide](headless-dispatch.md#parallel-vs-sequential) in headless-dispatch.md.
