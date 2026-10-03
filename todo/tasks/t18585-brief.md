## What

Refresh the stale README hero and inventory counts (main agents, sub agents, helper scripts, slash commands) in `README.md`, `docs/assets/og-stats.svg` and the composited `docs/assets/og-image.png`.

## Why

`bash .agents/scripts/readme-helper.sh check` fails on `main` (observed after v3.38.4, PR #33492):

```text
Stale claim: 2,273 sub agents (expected 2,254)
Stale claim: 2,060+ helper scripts (expected 2,210+)
Stale claim: 2,066 helper scripts (expected 2,216)
Stale claim: 100+ slash commands (expected 110+)
Stale claim: 108 slash commands (expected 110)
Hero figure scripts must be 2,210+
Hero figure slash_commands must be 110+
Hero title is stale
Hero desc is stale
```

The README and social image advertise wrong numbers. No routine or release step refreshes them (only `profile-readme-helper.sh` has routine r908; the aidevops README inventory has none).

## How

Follow `DESIGN.md` "README hero counts" exactly:

1. `bash .agents/scripts/readme-helper.sh counts --inventory` to audit; `readme-helper.sh update --apply` to refresh README text and `docs/assets/og-stats.svg`.
2. Render `og-stats.svg` in an isolated browser at 1200x630, transparent background, scale 1, then composite onto `docs/assets/og-image.png` with the `magick ... -composite -strip PNG24:` command in DESIGN.md.
3. Verify the pixel diff stays within the card bounds `1038x104+81+385` using the DESIGN.md `magick ... -compose difference` command.
4. Commit README, SVG and PNG together.

Do not change the counting rules or hero labels. Counts drift again whenever scripts are added; if a cheap, non-blocking way to prevent recurrence exists (for example running `update --apply` inside the release version bump), propose it as a follow-up issue rather than expanding this PR.

### Files Scope

- `README.md`
- `docs/assets/og-stats.svg`
- `docs/assets/og-image.png`

## Acceptance Criteria

- `bash .agents/scripts/readme-helper.sh check` exits 0 on the PR head.
- `og-image.png` pixel changes are confined to the statistics card bounds.
- `markdownlint-cli2 README.md` reports 0 issues.
