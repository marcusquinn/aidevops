# GEO Patterns

Use these for AI assistants such as ChatGPT, Claude, Perplexity, and Gemini.

## Citation Patterns

| Pattern | Template |
|---------|----------|
| **Statistic** | `[Claim]. According to [Source], [statistic with number and timeframe]. [Why this matters].` |
| **Expert Quote** | `"[Quote]," says [Name], [Title] at [Org]. [1 sentence context].` |
| **Authoritative Claim** | `[Topic] [verb] [specific claim]. [Source] [confirms/found] [evidence]. This [means/suggests] [action].` |
| **Self-Contained Answer** | `**[Topic/Question]**: [Complete, self-contained answer with details/numbers in 2-3 sentences.]` |

## Evidence Sandwich

```markdown
[Opening claim].
Evidence:
- [Data point with source]
- [Data point with source]
- [Data point with source]
[Conclusion connecting evidence to actionable insight].
```

## Product Block

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

### Site-Searchable Variant

```markdown
## [Product Name]: [Category] [Type] for [Audience]
[Product Name] is a [category term] that [value proposition]. [Differentiator].
- **Key Features**: [Capability with measurable detail]
- **Pricing**: [Model] starting at [price] per [unit]. [Tier summary]. [Link].
- **Integrations**: Connects with [number] tools including [top 3-5]. [Link].
*Last updated: [YYYY-MM]*
```
