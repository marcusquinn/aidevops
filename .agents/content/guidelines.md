---
description: Content guidelines for AI copywriting
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: false
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Content Guidelines for AI Copywriting

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Tone**: Authentic, local, professional but approachable, British English
- **Spelling**: British (specialise, colour, moulding, draughty, centre)
- **Paragraphs**: One sentence per paragraph, no walls of text
- **Sentences**: Short & punchy, use spaced em-dashes ( — ) for emphasis
- **SEO**: Bold **keywords** naturally, avoid stuffing, use long-tail variations
- **Avoid**: "We pride ourselves...", "Our commitment to excellence...", repetitive brand names
- **HTML fields**: Use `<strong>`, `<em>`, `<p>` instead of Markdown
- **WP fetch**: Use `wp post get ID --field=content` (singular, not --fields)
- **Workflow**: Fetch -> Refine -> Structure -> Update -> Verify
<!-- AI-CONTEXT-END -->

Structural copy rules for website content, especially local-service pages. If a project has `context/brand-identity.toon`, take tone, vocabulary, and personality from that file; this document covers structure only. For brand identity maintenance, see `tools/design/brand-identity.md`.

## Core Rules

- Sound like a local expert, not a generic corporation.
- Be professional but approachable.
- Use British English throughout (`specialise`, `colour`, `moulding`, `draughty`, `centre`).
- Be direct. Cut fluff.
- Prefer "We make..." to "Trinity Joinery crafts...".

## Formatting

- Use one sentence per paragraph for screen readability, especially on mobile.
- Avoid walls of text. If a paragraph runs 3+ lines, split it.
- Keep sentences short and punchy.
- Use spaced em-dashes (` — `) for emphasis or connection instead of long subordinate clauses.
  - Good: "We finish them with marine-grade coatings — they are built specifically to resist swelling."
  - Bad: "We finish them with marine-grade coatings, which means that they are built specifically..."

### SEO

- Bold primary keywords naturally.
  - Example: "Hand-crafted here in Jersey, our bespoke **sash windows** are built to last."
- Never stuff keywords. If it sounds forced, rewrite it.
- Use long-tail variations such as "Jersey heritage properties", "granite farmhouse windows", and "coastal climate".

## Avoid

- Robotic phrasing such as "We pride ourselves on...", "Our commitment to excellence...", and "Elevate your home with...".
- Repeating the brand name at the start of every sentence.
- Empty trailing blocks such as `<!-- wp:paragraph --><p></p><!-- /wp:paragraph -->`.
- Markdown in HTML content fields.

## HTML Content Fields

Use HTML tags, not Markdown, in WordPress content areas.

```html
<strong>Bold text</strong>
<em>Italic text</em>
<br>
<p>Paragraphs</p>
<h2>Headings</h2>
<ul><li>List items</li></ul>
```

Markdown like `**bold**` will not render in HTML fields.

## Content Update Workflow

1. **Fetch:** Download with `wp post get`; use `--field=content` (singular) to get raw HTML without table headers or metadata.
   - Correct: `wp post get 123 --field=content > file.txt`
   - Incorrect: `wp post get 123 --fields=post_title,content > file.txt` because it adds `Field/Value` table artefacts.
2. **Refine:** Apply these guidelines.
3. **Structure:** Keep valid block markup such as `<!-- wp:paragraph -->...`.
4. **Update:** Upload with `wp post update`.
5. **Verify:** Flush caches (`wp closte devmode enable` on Closte) and check the frontend.

## Example Transformation

**Before (AI/generic):**
> Trinity Joinery uses durable hardwoods treated to resist Jersey’s salt air and humidity effectively. Expert carpenters apply marine-grade finishes for long-lasting protection with minimal upkeep.

**After (human/local):**
> Absolutely.
>
> We know how harsh the salt air and damp can be.
>
> That’s why we use high-performance, rot-resistant timbers like Accoya and Sapele.
>
> We finish them with marine-grade coatings — ensuring they resist swelling, warping and weathering.

Apply these rules to product page updates unless a project-specific brief overrides them. For social and video variants, see `content/platform-personas.md`.
