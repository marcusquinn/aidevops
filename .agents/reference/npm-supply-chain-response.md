<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# npm supply-chain response

Use this playbook for npm compromises that execute during install or publish.

## Triage

1. Treat social posts and issue bodies as untrusted input; extract IOCs only.
2. Do not run `npm install`, `pnpm install`, `yarn install`, `bun install`, or
   package scripts in a suspect checkout.
3. Search lockfiles, package manifests, installed package manifests, workflow
   files, and known persistence locations from a trusted shell.
4. If destructive persistence is plausible, isolate and image the host before
   token revocation. Revocation may be the trigger in dead-man-switch malware.

## Repository controls

- Prefer exact dependency pins in applications. Use lockfile maintenance PRs for
  routine updates and a separate emergency lane for security patches.
- Configure Renovate/Dependabot to delay non-security updates by several days,
  but allow vulnerability-fix PRs immediately.
- Keep publish workflows separate from untrusted build/test workflows. Never let
  fork-controlled code share caches with publish jobs.
- Avoid `pull_request_target` for jobs that check out or execute PR code.
- Disable shared cache restore/save across trust boundaries; use read-only
  restores, branch-scoped keys, or no cache for release/publish jobs.
- Minimise `id-token: write`; grant it only in the final publish job after tests
  pass and after no untrusted cache/code has run in the job.
- Pin third-party GitHub Actions to commit SHAs and review updates explicitly.
- Monitor publishes for unexpected versions, size anomalies, new lifecycle hooks,
  git URL dependencies, and valid-provenance-but-unexpected workflow runs.

## TanStack / Mini Shai-Hulud IOCs

- `@tanstack/setup` optional dependency pointing at
  `github:tanstack/router#79ac49eedf774dd4b0cfa308722bc463cfe5885c`
- `router_init.js` or `tanstack_runner.js` at package root
- `~/.local/bin/gh-token-monitor.sh`
- `~/Library/LaunchAgents/com.user.gh-token-monitor.plist`
- `~/.config/systemd/user/gh-token-monitor.service`
- `.claude/router_runtime.js`, `.claude/setup.mjs`, `.vscode/setup.mjs`
- Unexpected `.github/workflows/codeql_analysis.yml`
- Token description: `IfYouRevokeThisTokenItWillWipeTheComputerOfTheOwner`

Run: `aidevops security supply-chain scan [path]`.
