---
description: Analyse code for simplification opportunities (analysis-only, human-gated)
agent: Build+
mode: subagent
model: opus
---

Analyse code for simplification opportunities. This is analysis-only -- produce suggestions for human review, never apply changes directly.

Target: $ARGUMENTS

Read `tools/code-review/code-simplifier.md` and follow its analysis process with the provided arguments. Output findings in the structured format specified. Do not modify any files.
