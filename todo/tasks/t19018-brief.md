<!-- aidevops:brief-schema=v2 -->

# t19018: feat(backups): detect a Backblaze safety freeze or stale last upload and surface it as a user action

## Origin

- **Created:** 2026-11-15
- **Created by:** ai-interactive (aidevops productivity mission, parent t19002 / GH#38332)
- **Conversation context:** Host I/O diagnosis showed the Backblaze client had not uploaded a file in 7.5 days. Nothing in aidevops noticed or told the user.

## What

`optimise-indexing-backups-helper.sh` gains a read-only Backblaze health check, run on macOS when `/Library/Backblaze.bzpkg` exists, that reports one of:

- `ok` — last upload recent and no freeze
- `stale:<hours>` — last upload older than a threshold (default 48 h)
- `safety_frozen:<hint>` — the client reports a safety freeze

A non-`ok` result is surfaced through an existing user-attention channel as a short human action, for example: "Backblaze backup frozen since <date>; open Backblaze and resolve the safety freeze (needs your private encryption key)". It is not an issue the user has to read.

## Why

On this host the newest `bztransmit` log repeats, every pass since 2026-11-08 19:29:

```text
ERROR BzUiUtil::Get_safety_frozen_StateFromLastSyncHostInfoXml - client is safety_frozen with hint: bzcf_missing_on_client
... this client is safety frozen and a PRIVATE_ENCRYPTION_KEY, so not attempting silent self_repair
```

`bzreports_lastfilestransmitted/bzstat_lastfile_transmitted.xml` has `date="20261107155908"`. Daily `bztransmit` logs grew from about 1 MB to 50–72 MB while the client retried every 5 s. Only a human with the private key can resolve this, and the framework already inspects Backblaze configuration (`_backblaze_apple_exclusions`, `_backblaze_path_statuses`) but never its health. Offsite backup silently stopped for a week.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** One read-only probe in an existing helper, plus routing to an existing notification path.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/optimise-indexing-backups-helper.sh` — add `_backblaze_health`, following the existing `_backblaze_*` helpers near line 343. Read `gmt_millis` from `.../bzreports_lastfilestransmitted/bzstat_lastfile_transmitted.xml`. Scan only the newest `bzlogs/bztransmit/bztransmit*.log` for the last `safety_frozen with hint: <hint>` line. Never print other XML attributes, which can contain account identifiers. Missing or unreadable files report `unknown`, never `ok`. Paths must be overridable by env, like `AIDEVOPS_BACKBLAZE_BZINFO`.
- `EDIT: .agents/workflows/optimise-macos-indexing-backups.md` — one line documenting the health result and the user action.
- Notification route: unknown path. Find the existing user-attention or notice channel (for example `rg -n 'attention|notify|toast' .agents/scripts/*-helper.sh`) and reuse it. Do not create a new channel.

### Verification

```bash
shellcheck -x -P .agents/scripts .agents/scripts/optimise-indexing-backups-helper.sh
bash .agents/scripts/tests/test-optimise-indexing-backups-helper.sh
# On a macOS host with Backblaze: the helper's report shows the health value;
# on this host it reports safety_frozen:bzcf_missing_on_client until resolved.
```

### Files Scope

- `.agents/scripts/optimise-indexing-backups-helper.sh`
- `.agents/workflows/optimise-macos-indexing-backups.md`
- `.agents/scripts/tests/test-optimise-indexing-backups-helper.sh`

## Acceptance Criteria

- [ ] The health result is one of `ok`, `stale:<hours>`, `safety_frozen:<hint>`, `unknown` or `not-installed`, and is read-only.
- [ ] No account identifiers or encryption fields are printed.
- [ ] A non-`ok` result reaches the user as a one-line action through an existing channel.
- [ ] The existing helper tests pass.

## Context & Decisions

- The framework cannot resolve the freeze itself: it needs the user's private encryption key, which must never pass through AI. Detection and a precise action line are the automatable part.
