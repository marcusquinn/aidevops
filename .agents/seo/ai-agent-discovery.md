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

Verify autonomous agents can find, interpret, and trust key business information via multi-turn exploration. Outputs: discoverability report, gap classification, remediation backlog.

## Workflow

### 1. Define discovery tasks

- Select 5–15 user tasks (pricing, eligibility, integration, support, compliance)
- Write each as a natural language goal an agent would execute
- Include both broad and goal-focused scenarios

### 2. Simulate multi-turn exploration

- Capture search attempts, page hits, and confidence changes
- Note where agent loops, backtracks, or stalls
- Separate retrieval failure from comprehension failure
- First-party: `site:yourdomain.com pricing`, `site:yourdomain.com integrations`
- Third-party: `site:g2.com [brand]`, `site:capterra.com [brand]` — compare fact consistency

### 3. Classify findings

- Clearly found and accurate
- Found but partial/uncertain
- Not found though content exists (discoverability issue)
- Not found because content missing (content gap)

### 4. Fix by failure type

- Discoverability: improve wording, headings, internal linking
- Content gap: add concise, evidence-backed section or dedicated page
- Comprehension: rewrite for standalone clarity

### 5. Re-run and score

- Re-test same tasks after changes
- Track task completion rate and turn count reduction
- Promote fixes that improve both human and agent outcomes

## Common Discoverability Problems

- Critical facts trapped in PDFs or images without text equivalents
- Internal jargon instead of user vocabulary
- Key answers scattered across weakly-linked pages
- High-value pages lack explicit sections for common decision questions
- Page titles use brand-centric language that doesn't match `site:` query patterns (e.g., "Our Solution" vs "[Category] Software Features")
- Review platform profiles outdated or incomplete — third-party validation returns stale data
- Key product pages consolidated into one URL — domain-scoped search returns one page for all queries

## Related Subagents

- `query-fanout-research.md` — thematic query planning
- `ai-hallucination-defense.md` — factual consistency and claim hygiene
- `site-crawler.md` — structure and linking audits
