# Chapter 3: CRO Frameworks and Prioritization

With limited resources and countless potential optimizations, prioritization is essential. CRO frameworks help systematically evaluate and prioritize testing opportunities.

### The PIE Framework

PIE (Potential, Importance, Ease) is one of the most popular prioritization frameworks, developed by Chris Goward at WiderFunnel.

#### PIE Components

**Potential (0-10)**: How much improvement is possible?
- Consider current performance: low-performing pages have higher potential
- Evaluate existing issues: more obvious problems mean higher potential
- Review benchmark data: if you're far below benchmarks, potential is higher

Scoring Guide:
- 9-10: Significant room for improvement, multiple obvious issues
- 7-8: Clear improvement opportunities
- 5-6: Moderate improvement possible
- 3-4: Limited improvement likely
- 1-2: Already performing well, minimal potential

**Importance (0-10)**: How valuable is this page or element to your business?
- Traffic volume: higher traffic = higher importance
- Revenue impact: pages closer to conversion = higher importance
- Strategic value: alignment with business goals

Scoring Guide:
- 9-10: Critical page (checkout, key landing pages)
- 7-8: Important page (product pages, category pages)
- 5-6: Supporting page (blog posts, informational pages)
- 3-4: Low-traffic page
- 1-2: Minimal business impact

**Ease (0-10)**: How difficult is the test to implement?
- Technical complexity: simple copy change vs. major rebuild
- Resources required: designer, developer, copywriter time
- Political considerations: stakeholder buy-in needed

Scoring Guide:
- 9-10: Simple change, minimal resources (headline, button text)
- 7-8: Moderate effort (new section, image changes)
- 5-6: Significant effort (redesign, new functionality)
- 3-4: Major effort (substantial development work)
- 1-2: Extremely difficult (platform migration, major rebuild)

#### PIE Calculation and Prioritization

**PIE Score = (Potential + Importance + Ease) / 3**

Example:

| Test Idea | Potential | Importance | Ease | PIE Score | Priority |
|-----------|-----------|------------|------|-----------|----------|
| Simplify checkout form | 9 | 10 | 8 | 9.0 | 1 |
| Add testimonials to product page | 7 | 9 | 9 | 8.3 | 2 |
| Redesign homepage | 8 | 8 | 3 | 6.3 | 3 |
| Improve product image quality | 6 | 8 | 7 | 7.0 | 4 |
| Create new landing page template | 7 | 6 | 4 | 5.7 | 5 |

Based on these scores, you would prioritize:
1. Simplifying checkout form (highest impact, high feasibility)
2. Adding testimonials to product page (strong all-around)
3. Improving product image quality (balanced opportunity)
4. Redesigning homepage (lower despite high potential due to difficulty)
5. Creating new landing page template (lowest overall score)

#### PIE Framework Advantages and Limitations

**Advantages**:
- Simple and intuitive
- Balances multiple factors
- Quick to apply
- Encourages team discussion

**Limitations**:
- Subjective scoring
- Equal weighting of factors may not fit all situations
- Doesn't account for learning value
- No consideration of resource availability

### The ICE Framework

ICE (Impact, Confidence, Ease) was popularized by Sean Ellis, founder of GrowthHackers.

#### ICE Components

**Impact (1-10)**: How much will this improve the conversion rate if successful?
- Consider the expected lift
- Evaluate how many users it will affect
- Assess the value of those conversions

**Confidence (1-10)**: How confident are you that this will improve conversions?
- Based on research quality
- Supported by data and user feedback
- Precedent from similar tests or case studies

**Ease (1-10)**: How easy is this to implement?
- Time required
- Resources needed
- Technical complexity

#### ICE Calculation

**ICE Score = (Impact × Confidence × Ease) / 100**

Or alternatively: **ICE Score = Impact + Confidence + Ease**

Example using addition method:

| Test Idea | Impact | Confidence | Ease | ICE Score | Priority |
|-----------|--------|------------|------|-----------|----------|
| Add security badges to checkout | 8 | 9 | 10 | 27 | 1 |
| Test new headline on landing page | 7 | 8 | 9 | 24 | 2 |
| Implement exit-intent popup | 6 | 7 | 8 | 21 | 3 |
| Rebuild product configurator | 9 | 8 | 2 | 19 | 4 |

#### ICE vs. PIE

**Use ICE when**:
- You have strong research supporting hypotheses (confidence is key)
- Speed of implementation is critical
- You want to focus on quick wins

**Use PIE when**:
- You want to consider the current state (potential)
- Page importance and traffic vary significantly
- You need to balance long-term and short-term opportunities

### The RICE Framework

