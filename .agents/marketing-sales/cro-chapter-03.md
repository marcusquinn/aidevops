# Chapter 3: CRO Frameworks and Prioritization

With limited resources and countless potential optimizations, prioritization is essential. CRO frameworks help systematically evaluate and prioritize testing opportunities.

## The PIE Framework

PIE (Potential, Importance, Ease) was developed by Chris Goward at WiderFunnel. Each component scored 0-10.

**Potential** — How much improvement is possible? Low-performing pages with obvious issues score higher. Already performing well = 1-2; significant room with multiple issues = 9-10.

**Importance** — How valuable is this page? Consider traffic volume, revenue impact, strategic alignment. Minimal business impact = 1-2; critical pages (checkout, key landing pages) = 9-10.

**Ease** — How difficult to implement? Factor technical complexity, resources required, stakeholder buy-in. Major rebuild = 1-2; simple copy/button change = 9-10.

**PIE Score = (Potential + Importance + Ease) / 3**

| Test Idea | Potential | Importance | Ease | PIE Score | Priority |
|-----------|-----------|------------|------|-----------|----------|
| Simplify checkout form | 9 | 10 | 8 | 9.0 | 1 |
| Add testimonials to product page | 7 | 9 | 9 | 8.3 | 2 |
| Redesign homepage | 8 | 8 | 3 | 6.3 | 3 |
| Improve product image quality | 6 | 8 | 7 | 7.0 | 4 |
| Create new landing page template | 7 | 6 | 4 | 5.7 | 5 |

**Advantages**: Simple, intuitive, balances multiple factors, encourages team discussion.
**Limitations**: Subjective scoring, equal weighting may not fit all situations, doesn't account for learning value or resource availability.

## The ICE Framework

ICE (Impact, Confidence, Ease) was popularized by Sean Ellis (GrowthHackers). Replaces PIE's Potential/Importance with Impact/Confidence.

- **Impact (1-10)**: Expected conversion lift and number of users affected
- **Confidence (1-10)**: Evidence quality — research, data, user feedback, precedent from similar tests
- **Ease (1-10)**: Time, resources, technical complexity

**ICE Score = Impact + Confidence + Ease** (or multiplicative: Impact x Confidence x Ease / 100)

| Test Idea | Impact | Confidence | Ease | ICE Score | Priority |
|-----------|--------|------------|------|-----------|----------|
| Add security badges to checkout | 8 | 9 | 10 | 27 | 1 |
| Test new headline on landing page | 7 | 8 | 9 | 24 | 2 |
| Implement exit-intent popup | 6 | 7 | 8 | 21 | 3 |
| Rebuild product configurator | 9 | 8 | 2 | 19 | 4 |

**ICE vs PIE**: Use ICE when you have strong research (confidence matters) and want quick wins. Use PIE when page importance/traffic varies significantly and you need to balance long-term vs short-term.

## The RICE Framework

RICE (Reach, Impact, Confidence, Effort) adds quantitative nuance, particularly for product development contexts.

- **Reach**: Users/sessions impacted per time period (actual numbers, not 1-10)
- **Impact**: Per-user effect on a fixed scale: 3 (massive), 2 (high), 1 (medium), 0.5 (low), 0.25 (minimal)
- **Confidence**: Percentage — 100% (high), 80% (medium), 50% (low)
- **Effort**: Person-months/days total (design + dev + testing + deployment)

**RICE Score = (Reach x Impact x Confidence) / Effort**

| Test Idea | Reach (monthly) | Impact | Confidence | Effort (person-days) | RICE Score |
|-----------|-----------------|--------|------------|---------------------|------------|
| Optimize mobile checkout | 15,000 | 3 | 80% | 10 | 3,600 |
| Add live chat | 30,000 | 1 | 90% | 15 | 1,800 |
| Redesign product pages | 25,000 | 2 | 70% | 20 | 1,750 |
| Improve search functionality | 10,000 | 2 | 60% | 15 | 800 |

## The PXL Framework

PXL (Predict, Explore, Learn), created by CXL, uses binary yes/no scoring to remove subjectivity.

**Evidence-Based** (must have at least 1 Yes):
- Based on qualitative research/data?
- Based on quantitative research/data?
- Based on best practices (industry research)?
- Solves a problem from user testing / analytics / heuristic analysis?

**Value Potential**: High-traffic page? Major conversion funnel? Significant expected impact? Aligns with business goals?

**Implementation**: Buildable in <2 weeks? Technically feasible? Resources available?

Tests require at least one Evidence-Based "Yes" and a strong overall score (typically 7+).

## The TIR Framework

TIR (Traffic, Impact, Resources) — a simpler alternative. Each scored 1-10 (Resources: 10 = very easy).

