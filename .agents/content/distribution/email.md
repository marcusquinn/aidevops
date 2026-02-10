---
name: email
description: Email distribution - newsletters, sequences, and automated campaigns
mode: subagent
model: sonnet
---

# Email - Newsletter and Sequence Distribution

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Distribute content via email newsletters, automated sequences, and campaigns
- **Formats**: Weekly newsletter, welcome sequence, launch sequence, nurture sequence
- **Key Principle**: Permission-based, value-first, relationship-building
- **Success Metrics**: Open rate, click rate, reply rate, unsubscribe rate
- **CRM Integration**: FluentCRM via `marketing.md` and `services/crm/fluentcrm.md`

**Critical Rules**:

- **Subject line is the hook** - 80% of email success is the subject line
- **One CTA per email** - Multiple CTAs reduce click-through rate
- **Mobile-first** - 60%+ of emails opened on mobile
- **Value before ask** - Minimum 3:1 value-to-promotion ratio
- **Segment aggressively** - Personalized emails outperform broadcasts 6x

<!-- AI-CONTEXT-END -->

## Email Types

### Weekly Newsletter

**Purpose**: Consistent touchpoint that builds trust and keeps audience engaged.

**Structure**:

1. **Subject line** - Curiosity hook or specific value promise (under 50 chars)
2. **Preview text** - Extends the hook (under 90 chars)
3. **Personal opener** (2-3 sentences) - Story, observation, or lesson
4. **Main content** (200-400 words) - One key insight or framework
5. **Content roundup** (3-5 links) - Best content from the week
6. **CTA** - One clear action (reply, click, share)
7. **PS line** - Secondary offer or personal note (highest-read section after subject)

**Cadence**: Weekly, same day and time (consistency builds habit).

**Content Adaptation from Pipeline**:

```text
Story: "Why 95% of AI influencers fail"

Newsletter:
Subject: The 5 mistakes killing AI influencers
Preview: I studied 50 creators for 6 months. Here's what I found.

Hey [Name],

I spent the last 6 months studying 50 AI content creators.

The pattern was brutal: 95% of them are making the same 5 mistakes.

Here's the one that surprised me most:

They chase tools instead of problems.

Nobody cares about your Sora 2 demo. They care about making
better videos faster.

The creators who are actually growing? They research their
audience obsessively, edit AI output ruthlessly, and test
10 variants before committing.

I broke down all 5 mistakes (and what the top 5% do instead)
in this week's video: [link]

What's your biggest challenge with AI content?
Hit reply - I read every response.

[Name]

PS - I'm putting together a free guide on building an AI content
system. Reply "GUIDE" if you want early access.
```

### Welcome Sequence (5-7 emails)

**Purpose**: Onboard new subscribers, establish value, and segment by interest.

**Sequence**:

| Email | Timing | Purpose | Content |
|-------|--------|---------|---------|
| **1** | Immediate | Deliver lead magnet + set expectations | Welcome, download link, what to expect |
| **2** | Day 1 | Quick win | One actionable tip they can use today |
| **3** | Day 3 | Story + credibility | Your journey, results, why you're qualified |
| **4** | Day 5 | Deep value | Best framework or methodology |
| **5** | Day 7 | Social proof | Case study or testimonial |
| **6** | Day 10 | Soft pitch | Introduce paid offering with value framing |
| **7** | Day 14 | Direct pitch | Clear CTA with urgency or bonus |

**Key Principles**:

- Each email should stand alone (not everyone reads sequentially)
- Build trust before asking for anything
- Segment based on clicks (interested in topic A vs topic B)
- Remove non-openers after email 3 (clean list)

### Launch Sequence (5-7 emails)

**Purpose**: Drive sales for a product launch or promotion.

**Sequence**:

| Email | Timing | Purpose | Content |
|-------|--------|---------|---------|
| **1** | Day -3 | Anticipation | Problem awareness, hint at solution |
| **2** | Day -1 | Story | Your journey solving this problem |
| **3** | Day 0 | Launch | Product reveal, benefits, early-bird offer |
| **4** | Day 1 | Social proof | Testimonials, case studies, results |
| **5** | Day 3 | FAQ | Objection handling, common questions |
| **6** | Day 5 | Scarcity | Deadline reminder, bonus expiring |
| **7** | Day 7 | Last chance | Final call, urgency, FOMO |

### Nurture Sequence

**Purpose**: Long-term relationship building for subscribers who didn't convert.

**Cadence**: Weekly or bi-weekly.

**Content Mix**:

- 60% educational (tips, frameworks, insights)
- 20% story-driven (personal experiences, case studies)
- 10% curated (best resources, tools, articles)
- 10% promotional (soft pitches, offers)

## Subject Line Formulas

### High-Performing Patterns

