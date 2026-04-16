#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
email_voice_analyzer.py - Analysis aggregation, AI synthesis, and profile generation.

Extracted from email-voice-miner.py to reduce file-level complexity.
Aggregates per-email pattern data, optionally synthesises via Claude,
and generates the markdown voice profile document.
"""

import json
import os
import statistics
import sys
from collections import Counter
from datetime import datetime, timezone
from typing import List, Optional

from email_voice_patterns import (
    count_sentences,
    count_words,
    detect_tone,
    extract_closing,
    extract_greeting,
    extract_recipient_type,
    extract_vocabulary,
    get_plain_body,
    strip_quoted_content,
)


# ---------------------------------------------------------------------------
# Analysis aggregation
# ---------------------------------------------------------------------------

def _normalise_phrase(text: str, max_words: int = 4) -> str:
    """Normalise a greeting/closing phrase to a lowercase key."""
    return " ".join(text.split()[:max_words]).rstrip(",.!").lower()


def _has_attachment(msg) -> bool:
    """Check whether an email message has file attachments."""
    if not msg.is_multipart():
        return False
    return any(
        part.get_content_disposition() == "attachment"
        for part in msg.walk()
    )


def _analyse_body(body: str, acc: dict) -> None:
    """Analyse a single email body and update accumulator counters."""
    greeting = extract_greeting(body)
    if greeting:
        acc["has_greeting"] += 1
        acc["greetings"][_normalise_phrase(greeting)] += 1

    closing = extract_closing(body)
    if closing:
        acc["has_closing"] += 1
        acc["closings"][_normalise_phrase(closing)] += 1

    acc["tones"][detect_tone(body)] += 1
    acc["sentence_counts"].append(count_sentences(body))
    acc["word_lengths"].append(count_words(body))
    acc["paragraph_counts"].append(
        max(1, len([p for p in body.split("\n\n") if p.strip()]))
    )

    for word, count in extract_vocabulary(body, top_n=30):
        acc["word_freq"][word] += count


def _analyse_headers(msg, acc: dict) -> None:
    """Analyse email headers and update accumulator counters."""
    to_header = msg.get("To", "")
    cc_header = msg.get("Cc", "")

    acc["recipient_types"][extract_recipient_type(to_header, cc_header)] += 1

    if cc_header:
        acc["uses_cc"] += 1
    if msg.get("Bcc", ""):
        acc["uses_bcc"] += 1
    if msg.get("In-Reply-To", ""):
        acc["reply_count"] += 1
    if _has_attachment(msg):
        acc["has_attachment"] += 1


def _build_accumulator() -> dict:
    """Create a fresh analysis accumulator with zeroed counters."""
    return {
        "greetings": Counter(),
        "closings": Counter(),
        "tones": Counter(),
        "recipient_types": Counter(),
        "word_lengths": [],
        "sentence_counts": [],
        "paragraph_counts": [],
        "word_freq": Counter(),
        "has_greeting": 0,
        "has_closing": 0,
        "uses_cc": 0,
        "uses_bcc": 0,
        "has_attachment": 0,
        "reply_count": 0,
        "total_analysed": 0,
    }


def _compute_results(acc: dict) -> dict:
    """Compute final statistics from the accumulator."""
    total = acc["total_analysed"]
    wl = acc["word_lengths"]
    sc = acc["sentence_counts"]
    pc = acc["paragraph_counts"]

    return {
        "total_analysed": total,
        "greetings": dict(acc["greetings"].most_common(10)),
        "closings": dict(acc["closings"].most_common(10)),
        "has_greeting_pct": round(acc["has_greeting"] / total * 100),
        "has_closing_pct": round(acc["has_closing"] / total * 100),
        "tones": dict(acc["tones"]),
        "dominant_tone": (
            acc["tones"].most_common(1)[0][0] if acc["tones"] else "unknown"
        ),
        "recipient_types": dict(acc["recipient_types"]),
        "avg_words_per_email": round(statistics.mean(wl) if wl else 0),
        "median_words_per_email": round(statistics.median(wl) if wl else 0),
        "avg_sentences_per_email": round(
            statistics.mean(sc) if sc else 0, 1,
        ),
        "avg_paragraphs_per_email": round(
            statistics.mean(pc) if pc else 0, 1,
        ),
        "uses_cc_pct": round(acc["uses_cc"] / total * 100),
        "uses_bcc_pct": round(acc["uses_bcc"] / total * 100),
        "reply_pct": round(acc["reply_count"] / total * 100),
        "attachment_pct": round(acc["has_attachment"] / total * 100),
        "top_vocabulary": [w for w, _ in acc["word_freq"].most_common(40)],
    }


def analyse_emails(messages: list, verbose: bool = False) -> dict:
    """Analyse a list of email messages and return aggregated pattern data.

    Returns a dict with all extracted patterns. No raw email content is
    included — only frequencies, distributions, and anonymised examples.
    """
    acc = _build_accumulator()

    for msg in messages:
        body_raw = get_plain_body(msg)
        if not body_raw or len(body_raw.strip()) < 20:
            continue

        body = strip_quoted_content(body_raw)
        if not body.strip():
            continue

        acc["total_analysed"] += 1
        _analyse_body(body, acc)
        _analyse_headers(msg, acc)

        if verbose and acc["total_analysed"] % 10 == 0:
            print(
                f"  Analysed {acc['total_analysed']}/{len(messages)} emails...",
                file=sys.stderr,
            )

    if acc["total_analysed"] == 0:
        return {}

    return _compute_results(acc)


# ---------------------------------------------------------------------------
# AI synthesis (optional, uses anthropic SDK)
# ---------------------------------------------------------------------------

def synthesise_with_ai(analysis: dict) -> Optional[str]:
    """Use Claude (sonnet) to synthesise analysis data into a narrative style guide.

    Returns the synthesised markdown string, or None if AI is unavailable.
    Requires ANTHROPIC_API_KEY env var.
    """
    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key:
        return None

    try:
        import anthropic  # pylint: disable=import-outside-toplevel
    except ImportError:
        print("WARNING: anthropic package not installed. Skipping AI synthesis.", file=sys.stderr)
        print("  Install: pip install anthropic", file=sys.stderr)
        return None

    client = anthropic.Anthropic(api_key=api_key)

    prompt = f"""You are analysing writing pattern data extracted from a person's sent email folder.
