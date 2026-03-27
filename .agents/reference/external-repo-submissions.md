# External Repo Issue/PR Submission (t1407)

When filing issues or PRs on repos we don't maintain, template compliance bots
(e.g., GitHub Actions that check issue format) will auto-close submissions that
don't match the repo's required templates. Many popular repos enforce this —
well-crafted issues get closed within hours if they don't use the right format.

This is a judgment call, not a deterministic check. Read the templates and
contributing guidelines, then format your submission accordingly.

## Issue Submission

Before `gh issue create --repo <slug>` on a repo NOT in `~/.config/aidevops/repos.json`:

1. Check for issue templates with explicit status handling (`404` means "missing", anything else fails):

   ```bash
   endpoint="repos/{slug}/contents/.github/ISSUE_TEMPLATE/"
   resp=$(gh api --include "$endpoint") || { echo "gh api failed: $endpoint" >&2; exit 1; }
   status=$(printf '%s\n' "$resp" | awk 'NR==1 {print $2}')
   if [[ "$status" == "404" ]]; then
     templates="[]"
   elif [[ "$status" != "200" ]]; then
     echo "gh api error $status: $endpoint" >&2
     exit 1
   else
     body=$(printf '%s\n' "$resp" | sed '1,/^\r$/d')
     templates=$(printf '%s\n' "$body" | jq -r '.[].name')
   fi
   ```

2. If templates exist, fetch the relevant one (e.g., `bug-report.yml`) using the same `--include` status pattern; only decode `200` bodies (`base64 -d`).
3. Check for `CONTRIBUTING.md` using the same `--include` status pattern; continue on `404`, fail on other non-`200` statuses.
4. Format the issue body to match the required template structure. YAML form templates (`.yml`) generate `### Label` section headers when submitted via the web UI — replicate this structure in your `--body`.
5. If no templates exist, use a clear, well-structured format (title, description, steps to reproduce, expected/actual behaviour).

## PR Submission

Before `gh pr create` targeting an external repo:

1. Check for PR templates with the same `gh api --include` status parsing (`404` allowed, other non-`200` statuses fail).
2. Check `CONTRIBUTING.md` for PR requirements (branch naming, commit format, CLA, etc.)
3. Format the PR body to match their template and follow their contributing guidelines.

## Auto-closed Submissions

If a submission is auto-closed by a compliance bot, read the bot's comment for formatting requirements, then resubmit with the correct format.

Practical examples and template mapping: `tools/git/github-cli.md` "External Repo Submissions" section.
