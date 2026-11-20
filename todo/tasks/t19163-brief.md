# fix(decisions): the --max cap fills up on the first repo alphabetically and hides every other repo's holds

## Origin

Interactive productivity mission session, 2026-11-19. While checking the maintainer decision queue for three blocked starter-sync issues, those issues did not appear in it.

## What

`maintainer-decisions-helper.sh list` (the `/decisions` queue) must spread its `--max` classification budget across every managed repo, so that no repo's holds are hidden by another repo's volume.

## Why

- `_md_list` sorted all discovered refs lexicographically (`refs=$(_md_discover | sort -u)`) and stopped after `MD_MAX` (default 300). With more than 300 open holds in the alphabetically first repository, every other repository's holds were never classified.
- Observed 2026-11-19: `list` printed `stopped at --max 300; more held issues exist`, and every row came from that first repository. Three open `needs-maintainer-input` starter-sync holds in other managed repos were absent. The queue exists to replace opening each issue, so a silently truncated queue leaves those holds waiting with nobody seeing them.

## How (Approach)

- `.agents/scripts/maintainer-decisions-helper.sh`:
  - Add `_md_interleave_refs`. It dedupes refs, orders them oldest issue first within each repo, and interleaves round-robin across repos (awk rank + sort; Bash 3.2 compatible).
  - `_md_list` pipes discovery through it, classifies the first `MD_MAX` refs, and when it truncates, warns with the totals (`classifying N of M held issues across R repos ...`) and points to `--repo` or a larger `--max`.
  - Document the shared cap in the `--max` usage text.

### Files Scope

- `.agents/scripts/maintainer-decisions-helper.sh`

## Acceptance Criteria

- `shellcheck .agents/scripts/maintainer-decisions-helper.sh` is clean.
- On synthetic refs, `_md_interleave_refs` emits a round-robin order with oldest numbers first per repo and drops duplicates and malformed lines.
- A live `list --max 60` run shows holds from more than one managed repository, including the starter-sync holds.