Your task: synthesise this statistical data into a concise, actionable writing style guide.

The style guide will be used by an AI email composition assistant to write emails that sound
like this person — not generic AI. Focus on what makes their voice distinctive.

ANALYSIS DATA (from {analysis['total_analysed']} sent emails):

Greeting patterns (phrase: count):
{json.dumps(analysis.get('greetings', {}), indent=2)}
Uses greeting: {analysis.get('has_greeting_pct', 0)}% of emails

Closing patterns (phrase: count):
{json.dumps(analysis.get('closings', {}), indent=2)}
Uses closing: {analysis.get('has_closing_pct', 0)}% of emails

Tone distribution:
{json.dumps(analysis.get('tones', {}), indent=2)}
Dominant tone: {analysis.get('dominant_tone', 'unknown')}

Email length:
- Average words: {analysis.get('avg_words_per_email', 0)}
- Median words: {analysis.get('median_words_per_email', 0)}
- Average sentences: {analysis.get('avg_sentences_per_email', 0)}
- Average paragraphs: {analysis.get('avg_paragraphs_per_email', 0)}

Recipient patterns:
{json.dumps(analysis.get('recipient_types', {}), indent=2)}
Uses CC: {analysis.get('uses_cc_pct', 0)}% | Uses BCC: {analysis.get('uses_bcc_pct', 0)}%
Replies (vs new): {analysis.get('reply_pct', 0)}%
Includes attachments: {analysis.get('attachment_pct', 0)}%

Frequent vocabulary (distinctive words, stop words removed):
{', '.join(analysis.get('top_vocabulary', [])[:30])}

Write a concise markdown style guide with these sections:
1. **Voice Summary** (2-3 sentences capturing the overall writing style)
2. **Greetings** (how they open emails, with examples)
3. **Closings** (how they close emails, with examples)
4. **Tone & Register** (formal/casual balance, when each is used)
5. **Email Length** (typical length, paragraph structure)
6. **Vocabulary Preferences** (characteristic words/phrases to use and avoid)
7. **Structural Patterns** (CC habits, reply style, attachment patterns)
8. **Composition Rules** (5-7 specific rules for the AI to follow)

