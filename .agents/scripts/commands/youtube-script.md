---
description: Generate YouTube video scripts with hooks, retention optimization, and remix mode
agent: Build+
mode: subagent
---

Generate YouTube video scripts optimized for audience retention, with hooks, pattern interrupts, and storytelling frameworks.

Topic: $ARGUMENTS

## Workflow

### Step 1: Parse Input and Load Context

1. **Parse $ARGUMENTS:**

   - Topic/title (e.g., "AI coding tools comparison")
   - Optional flags: `--remix VIDEO_ID`, `--hook-only`, `--outline-only`, `--length [short|medium|long]`

2. **Load research context from memory:**

```bash
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube-topics "$TOPIC"
```

Retrieve any prior research on this topic (competitor analysis, trending data, content gaps).

3. **Load channel configuration:**

```bash
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube "channel"
```

Get the user's niche and target audience.

### Step 2: Determine Script Mode

#### Mode A: Full Script (default)

Generate complete script with:
- Hook (0-30s)
- Intro (30-60s)
- Body (sections with pattern interrupts)
- Climax (payoff)
- CTA (subscribe prompt)

#### Mode B: Hook Only (`--hook-only`)

Generate 5-10 hook variants using proven formulas:
1. Bold Claim
2. Question Hook
3. Story Hook
4. Contrarian Hook
5. Result Hook
6. List Hook
7. Problem Hook

#### Mode C: Outline Only (`--outline-only`)

Generate structured outline with:
- Hook concept
- Intro roadmap
- Body sections (3-7 main points)
- Pattern interrupt placements
- CTA strategy

#### Mode D: Remix (`--remix VIDEO_ID`)

Transform competitor video into unique script:

1. **Get competitor video transcript:**

```bash
~/.aidevops/agents/scripts/youtube-helper.sh transcript VIDEO_ID
```

2. **Analyze structure:**
   - Extract hook, intro, body sections, CTA
   - Identify key points and examples
   - Note pacing and pattern interrupts

3. **Generate unique version:**
   - Same topic, different angle
   - New examples and analogies
   - Your voice and style
   - Updated/expanded information

### Step 3: Generate Script

Read `youtube/script-writer.md` for full guidance on:

