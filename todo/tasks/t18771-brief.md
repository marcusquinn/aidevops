## What

Enforce a strict, deterministic **no-redirect-links** policy for public contributions and for every aidevops session:

1. Any issue, PR, comment, review comment, discussion, or discussion comment from a non-collaborator that contains a URL-shortener or redirector link is spam. It is closed or hidden, labelled `spam`, and locked **without any comment**. The author is blocked from every repository the maintainer controls.
2. aidevops never resolves, fetches, or opens a redirect link, in interactive sessions, workers, or the pulse. That covers Bash network clients (`curl`, `wget`, `open`, ...), OpenCode tools with URL arguments (WebFetch, browser MCP navigation), and Claude Code `WebFetch`/MCP tools.

## Why

Issue #35640 was templated star-exchange spam: a security-themed title, engagement bait, and an anchor-masked URL-shortener link. The same title template was filed against several public repositories about an hour apart from a 9-day-old account with no footprint. Evidence gathered during review:

- `external-content-spam-detector.sh score issue 35640` → `score 2, verdict clean`. `bounty-spam-detector.sh` → `clean`. Neither has a redirect-link signal, and `prompt-injection-patterns.yaml` has no shortener pattern.
- `external-content-spam-detector.sh` is not wired into any workflow or the pulse.
- `.github/workflows/issue-triage-gate.yml` publicly thanked and @-mentioned the spammer (welcome comment) before any spam check.
- `maintainer-gate-reusable.yml` "Protect Triage Labels" posted a label-protection notice on the spam issue after maintainer cleanup.
- Nothing scans `issue_comment`, `pull_request_review_comment`, or discussion content for spam.
- No framework capability blocks users. Actions `GITHUB_TOKEN` cannot call `PUT /user/blocks`, so bans need the maintainer token (pulse).
- The "never fetch untrusted URLs" rule in `reference/gh-command-discipline.md` is prompt-only. `network-tiers.conf` denies only 5 shorteners, and only for sandboxed workers ("Interactive sessions are unrestricted").
- Resolving a link, even in a remote sandbox, credits the campaign through per-account UTM attribution. Detection must therefore be host-based and never resolve.

## How

- Single source of truth: `.agents/configs/redirect-hosts.conf`. One host, `*.host` wildcard, or `host/path-prefix` per line.
- Pure scanner `.agents/scripts/redirect_link_policy.py` (`scan`, `check-url`, `check-argv`). It normalises obfuscation (zero-width characters, fullwidth/ideographic dots, `[.]`/`(.)`, `hxxp`, percent-encoded hosts), matches scheme URLs, markdown/HTML links, and bare `host/path` tokens with boundaries, and never performs network I/O.
- `.agents/scripts/redirect-link-guard-helper.sh`: `enforce` (close/hide + `spam` label + lock, no comment) and `block` (user-level plus admin orgs; never OWNER/MEMBER/COLLABORATOR or bots). It also provides `sweep` and is sourceable by the pulse (`redirect_spam_sweep_all_repos`, interval-gated).
- `.github/workflows/redirect-link-spam-guard.yml`: base checkout only and trusted-author skip (`#aidevops:trust-boundary`), covering issues, `pull_request_target`, issue/PR-review comments, and discussions.
- Triage gates suppress the welcome comment for redirect-link spam. The label-protection notice is skipped for closed or `spam` issues; NMR re-application is unchanged.
- Command policy: new `command_policy_redirect.py` decision evaluated for **all** sessions (not only workers) in `command_policy_evaluation.py`.
- OpenCode: `quality-hooks-redirect-link.mjs` checks URL-bearing tool args before execution.
- Claude Code: `git_safety_guard.py` handles `WebFetch|mcp__.*` URL args. `install-hooks-helper.sh` registers that matcher.
- Docs: `CONTRIBUTING.md` link policy, `reference/gh-command-discipline.md`, `workflows/review-issue-pr.md` (spam closures: no comment, keep NMR), plus the spam signal in `external-content-spam-detector.sh`.

### Files Scope

- `.agents/configs/redirect-hosts.conf`
- `.agents/scripts/redirect_link_policy.py`
- `.agents/scripts/redirect_link_rules.py`
- `.agents/scripts/redirect_link_tool_check.py`
- `.agents/scripts/redirect-link-guard-helper.sh`
- `.agents/scripts/command_policy_redirect.py`
- `.agents/scripts/command_policy_evaluation.py`
- `.agents/scripts/external-content-spam-detector.sh`
- `.agents/scripts/pulse-wrapper.sh`
- `.agents/scripts/install-hooks-helper.sh`
- `.agents/scripts/tests/test-redirect-link-policy.sh`
- `.agents/scripts/tests/test-maintenance-selector-contract.sh`
- `TODO.md`
- `todo/tasks/t18771-brief.md`
- `.agents/hooks/git_safety_guard.py`
- `.agents/plugins/opencode-aidevops/quality-hooks-redirect-link.mjs`
- `.agents/plugins/opencode-aidevops/quality-hooks.mjs`
- `.github/workflows/redirect-link-spam-guard.yml`
- `.github/workflows/issue-triage-gate.yml`
- `.github/workflows/pr-triage-gate.yml`
- `.github/workflows/maintainer-gate-reusable.yml`
- `.agents/reference/gh-command-discipline.md`
- `.agents/workflows/review-issue-pr.md`
- `CONTRIBUTING.md`

## Acceptance Criteria

- [ ] `redirect_link_policy.py scan` flags shortener links in scheme, markdown, HTML, bare, and obfuscated forms, and does not flag ordinary GitHub/docs links or lookalike hosts (`this.gd`, `notbit.ly`).

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-redirect-link-policy.sh"
  ```

- [ ] The shared command policy forbids `curl`/`wget`/`open` of a redirect host in an interactive (non-worker) evaluation and still allows ordinary hosts.

  ```yaml
  verify:
    method: bash
    run: "python3 .agents/scripts/command-policy-helper.py check-command --cwd . --command 'curl https://bit.ly/x'; test $? -eq 20"
  ```

- [ ] Enforcement never posts a comment, never resolves the link, and never acts on OWNER/MEMBER/COLLABORATOR or bot authors.
- [ ] `external-content-spam-detector.sh` scores a redirect-link body from a non-collaborator as `spam-likely`.
- [ ] ShellCheck clean on changed shell files; workflow YAML parses.

## Context & Decisions

- Maintainer decision: ban **every** redirect link; there is no legitimate need for one. The maintainer's own sites are not on the list, so no exception mechanism is published.
- Spam closures carry no comment (no attention, no notification payload). NMR stays applied by design on closed spam.
- Detection is host-based only. Destinations are never resolved, even in sandboxes.