**TIR Score = Traffic x Impact x Resources**

## The Value vs Complexity Matrix

Plot ideas on two axes — Value/Impact (Y) vs Complexity/Effort (X):

| Quadrant | Value | Complexity | Action |
|----------|-------|------------|--------|
| Upper Left | High | Low | **Quick Wins — do first** |
| Upper Right | High | High | Major Projects — plan and resource |
| Lower Left | Low | Low | Maybe — if time permits |
| Lower Right | Low | High | Don't Do — avoid |

## Hybrid Approaches

Custom frameworks combine elements from multiple systems. Example:

- Business Impact (0-10, **2x weight**): Revenue potential
- User Impact (0-10): UX improvement
- Confidence (0-10): Evidence quality
- Effort (0-10, inverted — 10 = easy): Resources required
- Strategic Fit (0-10): Company goal alignment

**Score = (Business Impact x 2) + User Impact + Confidence + Effort + Strategic Fit**

The multiplier reflects prioritization of revenue-generating tests.

## Practical Prioritization Considerations

1. **Traffic requirements**: Tests need adequate traffic for statistical significance. Prioritize high-traffic pages or plan longer test durations.
2. **Learning value**: "Risky" tests with uncertain outcomes may open new optimization avenues. Factor learning potential in.
3. **Seasonality**: Prioritize tests that run during peak periods for maximum value.
4. **Technical dependencies**: Be realistic about platform constraints and implementation feasibility.
5. **Team bandwidth**: Don't commit to more tests than designers, developers, and copywriters can handle.
6. **Testing velocity**: Balance large slow tests with quick wins to maintain momentum and stakeholder enthusiasm.
7. **Risk tolerance**: Radical redesigns carry more risk but higher potential reward. Balance your portfolio.

## Building Your CRO Roadmap

Example quarterly structure:

- **Weeks 1-2**: Quick wins (3 small tests) — trust badges, headline tests, mobile form optimization
- **Weeks 3-6**: Medium test (1) — product page template redesign
- **Weeks 7-12**: Major test (1, alongside smaller tests) — new checkout flow
- **Ongoing**: Research pipeline — user surveys, session recordings, competitor research, next-quarter ideation

This ensures quick wins maintain momentum, major opportunities aren't neglected, research feeds the pipeline, and team capacity isn't overwhelmed.

## Prioritization Meeting Structure

**Monthly CRO Prioritization Meeting** (~90 min):

1. **Review previous month** (15 min) — completed test results, ongoing test status, implemented winners impact
2. **Present new ideas** (30 min) — supporting research, hypotheses, expected outcomes, dependencies
3. **Score ideas** (20 min) — apply chosen framework, discuss scoring differences, reach consensus
4. **Prioritize and plan** (15 min) — rank by score, check resources, assign to test slots and owners
5. **Set research priorities** (10 min) — identify research needs, assign tasks, set deadlines
6. **Review roadmap** (10 min) — confirm next month, preview quarter, adjust as needed

## Common Prioritization Mistakes

| Mistake | Remedy |
|---------|--------|
| **HiPPO** (Highest Paid Person's Opinion) | Involve leadership in framework creation, not test selection |
| **Shiny Object Syndrome** | Stick to your framework and roadmap |
| **Ignoring Quick Wins** | Quick wins build momentum and stakeholder support |
| **Analysis Paralysis** | Don't spend more time debating than testing |
| **Neglecting Research** | Frameworks are only as good as the research feeding them |
| **Forgetting Learning Value** | Learning what doesn't work is valuable too |
| **Resource Mismatches** | Don't prioritize tests you can't implement |

## Calculating ROI of CRO Tests

**Expected Value = (Probability of Success x Expected Lift x Revenue Impacted) - Cost of Implementation**

Example:
- Probability: 60% | Expected lift: 15% | Current CVR: 2% -> 2.3%
- Monthly revenue from page: $100,000 | Additional monthly: $15,000 | Annual: $180,000
- Cost: $10,000
- **Expected Value = (0.60 x $180,000) - $10,000 = $98,000** — strong ROI, prioritize

Counter-example:
- Probability: 40% | Lift: 5% | Monthly revenue: $50,000 | Annual additional: $30,000 | Cost: $15,000
- **Expected Value = (0.40 x $30,000) - $15,000 = -$3,000** — negative EV, deprioritize or redesign

## Documentation and Knowledge Management

Maintain a prioritization database tracking: test idea/hypothesis, supporting research, framework scores, priority ranking, status (backlog/planned/in-progress/completed), owner, expected completion, actual results, and learnings/next steps. This repository reveals what you've tested, what worked, why decisions were made, patterns in successful tests, and research supporting future tests.

---