| Formula | Example | Why It Works |
|---------|---------|-------------|
| **Number + benefit** | "5 AI tools that save 10 hours/week" | Specific, scannable |
| **Question** | "Are you making this AI content mistake?" | Curiosity gap |
| **How-to** | "How to create 10 videos per day with AI" | Clear value |
| **Contrarian** | "Stop using ChatGPT for content" | Pattern interrupt |
| **Personal** | "I wasted $5k on AI tools (so you don't have to)" | Authenticity |
| **Urgency** | "Last chance: AI content guide (free until Friday)" | Scarcity |
| **Curiosity** | "The AI video secret nobody talks about" | Open loop |
| **Social proof** | "How [Name] went from 0 to 100k with AI content" | Aspirational |

### Subject Line Rules

- Under 50 characters (mobile truncation)
- No ALL CAPS (spam filter trigger)
- No excessive punctuation (!!!, ???)
- Personalization token when available ([Name])
- A/B test 2-3 variants per send
- Preview text extends the hook (not repeats it)

## Email Design

### Mobile-First Layout

- **Width**: 600px maximum
- **Font size**: 16px minimum body, 22px+ headings
- **CTA button**: 44px minimum height, high contrast
- **Images**: Optional, not required for message
- **Single column**: No multi-column layouts on mobile

### Plain Text vs HTML

| Format | Best For | Open Rate Impact |
|--------|----------|-----------------|
| **Plain text** | Personal newsletters, B2B | Higher (feels personal) |
| **Light HTML** | Branded newsletters, B2C | Moderate (professional) |
| **Heavy HTML** | E-commerce, promotions | Lower (feels promotional) |

**Recommendation**: Plain text or light HTML for content-focused newsletters. Heavy HTML only for product launches and promotions.

## Segmentation Strategy

### Segment by Behavior

| Segment | Criteria | Content Strategy |
|---------|----------|-----------------|
| **Engaged** | Opened 3+ of last 5 emails | Full content, early access, premium offers |
| **Casual** | Opened 1-2 of last 5 emails | Re-engagement, best-of content, surveys |
| **Cold** | No opens in 30+ days | Win-back sequence, then remove |
| **Buyers** | Purchased any product | Upsell, loyalty, exclusive content |
| **Clickers** | Clicked specific topic links | Topic-specific content and offers |

### Segment by Interest

Tag subscribers based on:

- Lead magnet downloaded (topic interest)
- Links clicked in newsletters (content preference)
- Survey responses (self-reported interests)
- Purchase history (product category)

## FluentCRM Integration

**From `marketing.md` and `services/crm/fluentcrm.md`**:

```bash
# Create a new email campaign
# Use FluentCRM MCP tools for:
# - Contact management and segmentation
# - Email sequence creation
# - Automation triggers
# - Performance analytics
```

**Automation Triggers**:

- New subscriber → Welcome sequence
- Link click → Tag + segment
- Purchase → Buyer sequence
- No open in 30 days → Win-back sequence
- Unsubscribe → Exit survey

## Analytics and Optimization

### Key Metrics

| Metric | Target | Action if Below |
|--------|--------|----------------|
| **Open rate** | 30%+ | Improve subject lines, clean list |
| **Click rate** | 3%+ | Improve CTA, content relevance |
| **Reply rate** | 1%+ | More personal tone, ask questions |
| **Unsubscribe rate** | Under 0.5% | Check frequency, content quality |
| **Spam complaint rate** | Under 0.1% | Review opt-in process, add unsubscribe |

### A/B Testing (from `content/optimization.md`)

- **Subject lines**: Test 2-3 variants per send
- **Send time**: Test different days and times over 4 weeks
- **CTA placement**: Above fold vs end of email
- **Content length**: Short (100 words) vs long (400 words)
- **250-subscriber minimum** per variant before judging

## Related Agents and Tools

**Content Pipeline**:

- `content/research.md` - Audience research and niche validation
- `content/story.md` - Hook formulas and narrative design
- `content/guidelines.md` - Content standards and style guide
- `content/optimization.md` - A/B testing and analytics loops

**CRM and Marketing**:

- `marketing.md` - Marketing orchestrator with FluentCRM integration
- `services/crm/fluentcrm.md` - CRM operations and automation

**Email Services**:

- `services/accessibility/accessibility-audit.md` - Email accessibility checks (WCAG compliance)
- `services/email/email-health-check.md` - DNS authentication and deliverability
- `services/email/email-testing.md` - Design rendering and delivery testing overview
- `services/email/email-design-test.md` - Cross-client rendering tests (Litmus, Email on Acid)
- `services/email/email-delivery-test.md` - Inbox placement and spam scoring (GlockApps, Mail Tester)

**Pre-Send Testing Checklist** (run via `email-test-suite-helper.sh full`):

1. Content checks — subject line, preheader, accessibility, links, images, spam words (`email-health-check-helper.sh`)
2. Design rendering — cross-client screenshots and compatibility (`email-design-test-helper.sh`)
3. Delivery testing — inbox placement, spam score, authentication (`email-delivery-test-helper.sh`)

**Distribution Channels**:

- `content/distribution/youtube/` - Long-form YouTube content
- `content/distribution/short-form.md` - TikTok, Reels, Shorts
- `content/distribution/social.md` - X, LinkedIn, Reddit
- `content/distribution/blog.md` - SEO-optimized articles
- `content/distribution/podcast.md` - Audio-first distribution
