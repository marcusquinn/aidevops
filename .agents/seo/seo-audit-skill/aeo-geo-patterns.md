# AEO and GEO Content Patterns

Reusable content block patterns for answer engines and AI citation.

## AEO Patterns — featured snippets, AI Overviews, voice search, answer boxes

### Definition Block — "What is [X]?"

```markdown
## What is [Term]?
[Term] is [1-sentence definition]. [Key characteristics]. [Why it matters].
```

### Step-by-Step Block — "How to [X]" (list snippets)

```markdown
## How to [Action/Goal]
[1-sentence overview]
1. **[Step]**: [Action in 1-2 sentences]
2. **[Step]**: [Action in 1-2 sentences]
3. **[Step]**: [Action in 1-2 sentences]
```

### Comparison Table — "[X] vs [Y]" (table snippets)

```markdown
## [Option A] vs [Option B]: [Descriptor]
| Feature | [Option A] | [Option B] |
|---------|------------|------------|
| [Criteria] | [Value] | [Value] |
| Best For | [Use case] | [Use case] |
**Bottom line**: [1-2 sentence recommendation]
```

### Pros/Cons Block — "Is [X] worth it?", "Should I [X]?"

```markdown
## Advantages and Disadvantages of [Topic]
**Pros**: **[Benefit]**: [Explanation]
**Cons**: **[Drawback]**: [Explanation]
**Verdict**: [Balanced conclusion with recommendation]
```

### FAQ Block — common questions (FAQ schema)

Natural phrasing ("How do I..." not "How does one..."). Match "People Also Ask". 50-100 word answers.

```markdown
### [Question phrased as users search]?
[Direct answer first sentence]. [Supporting context in 2-3 sentences].
```

### Listicle Block — "Best [X]", "Top [X]", "[N] ways to [X]"

```markdown
## [Number] Best [Items] for [Goal/Purpose]
[1-2 sentence intro with selection criteria]
### 1. [Item Name]
[Why included -- 2-3 sentences with specific benefits]
```

### Voice Search

Conversational queries ("What is...", "How do I...", "Where can I find...", "Why does...", "When should I..."). Direct answer under 30 words, natural language, avoid jargon unless targeting experts, include local context where relevant.

## GEO Patterns

For citation by AI assistants (ChatGPT, Claude, Perplexity, Gemini).

### Single-Line Citation Patterns

| Pattern | Template |
|---------|----------|
| **Statistic** | `[Claim]. According to [Source], [statistic with number and timeframe]. [Why this matters].` |
| **Expert Quote** | `"[Quote]," says [Name], [Title] at [Org]. [1 sentence context].` |
| **Authoritative Claim** | `[Topic] [verb] [specific claim]. [Source] [confirms/found] [evidence]. This [means/suggests] [action].` |
| **Self-Contained Answer** | `**[Topic/Question]**: [Complete, self-contained answer with details/numbers in 2-3 sentences.]` |

### Evidence Sandwich — claims bracketed by evidence

```markdown
[Opening claim].
Evidence:
- [Data point with source]
- [Data point with source]
- [Data point with source]
[Conclusion connecting evidence to actionable insight].
```

### Product Block — domain-scoped AI retrieval

For `site:yourdomain.com [category] features [year]` queries. Align `title`/`H1`/first paragraph to domain-scoped query modifiers.

```markdown
## [Product/Category] Features for [Audience] ([Year])
**Best for**: [ICP or use case]  |  **Pricing**: [starting point / packaging]
**Integrations**: [top integrations]  |  **Compliance**: [SOC 2, GDPR, HIPAA, etc.]
**Time-to-value**: [timeline]
### Key capabilities
- **[Capability]**: [Specific, testable description]
### Validation sources
- G2: [profile URL with UTM]  |  Capterra: [profile URL with UTM]
```

Mirror canonical facts on product page and third-party profiles. UTM: `utm_source=g2`, `utm_medium=referral`, `utm_campaign=ai_citation`. Review freshness monthly.

**Site-searchable variant** — H2 with category terms for `site:` queries, standalone opening sentence, date freshness:

```markdown
## [Product Name]: [Category] [Type] for [Audience]
[Product Name] is a [category term] that [value proposition]. [Differentiator].
- **Key Features**: [Capability with measurable detail]
- **Pricing**: [Model] starting at [price] per [unit]. [Tier summary]. [Link].
- **Integrations**: Connects with [number] tools including [top 3-5]. [Link].
*Last updated: [YYYY-MM]*
```

## Domain-Specific GEO Authority Signals

| Domain | Key signals |
|--------|-------------|
| **Technology** | Technical precision, version numbers, dates, official docs, code examples |
| **Health/Medical** | Peer-reviewed studies, expert credentials (MD, RN), study limitations, "last reviewed" dates |
| **Financial** | Regulatory bodies (SEC, FTC), numbers with timeframes, "educational not advice" disclaimers |
| **Legal** | Specific laws/statutes, jurisdiction, professional disclaimers, "consult a professional" |
| **Business/Marketing** | Case studies with results, industry research, percentage changes, thought leader quotes |

## UTM Citation Attribution

Canonical URL always clean — tracking parameters only in cited variants.

```markdown
<!-- Canonical -->
https://yourdomain.com/product-features/
<!-- Cited variant -->
https://yourdomain.com/product-features/?utm_source=ai&utm_medium=citation&utm_campaign=[model-name]
```

**Key metrics:** citation traffic volume, citation-to-conversion rate, page citation distribution, UTM coverage.
