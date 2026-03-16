---
name: ai-agent-discovery
description: Assess whether autonomous AI agents can locate and understand critical site information across multi-turn exploration
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# AI Agent Discovery

Evaluate machine discoverability, not only human UX, using multi-turn exploration scenarios.

## Quick Reference

- Purpose: verify that autonomous agents can find, interpret, and trust key business information
- Inputs: target tasks/questions, indexed pages, navigation structure
- Outputs: discoverability report, gap classification, remediation backlog

## Workflow

### 1) Define discovery tasks

- Select 5-15 user tasks (pricing, eligibility, integration, support, compliance)
- Write each task as a natural language goal an agent would execute
- Include both broad and goal-focused scenarios

### 2) Simulate multi-turn exploration

- Capture sequence of search attempts, page hits, and confidence changes
- Note where agent loops, backtracks, or stalls
- Separate retrieval failure from comprehension failure
- Run explicit `site:` retrieval passes against first-party domain pages
  (`site:yourdomain.com pricing`, `site:yourdomain.com integrations`)
- Run third-party validation passes (`site:g2.com [brand]`,
  `site:capterra.com [brand]`) and compare fact consistency

### 3) Classify findings

- Clearly found and accurate
- Found but partial/uncertain
- Not found though content exists (discoverability issue)
- Not found because content missing (content gap)

### 4) Fix by failure type

- Discoverability issue: improve wording, headings, and internal linking
- Content gap: add concise, evidence-backed section or dedicated page
- Comprehension issue: rewrite for standalone clarity

### 5) Re-run and score

- Re-test same tasks after changes
- Track task completion rate and turn count reduction
- Promote fixes that improve both human and agent outcomes

## Common Discoverability Problems

- Critical facts trapped in PDFs or images without text equivalents
- Site language uses internal jargon instead of user vocabulary
- Key answers scattered across weakly-linked pages
- High-value pages lack explicit sections for common decision questions
- Page titles use brand-centric language that does not match `site:` query patterns (e.g., "Our Solution" instead of "[Category] Software Features")
- Review platform profiles are outdated or incomplete, causing third-party validation queries to return stale information
- Key product pages are consolidated into a single URL, making domain-scoped search return one page for all queries instead of topic-specific matches

## Related Subagents

- `query-fanout-research.md` for thematic query planning
- `ai-hallucination-defense.md` for factual consistency and claim hygiene
- `site-crawler.md` for structure and linking audits
