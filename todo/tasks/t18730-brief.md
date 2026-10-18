## What

The aidevops README's hand-maintained badge row puts the wide languages chart (`docs/metrics/badges/languages.svg`) in the same paragraph as the small Lines-of-code and Dependencies badges, so GitHub renders it inline with them — the layout bug fixed for managed badge blocks in GH#35012/PR #35015.

## Why

Same visual defect the badge layout guard now prevents in managed blocks. aidevops keeps a hand-maintained row (Version badge is updated by `version-manager-files.sh`; npm and Homebrew badges are not in the managed template), so it is not converted to a managed block.

## How

Insert one blank line before the languages chart line in the README badge row. No other change.

### Files Scope

- `README.md`

## Acceptance Criteria

- The languages chart line is preceded by a blank line, so it renders as its own paragraph.
- No other README line changes (`git diff --stat` shows README.md with 1 insertion).

## Context

Found while adding badge blocks to registered repos without one (follow-up to PR #35021).