RICE (Reach, Impact, Confidence, Effort) adds more nuance, particularly for product development contexts.

#### RICE Components

**Reach**: How many users will this impact in a given time period?
- Number of users/sessions per month, quarter, etc.
- Percentage of user base affected

**Impact (0.25, 0.5, 1, 2, 3)**: How much will this impact each user?
- 3 = Massive impact
- 2 = High impact
- 1 = Medium impact
- 0.5 = Low impact
- 0.25 = Minimal impact

**Confidence (percentage)**: How confident are you in your estimates?
- 100% = High confidence
- 80% = Medium confidence
- 50% = Low confidence

**Effort (person-months)**: How much time will this take?
- Total team time required
- Includes design, development, testing, and deployment

#### RICE Calculation

**RICE Score = (Reach × Impact × Confidence) / Effort**

Example:

| Test Idea | Reach (monthly users) | Impact | Confidence | Effort (person-days) | RICE Score |
|-----------|----------------------|--------|------------|---------------------|------------|
| Optimize mobile checkout | 15,000 | 3 | 80% | 10 | 3,600 |
| Add live chat | 30,000 | 1 | 90% | 15 | 1,800 |
| Redesign product pages | 25,000 | 2 | 70% | 20 | 1,750 |
| Improve search functionality | 10,000 | 2 | 60% | 15 | 800 |

The highest RICE score indicates the best opportunity considering reach, impact, confidence, and effort.

### The PXL Framework

The PXL (Predict, Explore, Learn) framework, created by CXL, uses a binary yes/no approach to remove subjectivity.

#### PXL Criteria

Questions are answered with Yes (1 point) or No (0 points):

**Evidence-Based (must have at least 1 Yes)**:
- Is it based on qualitative research/data?
- Is it based on quantitative research/data?
- Is it based on best practices (industry research)?
- Does it solve a problem noticed in user testing?
- Does it solve a problem noticed in analytics?
- Does it solve a problem noticed in heuristic analysis?

**Value Potential**:
- Will it address a high-traffic page?
- Will it affect a major conversion funnel?
- Is the expected impact significant?
- Does it align with business goals?

**Implementation**:
- Can it be built in less than 2 weeks?
- Is it technically feasible without major issues?
- Do you have the necessary resources?

Tests are only pursued if they have:
1. At least one "Yes" in Evidence-Based category
2. A strong overall score (typically 7+ out of available points)

### The TIR Framework (Traffic, Impact, Resources)

TIR provides a simpler alternative:

**Traffic (1-10)**: How much traffic does this page receive?
**Impact (1-10)**: What's the potential conversion lift?
**Resources (1-10)**: How easy is implementation? (10 = very easy)

**TIR Score = Traffic × Impact × Resources**

Higher scores get priority.

### The Value vs. Complexity Matrix

A visual prioritization method that plots ideas on two axes:

**Y-Axis**: Value/Impact (Low to High)
**X-Axis**: Complexity/Effort (Low to High)

This creates four quadrants:

1. **High Value, Low Complexity** (Upper Left): Quick Wins - DO THESE FIRST
2. **High Value, High Complexity** (Upper Right): Major Projects - plan and resource
3. **Low Value, Low Complexity** (Lower Left): Maybe - if time permits
4. **Low Value, High Complexity** (Lower Right): Don't Do - avoid these

### Hybrid Approaches

Many successful CRO teams develop custom frameworks combining elements from multiple systems:

**Example Custom Framework**:
- Business Impact (0-10): Revenue potential
- User Impact (0-10): UX improvement
- Confidence (0-10): Evidence quality
- Effort (0-10): Resources required (inverted, so 10 = easy)
- Strategic Fit (0-10): Alignment with company goals

**Custom Score = (Business Impact × 2) + User Impact + Confidence + Effort + Strategic Fit**

The 2× multiplier on Business Impact reflects that company's prioritization of revenue-generating tests.

### Practical Prioritization Considerations

Beyond frameworks, consider these factors:

**1. Traffic Requirements for Testing**
Tests require adequate traffic for statistical significance. Prioritize high-traffic pages when possible, or be prepared to run tests longer on low-traffic pages.

**2. Learning Value**
Sometimes a "risky" test with uncertain outcome has high learning value. If successful, it could open new optimization avenues. Factor learning potential into prioritization.

**3. Seasonality**
Seasonal businesses should prioritize tests that can run during peak periods and deliver value when it matters most.

**4. Technical Dependencies**
Some tests may be blocked by technical limitations or platform constraints. Be realistic about implementation feasibility.

**5. Team Bandwidth**
Consider available resources—designers, developers, copywriters. Don't commit to more tests than your team can handle.