Keep it concise — this is a reference card, not an essay. Use bullet points.
Do NOT include any personal information, email addresses, or raw email content.
"""

    try:
        response = client.messages.create(
            model="claude-sonnet-4-5",
            max_tokens=2000,
            messages=[{"role": "user", "content": prompt}],
        )
        return response.content[0].text
    except (anthropic.APIError, anthropic.APIConnectionError, KeyError, IndexError) as exc:
        print(f"WARNING: AI synthesis failed: {exc}", file=sys.stderr)
        return None


# ---------------------------------------------------------------------------
# Profile generation
# ---------------------------------------------------------------------------

def _phrase_table(title: str, data: dict, pct_key: str, analysis: dict) -> List[str]:
    """Build a markdown table section for greeting/closing patterns."""
    lines = [
        f"### {title} Patterns",
        "",
        f"Uses {title.lower()}: **{analysis.get(pct_key, 0)}%** of emails",
        "",
    ]
    if data:
        header_label = title
        lines.append(f"| {header_label} | Count |")
        lines.append(f"|{'─' * (len(header_label) + 2)}|-------|")
        for phrase, count in sorted(data.items(), key=lambda x: -x[1]):
            lines.append(f"| {phrase} | {count} |")
    else:
        lines.append(f"*No consistent {title.lower()} pattern detected.*")
    lines.append("")
    return lines


def _tone_section(analysis: dict) -> List[str]:
    """Build the tone distribution section."""
    lines = ["### Tone Distribution", ""]
    tones = analysis.get("tones", {})
    total = sum(tones.values()) or 1
    for tone, count in sorted(tones.items(), key=lambda x: -x[1]):
        pct = round(count / total * 100)
        lines.append(f"- **{tone.title()}**: {pct}% ({count} emails)")
    lines.append("")
    return lines


def _length_section(analysis: dict) -> List[str]:
    """Build the email length statistics section."""
    return [
        "### Email Length",
        "",
        f"- Average words: **{analysis.get('avg_words_per_email', 0)}**",
        f"- Median words: **{analysis.get('median_words_per_email', 0)}**",
        f"- Average sentences: **{analysis.get('avg_sentences_per_email', 0)}**",
        f"- Average paragraphs: **{analysis.get('avg_paragraphs_per_email', 0)}**",
        "",
    ]


def _recipient_section(analysis: dict) -> List[str]:
    """Build the recipient and structural patterns section."""
    lines = ["### Recipient & Structural Patterns", ""]
    rtypes = analysis.get("recipient_types", {})
    rtotal = sum(rtypes.values()) or 1
    for rtype, count in sorted(rtypes.items(), key=lambda x: -x[1]):
        pct = round(count / rtotal * 100)
        lines.append(f"- **{rtype.title()}** recipients: {pct}%")
    lines.extend([
        f"- Uses CC: **{analysis.get('uses_cc_pct', 0)}%**",
        f"- Uses BCC: **{analysis.get('uses_bcc_pct', 0)}%**",
        f"- Replies (vs new threads): **{analysis.get('reply_pct', 0)}%**",
        f"- Includes attachments: **{analysis.get('attachment_pct', 0)}%**",
        "",
    ])
    return lines


def _vocabulary_section(analysis: dict) -> List[str]:
    """Build the vocabulary preferences section."""
    lines = ["### Vocabulary Preferences", ""]
    vocab = analysis.get("top_vocabulary", [])
    if vocab:
        lines.append("Frequently used distinctive words:")
        lines.append("")
        lines.append(", ".join(f"`{w}`" for w in vocab[:30]))
    else:
        lines.append("*No distinctive vocabulary patterns detected.*")
    lines.append("")
    return lines


def generate_profile_markdown(
    analysis: dict, account: str, ai_synthesis: Optional[str],
) -> str:
    """Generate the voice profile markdown document."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    total_emails = analysis.get("total_analysed", 0)

    lines = [
        f"# Voice Profile: {account}",
        "",
        f"*Generated: {now} | Analysed: {total_emails} sent emails*",
        "",
        "> **Privacy note**: This profile contains extracted patterns only.",
        "> No raw email content, addresses, or subject lines are stored here.",
        "",
        "---",
        "",
    ]

    if ai_synthesis:
        lines.extend([
            "## AI-Synthesised Style Guide", "",
            ai_synthesis, "",
            "---", "",
            "## Raw Pattern Data", "",
            "*Source data used for the style guide above.*", "",
        ])
    else:
        lines.extend([
            "## Writing Patterns", "",
            "> AI synthesis unavailable (set ANTHROPIC_API_KEY to enable). "
            "Raw pattern data below.", "",
        ])

    lines.extend(_phrase_table(
        "Greeting", analysis.get("greetings", {}),
        "has_greeting_pct", analysis,
    ))
    lines.extend(_phrase_table(
        "Closing", analysis.get("closings", {}),
        "has_closing_pct", analysis,
    ))
    lines.extend(_tone_section(analysis))
    lines.extend(_length_section(analysis))
    lines.extend(_recipient_section(analysis))
    lines.extend(_vocabulary_section(analysis))

    return "\n".join(lines)
