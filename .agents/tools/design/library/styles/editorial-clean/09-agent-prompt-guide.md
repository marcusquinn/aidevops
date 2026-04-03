# 9. Agent Prompt Guide

## Quick Colour Reference

| CSS Variable | Hex | Role |
|-------------|-----|------|
| `--color-bg` | `#FAF8F5` | Warm off-white page background |
| `--color-surface` | `#FFFFFF` | Cards, inputs, overlays |
| `--color-surface-dark` | `#F2EFE9` | Code blocks, pull quote bg |
| `--color-text` | `#1a1a1a` | Headings |
| `--color-text-body` | `#2d2d2d` | Article body text |
| `--color-text-secondary` | `#666666` | Captions, bylines |
| `--color-text-tertiary` | `#999999` | Footnotes, deemphasised |
| `--color-link` | `#4a6fa5` | Inline links, active nav |
| `--color-link-hover` | `#364f75` | Hovered links |
| `--color-border` | `#E8E4DF` | Dividers, separators |
| `--color-highlight` | `#FFF3CD` | Text selection, highlights |
| `--color-success` | `#2d6a4f` | Success states |
| `--color-error` | `#c0392b` | Error states |

## Ready-to-Use Prompts

**Prompt 1 — Article page:**

> Build an article page following DESIGN.md. Page background #FAF8F5 with a minimal top navigation bar (60px, #FAF8F5, 1px bottom border #E8E4DF). Masthead in Playfair Display 24px/700. Article container centred at 680px max-width. Category label at top: 12px uppercase in #4a6fa5. Title in Playfair Display 40px/700/1.2 line-height in #1a1a1a. Byline: 14px/500 in #999999. Body text: Source Sans 3, 18px/400/1.7 line-height in #2d2d2d. Images can break out to 900px. Include a pull quote (Playfair Display italic 28px with 3px left border in #E8E4DF). Inline links in #4a6fa5 with subtle underlines.

**Prompt 2 — Article listing/index page:**

> Create a blog index page following DESIGN.md. Background #FAF8F5, same minimal nav. Two-column grid of article cards (max 1080px container). Each card: optional 16:9 image, category label (12px uppercase #4a6fa5), title in Playfair Display 24px/700 #1a1a1a (hover → #4a6fa5), excerpt in 16px/400 #666666, byline in 14px #999999. Cards separated by 48px vertical gap. No borders or shadows on cards — whitespace handles separation. Top of page: featured article with larger treatment (full-width image, 36px title).

**Prompt 3 — Newsletter signup page:**

> Build a newsletter signup page following DESIGN.md. Centred at 560px max-width on #FAF8F5 background. Heading in Playfair Display 36px/700. Description in Source Sans 3 18px/1.7 #2d2d2d. Email input: 16px, #FFFFFF background, 1px #E8E4DF border, 4px radius. Focus state: #4a6fa5 border with subtle ring. Subscribe button: #1a1a1a background, #FAF8F5 text, 4px radius. Below: "No spam" reassurance in 14px #999999. The entire form sits in a #FFFFFF card with 48px padding and a barely-there shadow (0 1px 4px rgba(0,0,0,0.04)).
