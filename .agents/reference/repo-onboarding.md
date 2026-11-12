<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Repository Onboarding

Complete this when you create, clone or adopt a repository that aidevops should
maintain, and use it to audit existing repositories. `aidevops repos add` and
auto-discovery only register a repository: they do not write `.aidevops.json`,
sync labels or install workflows. Missed steps fail silently: with Pulse off or
labels missing, `auto-dispatch` issues are never picked up, and
`aidevops check-workflows` exits 0 when managed workflows are missing.

r914 flags new or blocked repositories in the session toast; run `repo-aidevops-health-helper.sh onboarding --all` to audit all maintained candidates.

Third-party upstreams you only mirror: register them with
`aidevops repos add <path> --sync-only` (`reference/repos-json-fields.md`) and
stop there.

1. **Initialize:** run `aidevops init` in a linked worktree and merge the
   result through a PR. It registers the repository, writes `.aidevops.json`,
   syncs the canonical GitHub labels, installs the metrics workflow and
   assesses security posture. Read its warnings; each one names its manual fix.
2. **Automation:** check the registry entry:

   ```bash
   jq '.initialized_repos[] | select(.slug == "<slug>") | {pulse, maintenance, local_only, priority}' ~/.config/aidevops/repos.json
   ```

   Maintained repositories need `pulse: true` and `maintenance` not `false`.
   New registrations default to Pulse on, except local-only and profile
   repositories, but older or hand-edited entries may not. Fix with
   `aidevops repos maintenance on <slug>`, then `aidevops repos pulse on <slug>`.
3. **Labels:** if init warned, run `label-sync-helper.sh sync --repo <slug>`.
   Confirm with `gh label list --repo <slug> --search auto-dispatch`.
4. **Managed workflows:** these are opt-in, and Pulse works without them. Run
   `aidevops check-workflows --repo <slug>` and read the rows, not the exit
   code. Choose by need:
   - `review-bot-gate`, `maintainer-gate`, `linked-issue-check`: needed
     before step 6 can require them as status checks.
   - `issue-triage-gate`: public repositories receiving outside issues
     (otherwise Pulse triages them later).
   - `issue-sync`: GitHub-side `TODO.md`/issue sync; needs `SYNC_PAT`.
   - `release-verify`: manual GitHub releases only.

   Preview each with
   `sync-workflows-helper.sh --repo <slug> --workflow <name> --install-missing`,
   then repeat with `--apply`, which opens a PR. Repair drift with
   `aidevops sync-workflows --apply --repo <slug>`.

   Public repositories: the gate, triage and sync workflows run on
   `pull_request_target`, which GitHub blocks by default from 2026-12-02. After
   merging them, run `actions-event-policy-helper.sh plan --repo <slug>`, then
   `apply` and check `status`. Pulse reports uncovered managed repositories daily;
   setting `safety.actions_event_policy_auto_apply` to `true` lets it apply and
   verify policies automatically. Set `AIDEVOPS_EVENT_POLICY_ENABLED=0` to disable
   the routine on a host.
5. **Secrets:** when the repository runs `issue-sync` or the metrics workflow,
   run `/setup-git` to set `SYNC_PAT` (`scripts/commands/setup-git.md`). Never
   paste tokens into a session.
6. **Branch protection:** require pull requests and the `review-bot-gate`,
   `maintainer-gate` and `linked-issue-check` status checks on the default
   branch. This is a deliberate maintainer action, required for public
   repositories. Verify with `aidevops security check <path>`. Workflows that
   push straight to the default branch, such as Cloudron catalog publication,
   then need the owner as an admin bypass actor and an owner PAT that has the
   repository in its selected access ("Repository protection" in
   `tools/deployment/cloudron-app-publishing-skill.md`). The security check
   reports that bypass as critical; that is the accepted trade-off.
7. **Type-specific steps:** Cloudron packages also need
   `tools/deployment/cloudron-package-onboarding.md`. Repositories with a user
   interface need a root `DESIGN.md`; repositories with public search targets
   need `context/keywords.md`. Standard and public init scopes seed both.

If an `auto-dispatch` issue is open, confirm the next Pulse cycle picks it up.
