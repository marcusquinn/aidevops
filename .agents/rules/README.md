---
description: TTSR rule directory — soft correction rules for AI agent output
---

# TTSR Rules

Soft TTSR (Think-Then-Self-Reflect) rules that detect patterns in AI output and inject correction instructions.

## Rule File Format

Each `.md` file in this directory (except this README) is a rule. Rules use YAML frontmatter:

```yaml
---
id: unique-rule-id            # Required. Dedup key for state tracking
ttsr_trigger: regex pattern   # Required. ERE regex matched against AI output
severity: warn                # Optional. info | warn | error (default: warn)
repeat_policy: once           # Optional. once | after-gap | always (default: once)
gap_turns: 3                  # Optional. Cooldown turns for after-gap policy (default: 3)
tags: [git, safety]           # Optional. Categorization tags
enabled: true                 # Optional. Set false to disable without deleting
---
```

**Important**: Write `ttsr_trigger` values as raw ERE regex — do NOT quote or double-escape.
The parser reads values literally, so `\b` means word boundary, not `\\b`.
Do not wrap values in quotes unless the value itself contains a colon followed by a space.

## Rule Body

Everything after the frontmatter closing `---` is the correction content. It is injected verbatim when the rule triggers. Write it as direct instructions to the AI agent.

## Repeat Policies

| Policy | Behaviour |
|--------|-----------|
| `once` | Fires once per session, never again until state is reset |
| `after-gap` | Fires once, then again after `gap_turns` turns without firing |
| `always` | Fires every time the trigger matches |

## Adding Rules

1. Create a new `.md` file in this directory
2. Add YAML frontmatter with at least `id` and `ttsr_trigger`
3. Write correction instructions in the body
4. Test with: `ttsr-rule-loader.sh list` and `ttsr-rule-loader.sh check <file>`

## Phase 2 (Future)

When stream hooks become available, rules will support real-time TTSR injection during generation. The `phase2_hook` field (reserved) will control injection timing.
