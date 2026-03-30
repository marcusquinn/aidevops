---
name: scripts
description: Writing effective scripts for HeyGen AI avatar videos
metadata:
  tags: scripts, writing, pauses, breaks, pacing, speech
---

# Writing Scripts for HeyGen Videos

AI avatar scripts differ from human presenter scripts — pacing, pauses, and pronunciation must be explicit.

## Speech Rate and Duration

~150 words/minute at 1.0x speed.

| Words | Duration |
|-------|----------|
| 75 | 30s |
| 150 | 1 min |
| 300 | 2 min |
| 450 | 3 min |
| 750 | 5 min |

## Sentence Structure

10-20 words per sentence. AI voices handle shorter sentences more naturally. Split run-ons at natural pause points.

## Punctuation Effects

| Punctuation | Effect |
|-------------|--------|
| `.` | Full stop, natural pause |
| `,` | Brief pause |
| `?` | Rising intonation |
| `!` | Emphasis (use sparingly) |
| `...` | Trailing off, slight pause |

## Break Tags

```xml
<break time="Xs"/>
```

Always space before and after: `word <break time="1s"/> next word`. Use seconds (`1.5s`), not milliseconds. Self-closing only. Consecutive breaks combine: `<break time="1s"/> <break time="0.5s"/>` = 1.5s.

### Pause Reference

| Duration | Use For |
|----------|---------|
| 0.3-0.5s | Between clauses, light emphasis |
| 0.5-1s | Sentence breaks, transitions, after greetings |
| 1-1.5s | Section changes, setup for key points |
| 1.5-2s | Dramatic reveals, important announcements |
| 2s+ | Use sparingly — can feel unnatural |

## Script Templates

### Product Demo (~150 words, 60s)

```text
Hi, I'm [Name], and I'm excited to show you [Product]. <break time="1s"/>
[Product] helps you [main benefit] in just [timeframe]. <break time="0.5s"/>
Here's how it works. <break time="1s"/>
First, [step 1]. <break time="0.5s"/> Then, [step 2]. <break time="0.5s"/> And finally, [step 3]. <break time="1s"/>
What used to take [old time] now takes [new time]. <break time="0.5s"/>
Ready to get started? <break time="0.5s"/> Visit [website] today.
```

### Tutorial Intro (~225 words, 90s)

```text
Welcome to this tutorial on [topic]. <break time="0.5s"/>
I'm [Name], and I'll guide you through everything you need to know. <break time="1s"/>
By the end, you'll be able to [outcome 1], [outcome 2], and [outcome 3]. <break time="1s"/>
Let's start with the basics. <break time="1.5s"/>
[Section 1 — 2-3 sentences] <break time="1s"/>
Now let's move on to [next topic]. <break time="1.5s"/>
[Section 2 — 2-3 sentences] <break time="1s"/>
And finally, [last topic]. <break time="1.5s"/>
[Section 3 — 2-3 sentences] <break time="1s"/>
That's everything you need to get started. <break time="0.5s"/>
If you have questions, leave a comment below. <break time="0.5s"/> Thanks for watching!
```

### Announcement (~75 words, 30s)

```text
Big news! <break time="0.5s"/>
We're thrilled to announce [announcement]. <break time="1s"/>
This means [benefit 1] and [benefit 2] for all our users. <break time="0.5s"/>
Starting [date], you'll be able to [new capability]. <break time="1s"/>
Head to [location] to learn more. <break time="0.5s"/> We can't wait to hear what you think!
```

## Writing Tips

**Do:** Write conversationally, use contractions, spell out abbreviations ("A-P-I"), end sections clearly.

**Avoid:** Jargon without context, long parentheticals, ambiguous pronunciations, excessive `!`, run-ons, dense info without pauses.

**Pronunciation:** Spell phonetically inline — `"Our API (A-P-I)"`, `"HeyGen (hey-jen)"`, `"I read (red) the docs"`.

## Multi-Scene Scripts

Split scripts across scenes for different backgrounds or avatars. End each scene on a complete thought; open new scenes with brief context. Pause at scene starts to let visuals register.

```typescript
const multiSceneVideo = {
  video_inputs: [
    {
      character: { type: "avatar", avatar_id: "josh_lite3_20230714", avatar_style: "normal" },
      voice: { type: "text", input_text: "Welcome to our quarterly update. <break time=\"1s\"/> I'm Josh, and I'll walk you through the highlights.", voice_id: "voice_id_here" },
      background: { type: "color", value: "#1a1a2e" },
    },
    // Repeat with different input_text and background
  ],
};
```

## Testing Your Script

1. Read aloud — time yourself, check phrasing
2. Count words — verify duration
3. Check break tags — spacing and syntax
4. Preview short clip — test pronunciation uncertainty

## Voice Speed

Set via `speed` parameter: `voice: { type: "text", input_text: script, voice_id: "voice_id", speed: 1.1 }`

| Speed | Use Case |
|-------|----------|
| 0.8-0.9 | Complex topics, deliberate delivery |
| 1.0 | General use (default) |
| 1.1-1.2 | Energetic content |
| 1.3+ | Use sparingly — may reduce clarity |

See [voices.md](voices.md) for full voice configuration options.
