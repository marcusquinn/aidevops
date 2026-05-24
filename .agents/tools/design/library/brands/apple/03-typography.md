<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# apple: Typography

## Observed source font evidence

- `SF Mono,SFMono-Regular,ui-monospace,Menlo,monospace`
- `SF Pro JP,SF Pro Text,SF Pro Icons,Hiragino Kaku Gothic Pro,ヒラギノ角ゴ Pro W3,メイリオ,Meiryo,ＭＳ Ｐゴシック,system-ui,-apple-system,BlinkMacSystemFont,Helvetica Neue,Helvetica,Arial,sans-serif`
- `SF Pro KR,SF Pro Text,SF Pro Icons,Apple Gothic,HY Gulim,MalgunGothic,HY Dotum,Lexi Gulim,system-ui,-apple-system,BlinkMacSystemFont,Helvetica Neue,Helvetica,Arial,sans-serif`
- `SF Pro SC,SF Pro Display,SF Pro Icons,PingFang SC,system-ui,-apple-system,BlinkMacSystemFont,Helvetica Neue,Helvetica,Arial,sans-serif`
- `var(--typography-html-font,`

## Substitute policy

Use exact source fonts only when they are system/open-source and appropriate for redistribution. Where the source uses commercial or hosted proprietary fonts, map the style to open-source/system alternatives in DESIGN.md tokens. Document the source font in this chapter and the substitute in `DESIGN.md`.

## Report typography requirements

- Screen body text: 16px or larger with 1.45-1.7 line height.
- PDF body text: 10.5-12pt equivalent.
- Headings: preserve the source's broad serif/sans/mono character and weight contrast.
- Code/data: use a readable monospace stack and wrap long lines in PDF.
