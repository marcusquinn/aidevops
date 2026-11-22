## What

Add a macOS account and login-keychain incident reference for aidevops agents: how to triage a rejected login password or an unexpected screen-sharing indicator, how to recover after a Recovery-mode password reset sets the login keychain aside, and how to recover app data such as WireGuard tunnels that live in the old keychain.

## Why

On 2026-11-08 a maintainer's Mac rejected the correct login password after 23.5 days of uptime. The password was reset in Recovery, which set the login keychain aside as `login_renamed_1.keychain-db`. Agent sessions lost ssh, gh, signed commits and Chrome. A background `gh auth token` routine looped keychain prompts. The WireGuard app deleted its orphaned tunnel item after the restart. Recovery took several hours of ad hoc investigation. A reference would let the next session triage and recover in minutes, and avoid the mistakes made this time: assuming which password opens a file, testing copies under the wrong file name, and overwriting user files without asking.

## How

- New file: `.agents/tools/security/macos-account-keychain-recovery.md` (subagent frontmatter, SPDX header, AI-CONTEXT block).
- Pointer: add the new file to the "macOS Operations" row in `.agents/reference/domain-index.md`.
- Pattern: follow `.agents/tools/security/local-permissions-check.md` (short operating model, then reference sections).
- Content: triage log sources and read-only commands; evidence labelling; the Recovery-reset keychain mechanism; safe copy-based unlock testing (users type passwords at Terminal, never in chat); Time Machine local snapshot access; WireGuard keychain storage and recovery; agent prompt-loop containment (#37232); the restart-first rule for user-lookup outages (#37260).
- Keep it generic: no private hostnames, account IDs or local paths.

### Files Scope

- `.agents/tools/security/macos-account-keychain-recovery.md`
- `.agents/reference/domain-index.md`

## Acceptance

- `markdownlint-cli2` passes on the new file (via `.agents/scripts/linters-local.sh` or the repo markdown lint config).
- `domain-index.md` row resolves to an existing path.
- No secrets, private hostnames or private paths in the diff.

## Verification

`rg -n 'macos-account-keychain-recovery' .agents/reference/domain-index.md` and `test -f .agents/tools/security/macos-account-keychain-recovery.md`.
