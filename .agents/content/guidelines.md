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
- **Spelling**: British (`specialise`, `colour`, `moulding`, `draughty`, `centre`)
- **Paragraphs**: One sentence per paragraph; split at 3+ lines
- **Sentences**: Short & punchy; use spaced em-dashes ( — ) instead of subordinate clauses
- **SEO**: Bold **keywords** naturally; use long-tail variations; never stuff
- **Avoid**: "We pride ourselves...", "Our commitment to excellence...", repetitive brand names
- **HTML fields**: Use `<strong>`, `<em>`, `<p>` — not Markdown (`**bold**` won't render)
- **WP fetch**: `wp post get ID --field=content` (singular `--field`, not `--fields`)
- **Workflow**: Fetch → Refine → Structure → Update → Verify

<!-- AI-CONTEXT-END -->

Structural copy rules for website content, especially local-service pages. If a project has `context/brand-identity.toon`, take tone, vocabulary, and personality from that file; this document covers structure only. For brand identity maintenance, see `tools/design/brand-identity.md`.

## Formatting Examples

Em-dash usage:
- Good: "We finish them with marine-grade coatings — they resist swelling."
- Bad: "We finish them with marine-grade coatings, which means that they are built specifically..."

SEO keyword usage: "Hand-crafted here in Jersey, our bespoke **sash windows** are built to last."

Long-tail variations: "Jersey heritage properties", "granite farmhouse windows", "coastal climate".

## Avoid

- Robotic phrasing: "We pride ourselves on...", "Our commitment to excellence...", "Elevate your home with...".
- Brand name at sentence start — prefer "We make..." over "Trinity Joinery crafts...".
- Empty trailing blocks: `<!-- wp:paragraph --><p></p><!-- /wp:paragraph -->`.
- Markdown in HTML content fields.

## HTML Content Fields

WordPress content areas use HTML, not Markdown:

```html
<strong>Bold text</strong>
<em>Italic text</em>
<br>
<p>Paragraphs</p>
<h2>Headings</h2>
<ul><li>List items</li></ul>
```

## Content Update Workflow

1. **Fetch:** `wp post get 123 --field=content > file.txt` — `--field` (singular) avoids `Field/Value` table artefacts. Do not use `--fields=post_title,content`.
2. **Refine:** Apply these guidelines.
3. **Structure:** Keep valid block markup such as `<!-- wp:paragraph -->...`.
4. **Update:** Upload with `wp post update`.
5. **Verify:** Flush caches (`wp closte devmode enable` on Closte) and check the frontend.

## Example Transformation

**Before (AI/generic):**
> Trinity Joinery uses durable hardwoods treated to resist Jersey's salt air and humidity effectively. Expert carpenters apply marine-grade finishes for long-lasting protection with minimal upkeep.

**After (human/local):**
> Absolutely.
>
> We know how harsh the salt air and damp can be.
>
> That's why we use high-performance, rot-resistant timbers like Accoya and Sapele.
>
> We finish them with marine-grade coatings — ensuring they resist swelling, warping and weathering.

Apply these rules to product page updates unless a project-specific brief overrides them. For social and video variants, see `content/platform-personas.md`.