- Hook formulas (7 proven patterns)
- Pattern interrupt types (curiosity gaps, story pivots, direct address)
- Retention curve optimization (attention resets every 2-3 minutes)
- Storytelling frameworks (AIDA, Hero's Journey, Problem-Solution-Result)
- B-roll direction markers
- Pacing guidelines (120-150 words/minute for YouTube)

**Script structure:**

```text
[HOOK - 0:00-0:30]
{Pattern interrupt + promise + credibility}

[INTRO - 0:30-1:00]
{Context + roadmap + stakes}

[SECTION 1 - 1:00-3:00]
{Main point 1}
[B-roll: {description}]
{Supporting details}
[Pattern interrupt: {type}]

[SECTION 2 - 3:00-5:00]
{Main point 2}
[B-roll: {description}]
{Supporting details}
[Pattern interrupt: {type}]

[SECTION 3 - 5:00-7:00]
{Main point 3}
[B-roll: {description}]
{Supporting details}

[CLIMAX - 7:00-8:00]
{Payoff the hook's promise}

[CTA - 8:00-8:30]
{Subscribe + next video + comment prompt}
```

### Step 4: Optimize for Retention

1. **Hook strength check:**
   - Does it create curiosity?
   - Does it promise value?
   - Does it establish credibility?

2. **Pattern interrupt placement:**
   - Every 2-3 minutes
   - Before potential drop-off points
   - After dense information sections

3. **Pacing check:**
   - 120-150 words/minute (conversational)
   - Vary sentence length
   - Use pauses for emphasis

4. **B-roll markers:**
   - Visual changes every 5-10 seconds
   - Illustrate abstract concepts
   - Show examples/demos

### Step 5: Present Script

Format as a production-ready script:

```text
YouTube Script: {title}

Target Length: {duration}
Target Audience: {niche}
Hook Formula: {formula used}

---

[HOOK - 0:00-0:30]
{script text}

[INTRO - 0:30-1:00]
{script text}

[SECTION 1: {title}]
{script text}
[B-roll: {description}]

...

---

Production Notes:
- Estimated word count: {count}
- Estimated duration: {minutes}:{seconds}
- Pattern interrupts: {count} (every {interval})
- B-roll shots needed: {count}

Retention Optimization:
- Hook: {strength score}/10
- Pattern interrupts: {placement quality}
- Pacing: {words/minute}

Next Steps:
1. Record video using this script
2. Generate thumbnail: /youtube optimize thumbnail "{title}"
3. Optimize metadata: /youtube optimize metadata "{title}"
```

### Step 6: Store and Offer Follow-up

1. **Store script in memory:**

```bash
~/.aidevops/agents/scripts/memory-helper.sh store \
  --type WORKING_SOLUTION \
  --namespace youtube-scripts \
  "Script: {title}. Hook: {formula}. Length: {duration}. Generated: {date}"
```

2. **Offer next steps:**
   - Generate hook variants
   - Create thumbnail brief
   - Optimize title/tags/description
   - Generate B-roll shot list
   - Create YouTube Short version (first 60s)

## Options

| Command | Purpose |
|---------|---------|
| `/youtube script "topic"` | Full script generation |
| `/youtube script "topic" --hook-only` | Generate 5-10 hook variants |
| `/youtube script "topic" --outline-only` | Structured outline only |
| `/youtube script --remix VIDEO_ID` | Transform competitor video |
| `/youtube script "topic" --length short` | 5-8 minute script |
| `/youtube script "topic" --length medium` | 8-12 minute script |
| `/youtube script "topic" --length long` | 12-20 minute script |

## Examples

**Full script generation:**

```text
User: /youtube script "AI Code Review Tools Compared"
AI: Generating YouTube script for "AI Code Review Tools Compared"...

    Loading research context...
    ✓ Found trending topic data (340K avg views)
    ✓ Loaded channel config (niche: AI coding tools)
    
    Analyzing topic...
    - Comparison format (proven high retention)
    - Technical audience (detail-oriented)
    - Practical value (tool selection)
    
    Recommended hook: Result Hook (show best tool first, then explain)
    Recommended length: 10-12 minutes (comparison needs depth)
    
    ---
    
    YouTube Script: "I Tested 5 AI Code Review Tools - Here's the Winner"
    
    Target Length: 10-12 minutes
    Target Audience: Developers using AI coding tools
    Hook Formula: Result Hook
    
    ---
    
    [HOOK - 0:00-0:30]
    I spent $500 and 40 hours testing every AI code review tool on the market.
    One of them found 23 bugs in production code that human reviewers missed.
    And it's not the one you think.
    
    [INTRO - 0:30-1:00]
    I'm going to show you exactly which tool won, why it won, and whether it's
    worth the cost for your team. We'll cover accuracy, speed, false positives,
    and the one feature that makes or breaks these tools. By the end, you'll
    know exactly which tool to use.
    
    [SECTION 1: The Testing Methodology - 1:00-2:30]
    Here's how I tested them. I took the same 10,000-line codebase with 47
    known bugs - some obvious, some subtle - and ran it through each tool.
    [B-roll: Screen recording of test setup]
    
    The tools: CodeRabbit, Qodo, DeepSource, SonarCloud AI, and Codacy AI.
    Each one promises to catch bugs, security issues, and code smells.
    But do they actually deliver?
    
    [Pattern interrupt: "Here's where it gets interesting..."]
    
    [SECTION 2: The Results - 2:30-5:00]
    Tool #1: CodeRabbit
    - Caught: 31 of 47 bugs (66%)
    - False positives: 12
    - Speed: 45 seconds
    - Standout feature: Explains WHY the bug is a problem
    [B-roll: CodeRabbit interface, bug detection examples]
    
    But here's the problem with CodeRabbit...
    [Pattern interrupt: Problem reveal]
    
    Tool #2: Qodo
    - Caught: 28 of 47 bugs (60%)
    - False positives: 8
    - Speed: 38 seconds
    - Standout feature: Suggests the fix, not just the problem
    [B-roll: Qodo interface, fix suggestions]
    
    Now you might be thinking, "Lower accuracy but better UX?"
    [Pattern interrupt: Direct address]
    
    [Continue for Tools 3-5...]
    
    [SECTION 3: The Winner - 7:00-8:30]
    The winner: CodeRabbit. But not for the reason you'd expect.
    
    Yes, it had the highest accuracy. But the real reason it won is this:
    it's the only tool that caught the 3 critical security vulnerabilities
    that could have led to data breaches.
    [B-roll: Security vulnerability examples]
    
    The other tools flagged style issues and minor bugs. CodeRabbit flagged
    the stuff that would get you fired.
    
    [CLIMAX - 8:30-9:00]
    Here's the full breakdown: [Show comparison table]
    
    If you're a solo developer: Qodo (free tier is generous)
    If you're a team: CodeRabbit (security focus is worth it)
    If you're enterprise: SonarCloud AI (compliance features)
    
    [CTA - 9:00-9:30]
    I've put the full test results, pricing breakdown, and setup guides in
    the description. If you want to see me test AI coding assistants next,
    drop a comment. And subscribe - I'm testing a new AI tool every week.
    
    ---
    
    Production Notes:
    - Estimated word count: 1,350
    - Estimated duration: 10:00
    - Pattern interrupts: 5 (every 2 minutes)
    - B-roll shots needed: 15
    
    Retention Optimization:
    - Hook: 9/10 (result + curiosity + specificity)
    - Pattern interrupts: Well-placed before potential drop-offs
    - Pacing: 135 words/minute (conversational)
    
    Next Steps:
    1. Record video using this script
    2. Generate thumbnail: /youtube optimize thumbnail
    3. Create YouTube Short (first 60s): /youtube script --short
```

**Hook variants only:**

```text
User: /youtube script "Python vs JavaScript for AI" --hook-only
AI: Generating hook variants for "Python vs JavaScript for AI"...

    Hook Variants (7 formulas):
    
    1. Bold Claim:
       "JavaScript is faster than Python for AI workloads. I have the benchmarks."
    
    2. Question Hook:
       "Why does every AI tutorial use Python when JavaScript is 3x faster?"
    
    3. Story Hook:
       "I rewrote my Python AI app in JavaScript. It went from 12 seconds to 4."
    
    4. Contrarian Hook:
       "Everyone says Python is the AI language. They're wrong."
    
    5. Result Hook:
       "I built the same AI model in Python and JavaScript. One was 3x faster."
    
    6. List Hook:
       "5 reasons JavaScript is better for AI than Python. Number 3 will surprise you."
    
    7. Problem Hook:
       "Your Python AI app is slow. Here's why JavaScript might be the answer."
    
    Recommended: #5 (Result Hook) - Specific, measurable, creates curiosity
    
    Generate full script with this hook? (y/n)
```

**Remix mode:**

```text
User: /youtube script --remix dQw4w9WgXcQ
AI: Analyzing competitor video dQw4w9WgXcQ...

    Original Video:
    - Title: "Never Gonna Give You Up"
    - Views: 1.4B
    - Length: 3:33
    
    Getting transcript...
    
    Structure Analysis:
    - Hook: Immediate music start (no verbal hook)
    - Body: Verse-Chorus-Verse-Chorus-Bridge-Chorus
    - Pattern: Repetition for memorability
    
    Remix Strategy:
    - Topic: Same (relationship commitment)
    - Angle: Different (modern dating context)
    - Format: Spoken word + music (vs pure music)
    - Length: 8-10 minutes (vs 3:33)
    
    Remixed Script: "Why Modern Dating Apps Make You Give Up"
    
    [HOOK - 0:00-0:30]
    Dating apps promise you'll never be alone. But 73% of users give up
    within 3 months. Here's why the system is designed to make you quit.
    
    [Continue with remixed content...]
    
    This is a creative remix. The original is a music video; this transforms
    the theme into a commentary video. Same emotional core, different execution.
```

## Related

- `youtube.md` - Main YouTube agent
- `youtube/script-writer.md` - Full script writing guide
- `content/story.md` - Storytelling frameworks and hook formulas
- `/youtube research` - Research topics before scripting
- `/youtube setup` - Configure channel and niche
- `youtube-helper.sh` - Get competitor transcripts for remix mode
