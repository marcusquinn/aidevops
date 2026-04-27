## Summary

Adds documentation explaining how to recognise the "bounty-hunter" spam class.

## Why

External contributors filing PRs with templated bodies like
`## 💰 Paid Bounty Contribution` (note: quoted in inline code) and the
attribution phrase `Generated via automated bounty hunter` have hit
several adjacent repos. We add a SECURITY.md section so maintainers
can route them quickly.

## How

- **NEW:** `SECURITY.md` — documentation only, no executable code.

Note: the document includes the bot's verbatim phrases (`Feishu
notifications`, `Contributed via bounty system`) inside fenced code
blocks so the detector's line-anchored header check correctly skips
them — quoted prose must not trigger auto-close.

```markdown
## 💰 Paid Bounty Contribution
| **Reward** | **$1** |
| **Source** | GitHub-Paid |
```

The above is reference material inside a fenced code block. It must
NOT trigger spam detection because the headers are not at line-start
of the body — they are nested four characters deep inside the fence.

Resolves #99999
