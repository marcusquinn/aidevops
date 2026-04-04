# Do's and Don'ts

## Do

- Use HashiCorp Sans for headings and brand text, system-ui for body and UI text
- Enable `"kern"` on all HashiCorp Sans text
- Use product brand colors ONLY for their respective products (Terraform = purple, Vault = yellow, etc.)
- Apply uppercase labels at 13px weight 600 with 1.3px letter-spacing for section markers
- Keep shadows at the "whisper" level (0.05 opacity dual-layer)
- Use the `--mds-color-*` token system for consistent color application
- Maintain the tight-heading / relaxed-body rhythm (1.17–1.21 vs 1.50–1.69 line-heights)
- Use `3px solid` focus outlines for accessibility

## Don't

- Don't use product brand colors outside their product context (no Terraform purple on Vault content)
- Don't increase shadow opacity above 0.1 — the whisper level is intentional
- Don't use pill-shaped buttons (>8px radius) — the sharp, minimal radius is structural
- Don't skip the `"kern"` feature on headings — the font requires it
- Don't use HashiCorp Sans for small body text — it's designed for 17px+ heading use
- Don't mix product colors in the same component — each product has one color
- Don't use pure black (`#000000`) for dark backgrounds — use `#15181e` or `#0d0e12`
- Don't forget the asymmetric button padding — 9px 9px 9px 15px is intentional
