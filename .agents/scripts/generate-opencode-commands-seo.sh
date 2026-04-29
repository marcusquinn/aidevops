#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Generate OpenCode Commands -- SEO & AI Search
# =============================================================================
# SEO keyword research, SERP analysis, and AI search optimization command
# definitions for OpenCode.
#
# Usage: source "${SCRIPT_DIR}/generate-opencode-commands-seo.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, color vars)
#   - create_command() from the orchestrator
#   - AGENT_SEO constant from the orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_OPENCODE_CMDS_SEO_LOADED:-}" ]] && return 0
_OPENCODE_CMDS_SEO_LOADED=1

# --- SEO Commands ---
# Split into basic keyword research and advanced analysis sub-groups.

define_keyword_research_commands() {
	create_command "keyword-research" \
		"Keyword research with seed keyword expansion" \
		"$AGENT_SEO" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/seo/keyword-research.md and follow its instructions.

Keywords to research: $ARGUMENTS

**Workflow:**
1. If no locale preference saved, prompt user to select (US/English default)
2. Call the keyword research helper or DataForSEO MCP directly
3. Return first 100 results in markdown table format
4. Ask if user needs more results (up to 10,000)
5. Offer CSV export option

**Output format:**
```
| Keyword                  | Volume  | CPC    | KD  | Intent       |
|--------------------------|---------|--------|-----|--------------|
| best seo tools 2025      | 12,100  | $4.50  | 45  | Commercial   |
```

**Options from arguments:**
- `--provider dataforseo|serper|both`
- `--locale us-en|uk-en|etc`
- `--limit N`
- `--csv` - Export to ~/Downloads/
- `--min-volume N`, `--max-difficulty N`, `--intent type`
- `--contains "term"`, `--excludes "term"`

Wildcards supported: "best * for dogs" expands to variations.
BODY

	create_command "autocomplete-research" \
		"Google autocomplete long-tail keyword expansion" \
		"$AGENT_SEO" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/seo/keyword-research.md and follow its instructions.

Seed keyword for autocomplete: $ARGUMENTS

**Workflow:**
1. Use DataForSEO or Serper autocomplete API
2. Return all autocomplete suggestions
3. Display in markdown table format
4. Offer CSV export option

**Output format:**
```
| Keyword                           | Volume  | CPC    | KD  | Intent       |
|-----------------------------------|---------|--------|-----|--------------|
| how to lose weight fast           |  8,100  | $2.10  | 42  | Informational|
| how to lose weight in a week      |  5,400  | $1.80  | 38  | Informational|
```

**Options:**
- `--provider dataforseo|serper|both`
- `--locale us-en|uk-en|etc`
- `--csv` - Export to ~/Downloads/

This is ideal for discovering question-based and long-tail keywords.
BODY

	return 0
}

cmd_keyword_research_extended() {
	create_command "keyword-research-extended" \
		"Full SERP analysis with weakness detection and KeywordScore" \
		"$AGENT_SEO" "true" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/seo/keyword-research.md and follow its instructions.

Research target: $ARGUMENTS

**Modes (from arguments):**
- Default: Full SERP analysis on keywords
- `--domain example.com` - Keywords associated with domain's niche
- `--competitor example.com` - Exact keywords competitor ranks for
- `--gap yourdomain.com,competitor.com` - Keywords they have that you don't

**Analysis levels:**
- `--full` (default): Complete SERP analysis with 17 weaknesses + KeywordScore
- `--quick`: Basic metrics only (Volume, CPC, KD, Intent) - faster, cheaper

**Additional options:**
- `--ahrefs` - Include Ahrefs DR/UR metrics
- `--provider dataforseo|serper|both`
- `--limit N` (default 100, max 10,000)
- `--csv` - Export to ~/Downloads/

**Extended output format:**
```
| Keyword         | Vol    | KD  | KS  | Weaknesses | Weakness Types                   | DS  | PS  |
|-----------------|--------|-----|-----|------------|----------------------------------|-----|-----|
| best seo tools  | 12.1K  | 45  | 72  | 5          | Low DS, Old Content, No HTTPS... | 23  | 15  |
```

**Competitor/Gap output format:**
```
| Keyword         | Vol    | KD  | Position | Est Traffic | Ranking URL                    |
|-----------------|--------|-----|----------|-------------|--------------------------------|
| best seo tools  | 12.1K  | 45  | 3        | 2,450       | example.com/blog/seo-tools     |
```

**KeywordScore (0-100):**
- 90-100: Exceptional opportunity
- 70-89: Strong opportunity
- 50-69: Moderate opportunity
- 30-49: Challenging
- 0-29: Very difficult

**17 SERP Weaknesses detected:**
Domain: Low DS, Low PS, No Backlinks
Technical: Slow Page, High Spam, Non-HTTPS, Broken, Flash, Frames, Non-Canonical
Content: Old Content, Title Mismatch, No Keyword in Headings, No Headings, Unmatched Intent
SERP: UGC-Heavy Results
BODY

	return 0
}

