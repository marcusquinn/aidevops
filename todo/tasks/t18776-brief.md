## What

Stop CodeRabbit from requesting changes on every protected release PR (`chore/release-v<semver>-provenance`) because of a missing Markdown reference definition for the new `## [X.Y.Z]` CHANGELOG heading.

## Why (observed evidence)

- Release PR #35792 (v3.39.79) and release PR #35805 (v3.39.80) both got a CodeRabbit `CHANGES_REQUESTED` review at the signed release commit. The finding was the same both times: `[X.Y.Z]` at `CHANGELOG.md:13` has no matching reference definition.
- `CHANGELOG.md` on `main` has **zero** `[x.y.z]: https://...` reference definitions in its history (checked with `rg -c '^\[[0-9]+\.[0-9]+\.[0-9]+\]: ' CHANGELOG.md`). The headings follow the Keep a Changelog bracket style but have never had link targets. So this is a convention gap across the whole repo, not a defect in any one release.
- A signed release PR cannot take a fix commit, because that breaks the merge topology (see #35798, which stranded v3.39.79). Each release currently needs a maintainer `coderabbit-nits-ok` label plus `review-bot-gate-helper.sh dismiss-coderabbit-nits <PR>` before native auto-merge can proceed. #35805 was unblocked this way.

## How

Pick the smaller option. Prefer option 1.

1. `.coderabbit.yaml`: add a `reviews.path_instructions` entry for `CHANGELOG.md` saying that version headings use bare `[X.Y.Z]` brackets by convention and must not be flagged for missing reference definitions. Alternatively, exclude `CHANGELOG.md` from review on release-provenance PRs if the config supports that.
2. Alternative: have the changelog writer emit a compare-link definition for each new version (for example `[X.Y.Z]: https://github.com/<owner>/<repo>/compare/vPREV...vX.Y.Z`). Find the writer with `rg -n "## \[" .agents/scripts --glob 'version-manager*.sh'`. This must happen before the release commit is signed. It does not backfill history.

### Files Scope

- `.coderabbit.yaml`
- `.agents/scripts/version-manager-release.sh`

## Notes

Option 2's exact changelog-writer function has not been identified. `version-manager-release.sh` is the likely file. Confirm with the `rg` command above.

## Verification

- Option 1: the next release PR gets no CHANGELOG reference-definition finding from CodeRabbit, and auto-merge proceeds without `coderabbit-nits-ok`.
- Option 2: `rg -n '^\[X\.Y\.Z\]: ' CHANGELOG.md` matches on the next release commit. ShellCheck is clean on the edited script.

Related: #35798 (never push to release provenance PRs).
