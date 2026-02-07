---
description: Example runner templates for parallel agent dispatch
mode: reference
---

# Runner Templates

Ready-to-use AGENTS.md templates for common runner types. Copy and customize for your needs.

## Available Templates

| Template | Use Case |
|----------|----------|
| [code-reviewer.md](code-reviewer.md) | Security and quality code review |
| [seo-analyst.md](seo-analyst.md) | SEO analysis and recommendations |

## Creating a Runner from a Template

```bash
# 1. Create the runner
runner-helper.sh create my-runner --description "What it does"

# 2. Open the AGENTS.md for editing
runner-helper.sh edit my-runner

# 3. Paste the template content from the files above

# 4. Test it
runner-helper.sh run my-runner "Your first task"
```

## Writing Your Own Runner Template

A good runner AGENTS.md has four sections:

1. **Identity** - One sentence: who is this agent and what does it do
2. **Checklist** - Specific items to check/do (not vague guidance)
3. **Output format** - Exact structure of the response (tables, sections)
4. **Rules** - Hard constraints (what to never do, when to escalate)

Keep it under 500 words. Runners get the full prompt on every dispatch, so brevity matters.

## Evolving Runners into Shared Agents

When a runner proves valuable across multiple projects, consider promoting it:

1. **Draft** -- Save to `~/.aidevops/agents/draft/` with `status: draft` in frontmatter
2. **Custom** -- Move to `~/.aidevops/agents/custom/` for permanent private use
3. **Shared** -- Refine to framework standards and submit a PR to `.agents/` in the aidevops repo

Log a TODO item when a runner has reuse potential: `- [ ] tXXX Review runner {name} for promotion #agent-review`

See `tools/build-agent/build-agent.md` "Agent Lifecycle Tiers" for the full promotion workflow.

## Parallel vs Sequential

See the [decision guide](../headless-dispatch.md#parallel-vs-sequential) in headless-dispatch.md.
