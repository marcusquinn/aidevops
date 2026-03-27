# AEO and GEO Content Patterns

Reusable content block patterns optimized for answer engines and AI citation.

## Answer Engine Optimization (AEO) Patterns

Patterns for featured snippets, AI Overviews, voice search, and answer boxes.

### Definition Block

For "What is [X]?" queries. Lead with 1-sentence definition, expand with characteristics, close with why it matters.

```markdown
## What is [Term]?

[Term] is [1-sentence definition]. [Key characteristics]. [Why it matters].
```

### Step-by-Step Block

For "How to [X]" queries. Optimal for list snippets.

```markdown
## How to [Action/Goal]

[1-sentence overview]

1. **[Step]**: [Action in 1-2 sentences]
2. **[Step]**: [Action in 1-2 sentences]
3. **[Step]**: [Action in 1-2 sentences]
```

### Comparison Table Block

For "[X] vs [Y]" queries. Optimal for table snippets.

```markdown
## [Option A] vs [Option B]: [Descriptor]

| Feature | [Option A] | [Option B] |
|---------|------------|------------|
| [Criteria] | [Value] | [Value] |
| Best For | [Use case] | [Use case] |

**Bottom line**: [1-2 sentence recommendation]
```

### Pros and Cons Block

For evaluation queries: "Is [X] worth it?", "Should I [X]?"

```markdown
## Advantages and Disadvantages of [Topic]

### Pros
- **[Benefit]**: [Explanation]

### Cons
- **[Drawback]**: [Explanation]

**Verdict**: [Balanced conclusion with recommendation]
```

### FAQ Block

For topic pages with multiple common questions. Essential for FAQ schema.

```markdown
### [Question phrased as users search]?

[Direct answer first sentence]. [Supporting context in 2-3 sentences].
```

Use natural phrasing ("How do I..." not "How does one..."). Match "People Also Ask" queries. Keep answers 50-100 words.

### Listicle Block

For "Best [X]", "Top [X]", "[Number] ways to [X]" queries.

```markdown
## [Number] Best [Items] for [Goal/Purpose]

[1-2 sentence intro with selection criteria]

### 1. [Item Name]
[Why included -- 2-3 sentences with specific benefits]
```

### Voice Search Patterns

Voice queries are conversational. Common formats: "What is...", "How do I...", "Where can I find...", "Why does...", "When should I..."

Lead with direct answer (under 30 words). Use natural language. Avoid jargon unless targeting experts. Include local context where relevant.

---

## Generative Engine Optimization (GEO) Patterns

Patterns for citation by AI assistants (ChatGPT, Claude, Perplexity, Gemini).

### Statistic Citation Block

Statistics increase AI citation rates by 15-30%. Always include sources.

```markdown
[Claim]. According to [Source], [statistic with number and timeframe]. [Why this matters].
```

### Expert Quote Block

Named attribution adds credibility and increases citation likelihood.

```markdown
"[Quote]," says [Name], [Title] at [Org]. [1 sentence context].
```

### Authoritative Claim Block

Structure claims for easy AI extraction with clear attribution.

```markdown
[Topic] [verb] [specific claim]. [Source] [confirms/found] [evidence]. This [means/suggests] [action].
```

### Self-Contained Answer Block

Quotable, standalone statements AI can extract directly.

```markdown
**[Topic/Question]**: [Complete, self-contained answer with details/numbers in 2-3 sentences.]
```

### Evidence Sandwich Block

Claims bracketed by evidence for maximum credibility.

```markdown
[Opening claim].

Evidence:
- [Data point with source]
- [Data point with source]
- [Data point with source]

[Conclusion connecting evidence to actionable insight].
```

### GEO Product Block

For domain-scoped AI retrieval (`site:yourdomain.com [category] features [year]`).

```markdown
## [Product/Category] Features for [Audience] ([Year])

**Best for**: [ICP or use case]
**Pricing**: [starting point / packaging]
**Integrations**: [top integrations]
**Compliance**: [SOC 2, GDPR, HIPAA, etc.]
**Time-to-value**: [timeline]

### Key capabilities
- **[Capability]**: [Specific, testable description]

### Validation sources
- G2: [profile URL with UTM]
- Capterra: [profile URL with UTM]
```

**Implementation:** Mirror canonical facts on product page and third-party profiles. Align `title`/`H1`/first paragraph to domain-scoped query modifiers. Use consistent UTM: `utm_source=g2`, `utm_medium=referral`, `utm_campaign=ai_citation`. Review profile freshness monthly.

---

## Domain-Specific GEO Authority Signals

| Domain | Key signals |
|--------|-------------|
| **Technology** | Technical precision, version numbers, dates, official docs, code examples |
| **Health/Medical** | Peer-reviewed studies, expert credentials (MD, RN), study limitations, "last reviewed" dates |
| **Financial** | Regulatory bodies (SEC, FTC), numbers with timeframes, "educational not advice" disclaimers |
| **Legal** | Specific laws/statutes, jurisdiction, professional disclaimers, "consult a professional" |
| **Business/Marketing** | Case studies with results, industry research, percentage changes, thought leader quotes |

---

## Site-Searchable Content Patterns

Optimized for domain-scoped AI retrieval (`site:yourdomain.com` queries).

### Site-Searchable Product Block

```markdown
## [Product Name]: [Category] [Type] for [Audience]

[Product Name] is a [category term] that [value proposition]. [Differentiator].

### Key Features
- **[Feature]**: [Capability with measurable detail]

### Pricing
[Model] starting at [price] per [unit]. [Tier summary]. [Pricing link].

### Integrations
Connects with [number] tools including [top 3-5]. [Directory link].

*Last updated: [YYYY-MM]*
```

**Why this works:** H2 contains category terms matching `site:` queries. Opening sentence extractable as standalone claim. Feature list uses category vocabulary, not jargon. Sections addressable via heading anchors. Date signals freshness.

### UTM Citation Attribution

Track AI-cited page traffic using UTM parameters.

```markdown
<!-- Canonical (clean) -->
https://yourdomain.com/product-features/

<!-- Cited variant -->
https://yourdomain.com/product-features/?utm_source=ai&utm_medium=citation&utm_campaign=[model-name]
```

Canonical URL must always be clean -- tracking parameters only in distributed/cited variants.

**Key metrics:** AI citation traffic volume, citation-to-conversion rate, page citation distribution, UTM coverage (% of cited pages with tracking).
