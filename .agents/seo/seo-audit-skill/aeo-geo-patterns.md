# AEO and GEO Content Patterns

Reusable blocks for answer engines, AI Overviews, voice search, and AI citation.

## AEO Patterns

Use these for featured snippets, answer boxes, and spoken-result queries.

### Definition Block

```markdown
## What is [Term]?
[Term] is [1-sentence definition]. [Key characteristics]. [Why it matters].
```

### Step-by-Step Block

```markdown
## How to [Action/Goal]
[1-sentence overview]
1. **[Step]**: [Action in 1-2 sentences]
2. **[Step]**: [Action in 1-2 sentences]
3. **[Step]**: [Action in 1-2 sentences]
```

### Comparison Table

```markdown
## [Option A] vs [Option B]: [Descriptor]
| Feature | [Option A] | [Option B] |
|---------|------------|------------|
| [Criteria] | [Value] | [Value] |
| Best For | [Use case] | [Use case] |
**Bottom line**: [1-2 sentence recommendation]
```

### Pros/Cons Block

```markdown
## Advantages and Disadvantages of [Topic]
**Pros**: **[Benefit]**: [Explanation]
**Cons**: **[Drawback]**: [Explanation]
**Verdict**: [Balanced conclusion with recommendation]
```

### FAQ Block

Phrase questions the way users search, match "People Also Ask" wording, keep answers to 50-100 words, and put the direct answer first.

```markdown
### [Question phrased as users search]?
[Direct answer first sentence]. [Supporting context in 2-3 sentences].
```

### Listicle Block

```markdown
## [Number] Best [Items] for [Goal/Purpose]
[1-2 sentence intro with selection criteria]
### 1. [Item Name]
[Why included -- 2-3 sentences with specific benefits]
```

### Voice Search Pattern

Target conversational queries like "What is...", "How do I...", "Where can I find...", "Why does...", and "When should I...?" Give the answer in under 30 words, use natural language, avoid jargon unless the audience is expert, and add local context when useful.

## GEO Patterns

Use these for AI assistants such as ChatGPT, Claude, Perplexity, and Gemini.

### Citation Patterns

| Pattern | Template |
|---------|----------|
| **Statistic** | `[Claim]. According to [Source], [statistic with number and timeframe]. [Why this matters].` |
| **Expert Quote** | `"[Quote]," says [Name], [Title] at [Org]. [1 sentence context].` |
| **Authoritative Claim** | `[Topic] [verb] [specific claim]. [Source] [confirms/found] [evidence]. This [means/suggests] [action].` |
| **Self-Contained Answer** | `**[Topic/Question]**: [Complete, self-contained answer with details/numbers in 2-3 sentences.]` |

### Evidence Sandwich

```markdown
[Opening claim].
Evidence:
- [Data point with source]
- [Data point with source]
- [Data point with source]
[Conclusion connecting evidence to actionable insight].
```

### Product Block

Use for `site:yourdomain.com [category] features [year]` queries.

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

Mirror facts on the product page and third-party profiles, use `utm_source=g2`, `utm_medium=referral`, and `utm_campaign=ai_citation`, and review freshness monthly.

#### Site-Searchable Variant

```markdown
## [Product Name]: [Category] [Type] for [Audience]
[Product Name] is a [category term] that [value proposition]. [Differentiator].
- **Key Features**: [Capability with measurable detail]
- **Pricing**: [Model] starting at [price] per [unit]. [Tier summary]. [Link].
- **Integrations**: Connects with [number] tools including [top 3-5]. [Link].
*Last updated: [YYYY-MM]*
```

## Domain-Specific Authority Signals

| Domain | Key signals |
|--------|-------------|
| **Technology** | Technical precision, version numbers, dates, official docs, code examples |
| **Health/Medical** | Peer-reviewed studies, expert credentials (MD, RN), study limitations, "last reviewed" dates |
| **Financial** | Regulatory bodies (SEC, FTC), numbers with timeframes, "educational not advice" disclaimers |
| **Legal** | Specific laws/statutes, jurisdiction, professional disclaimers, "consult a professional" |
| **Business/Marketing** | Case studies with results, industry research, percentage changes, thought leader quotes |

## UTM Citation Attribution

Keep the canonical URL clean. Add tracking parameters only to cited variants.

```markdown
<!-- Canonical -->
https://yourdomain.com/product-features/
<!-- Cited variant -->
https://yourdomain.com/product-features/?utm_source=ai&utm_medium=citation&utm_campaign=[model-name]
```

Track citation traffic volume, citation-to-conversion rate, page citation distribution, and UTM coverage.