**6. Testing Velocity**
Balance large, slow tests with quick wins. A steady stream of quick wins maintains momentum and stakeholder enthusiasm while major tests run.

**7. Risk Tolerance**
Radical redesigns carry more risk but potentially higher reward. Conservative changes are safer but may yield incremental improvements. Balance your portfolio.

### Building Your CRO Roadmap

Once you've prioritized ideas, build a roadmap:

**Quarter 1 Example**:
- **Weeks 1-2**: Quick wins (3 small tests)
  - Add trust badges to checkout
  - Test new headline on primary landing page
  - Optimize mobile form fields

- **Weeks 3-6**: Medium test (1 test)
  - Redesign product page template

- **Weeks 7-12**: Major test (1 test, running alongside smaller tests)
  - New checkout flow

- **Ongoing**: Research and ideation
  - User surveys
  - Session recording analysis
  - Competitor research
  - Preparing Q2 test ideas

This balanced approach ensures:
- Quick wins maintain momentum
- Major opportunities aren't neglected
- Research continues to feed the pipeline
- Team capacity isn't overwhelmed

### Prioritization Meeting Structure

Effective CRO teams hold regular prioritization meetings:

**Monthly CRO Prioritization Meeting Agenda**:

1. **Review Previous Month** (15 minutes)
   - Completed tests and results
   - Ongoing tests status
   - Implemented winners impact

2. **Present New Ideas** (30 minutes)
   - Team members present ideas with supporting research
   - Discuss hypotheses and expected outcomes
   - Identify any concerns or dependencies

3. **Score Ideas** (20 minutes)
   - Apply chosen framework (PIE, ICE, etc.)
   - Discuss scoring differences
   - Reach consensus on scores

4. **Prioritize and Plan** (15 minutes)
   - Rank ideas by score
   - Check against available resources
   - Assign to upcoming test slots
   - Identify who owns each test

5. **Set Research Priorities** (10 minutes)
   - Identify research needed for future tests
   - Assign research tasks
   - Set deadlines

6. **Review Roadmap** (10 minutes)
   - Confirm next month's tests
   - Preview upcoming quarter
   - Adjust if necessary

Total: 90 minutes

### Common Prioritization Mistakes

**1. HiPPO (Highest Paid Person's Opinion)**
Don't let seniority override data-driven prioritization. Involve leadership in framework creation, not test selection.

**2. Shiny Object Syndrome**
Resist chasing every new tactic or trend. Stick to your prioritization framework and roadmap.

**3. Ignoring Quick Wins**
Don't only pursue complex, long-term tests. Quick wins build momentum and stakeholder support.

**4. Analysis Paralysis**
Don't spend more time debating prioritization than actually testing. Frameworks provide structure, not perfection.

**5. Neglecting Research**
Prioritization frameworks are only as good as the research feeding them. Invest in ongoing research.

**6. Forgetting Learning Value**
Not every test needs to be a guaranteed winner. Learning what doesn't work is valuable too.

**7. Resource Mismatches**
Don't prioritize tests you can't actually implement with available resources.

### Calculating ROI of CRO Tests

To further inform prioritization, estimate ROI:

**Expected Value Calculation**:
```
Expected Value = (Probability of Success × Expected Lift × Revenue Impacted) - Cost of Implementation
```

Example:
- Probability of Success: 60% (based on research quality)
- Expected Lift: 15% conversion rate increase
- Current Conversion Rate: 2%
- New Conversion Rate: 2.3%
- Monthly Revenue from this page: $100,000
- Additional Monthly Revenue: $15,000
- Annual Additional Revenue: $180,000
- Cost of Implementation: $10,000

Expected Value = (0.60 × $180,000) - $10,000 = $98,000

This test has a strong expected ROI and should be prioritized.

Compare this to another test:
- Probability of Success: 40%
- Expected Lift: 5%
- Monthly Revenue: $50,000
- Additional Monthly Revenue: $2,500
- Annual Additional Revenue: $30,000
- Cost: $15,000

Expected Value = (0.40 × $30,000) - $15,000 = -$3,000

This test has negative expected value and should be deprioritized or redesigned.

### Documentation and Knowledge Management

Maintain a prioritization database/spreadsheet tracking:
- Test idea and hypothesis
- Supporting research
- Framework scores
- Priority ranking
- Status (backlog, planned, in-progress, completed)
- Owner
- Expected completion date
- Actual results (once tested)
- Learning and next steps

This becomes an invaluable knowledge repository showing:
- What you've tested
- What worked and didn't work
- Why decisions were made
- Patterns in successful tests
- Research supporting future tests

---