cmd_webmaster_keywords() {
	create_command "webmaster-keywords" \
		"Keywords from GSC + Bing for your verified sites" \
		"$AGENT_SEO" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/seo/keyword-research.md and follow its instructions.

Site URL: $ARGUMENTS

**Workflow:**
1. List verified sites if no URL provided: `keyword-research-helper.sh sites`
2. Fetch keywords from Google Search Console
3. Fetch keywords from Bing Webmaster Tools
4. Combine and deduplicate results
5. Enrich with DataForSEO volume/difficulty data (unless --no-enrich)
6. Display in markdown table format

**Output format:**
```
| Keyword                  | Clicks | Impressions | CTR   | Position | Volume | KD | CPC  | Sources  |
|--------------------------|--------|-------------|-------|----------|--------|----|----- |----------|
| best seo tools           |    245 |       8,100 | 3.02% |      4.2 | 12,100 | 45 | 4.50 | GSC+Bing |
| keyword research tips    |    128 |       3,400 | 3.76% |      6.8 |  2,400 | 32 | 2.10 | GSC      |
```

**Options:**
- `--days N` - Days of data (default: 30)
- `--limit N` - Number of results (default: 100)
- `--no-enrich` - Skip DataForSEO enrichment (faster, no credits)
- `--csv` - Export to ~/Downloads/

**Commands:**
```bash
# List verified sites
keyword-research-helper.sh sites

# Get keywords for a site
keyword-research-helper.sh webmaster https://example.com

# Last 90 days, no enrichment
keyword-research-helper.sh webmaster https://example.com --days 90 --no-enrich
```

**Use cases:**
1. Find high-impression, low-CTR keywords to optimize
2. Track ranking changes over time
3. Discover keywords you're ranking for but not targeting
4. Compare Google vs Bing performance
BODY

	return 0
}

define_keyword_analysis_commands() {
	cmd_keyword_research_extended
	cmd_webmaster_keywords
	return 0
}

define_seo_commands() {
	define_keyword_research_commands
	define_keyword_analysis_commands
	return 0
}

# --- SEO AI Commands ---
# Split into optimization workflows and integrity/readiness sub-groups.

define_seo_optimization_commands() {
	create_command "seo-fanout" \
		"Run thematic query fan-out research for AI search coverage" \
		"$AGENT_SEO" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/seo/query-fanout-research.md and follow its instructions.

Target: $ARGUMENTS

Produce:
1. Thematic branch map for the target intent set
2. Prioritized sub-query list
3. Coverage matrix against existing pages
4. Remediation backlog for partial/missing high-priority branches
BODY

	create_command "seo-geo" \
		"Run GEO strategy workflow for AI search visibility" \
		"$AGENT_SEO" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/seo/geo-strategy.md and follow its instructions.

Target: $ARGUMENTS

Deliverables:
1. Decision-criteria matrix
2. Page-level strong/partial/missing coverage map
3. Prioritized retrieval-first implementation plan
BODY

	create_command "seo-sro" \
		"Run Selection Rate Optimization workflow for grounding snippets" \
		"$AGENT_SEO" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/seo/sro-grounding.md and follow its instructions.

Target: $ARGUMENTS

Deliverables:
1. Baseline snippet behavior summary
2. Sentence/structure-level SRO fixes
3. Controlled re-test plan with expected deltas
BODY

	return 0
}

define_seo_integrity_commands() {
	create_command "seo-hallucination-defense" \
		"Audit and reduce AI brand hallucination risk" \
		"$AGENT_SEO" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/seo/ai-hallucination-defense.md and follow its instructions.

Target: $ARGUMENTS

Deliverables:
1. Critical fact inventory and canonical source map
2. Contradiction report with severities
3. Claim-evidence matrix and remediation priorities
BODY

	create_command "seo-agent-discovery" \
		"Test AI agent discoverability across multi-turn tasks" \
		"$AGENT_SEO" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/seo/ai-agent-discovery.md and follow its instructions.

Target: $ARGUMENTS

Deliverables:
1. Discovery task completion diagnostics
2. Failure classification (missing content vs discoverability vs comprehension)
3. Prioritized remediation and re-test scorecard
BODY

	create_command "seo-ai-readiness" \
		"Run end-to-end AI search readiness workflow" \
		"$AGENT_SEO" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/seo/ai-search-readiness.md and follow its instructions.

Target: $ARGUMENTS

Run chained phases:
1. Fan-out decomposition
2. GEO criteria alignment
3. SRO snippet optimization
4. Hallucination defense
5. Agent discoverability validation

Return one prioritized backlog with readiness scorecard deltas.
BODY

	create_command "seo-ai-baseline" \
		"Capture AI-search baseline metrics and output KPI scorecard" \
		"$AGENT_SEO" "" <<'BODY'
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/seo/ai-search-readiness.md and follow its instructions.
Read ${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/seo/ai-search-kpi-template.md and follow its format.

Target: $ARGUMENTS

Run baseline checks for fan-out, GEO, SRO, integrity, and discoverability.

Return:
1. Completed KPI scorecard baseline
2. Top 3 remediation priorities
3. Re-test schedule recommendation
BODY

	return 0
}

define_seo_ai_commands() {
	define_seo_optimization_commands
	define_seo_integrity_commands
	return 0
}
