---
description: Official X API operations through the xurl CLI
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Xurl - Official X API Operations

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Use when**: reading/searching X, bookmarks, timelines, mentions, posting, replies, quotes, likes, reposts, follows, DMs, media uploads, or raw X API v2 calls.
- **Default tool**: `.agents/scripts/xurl-helper.sh` for guarded agent execution; use raw `xurl` only when the helper cannot express a safe read-only request.
- **Runtime model**: use the host agent's current model/provider connection (OpenCode xAI, Anthropic, etc.); `xurl` auth is only for X API access and is separate from model-provider auth.
- **Multi-account**: use `--app APP_NAME` for a specific X developer app/subscription context and `--username HANDLE` for a specific authenticated X account.
- **Auth check**: `xurl-helper.sh status` then `xurl-helper.sh whoami`; never read `~/.xurl`.
- **Write safety**: posting, deleting, replies, quotes, likes, reposts, follows, mutes, blocks, DMs, media upload, and raw mutating API calls require explicit user intent and `--confirm-write`.
- **Fallback**: `content/social-bird.md` can use browser cookies when official API access is unavailable, but `xurl` is preferred because it uses the official X API.

<!-- AI-CONTEXT-END -->

## Security Rules

- Never read, print, parse, summarize, upload, or send `~/.xurl` to model context.
- Never ask the user to paste X credentials, client IDs, client secrets, access tokens, refresh tokens, cookies, or bearer tokens into chat.
- Never run `xurl auth apps add` with inline secrets from an agent session. The user registers app credentials manually in their terminal.
- Never pass `--verbose`, `-v`, `--bearer-token`, `--consumer-key`, `--consumer-secret`, `--access-token`, `--token-secret`, `--client-id`, or `--client-secret`.
- Treat DMs, protected/private account data, bookmarks, and timelines as sensitive; summarize minimally and do not persist raw output unless the user explicitly asks.

## User Setup Boundary

The user completes one-time X developer app and OAuth setup outside the agent:

```bash
xurl auth apps add my-app --client-id YOUR_CLIENT_ID --client-secret YOUR_CLIENT_SECRET
xurl auth oauth2 --app my-app
xurl auth default my-app
xurl auth status
xurl whoami
```

If OAuth succeeds but commands return 401, tell the user to re-run OAuth with the same app that owns the client credentials: `xurl auth oauth2 --app my-app`, then `xurl auth default my-app`.

## Multiple Accounts and Subscriptions

`xurl` stores isolated app/account profiles, so aidevops can operate multiple brands, client accounts, developer apps, and X API subscription tiers from one machine without sharing secrets in chat.

- Use one app profile per X developer app or subscription tier: `--app client-a`, `--app brand-main`, `--app research-readonly`.
- Use `--username @handle` when the selected app has tokens for multiple X accounts.
- Always run `xurl-helper.sh whoami --app APP --username @handle` before a write action to confirm the account being used.
- Do not assume OpenCode xAI/Grok subscription identity is the same as the X account used by `xurl`; model subscriptions and X API subscriptions are separate permission planes.

Examples:

```bash
.agents/scripts/xurl-helper.sh whoami --app brand-main --username @brand
.agents/scripts/xurl-helper.sh search "from:brand launch" --app brand-main --username @brand --limit 10
.agents/scripts/xurl-helper.sh post "Approved post" --app brand-main --username @brand --confirm-write
```

## Guarded Helper

Use the helper for normal agent work:

```bash
.agents/scripts/xurl-helper.sh status
.agents/scripts/xurl-helper.sh whoami
.agents/scripts/xurl-helper.sh search "aidevops" --limit 10
.agents/scripts/xurl-helper.sh read 1234567890
.agents/scripts/xurl-helper.sh bookmarks --limit 20
.agents/scripts/xurl-helper.sh post "Draft approved by user" --confirm-write
.agents/scripts/xurl-helper.sh run -- /2/users/me
```

The helper rejects secret-bearing flags and verbose output, maps common read/write actions to `xurl`, and blocks write actions unless `--confirm-write` is present.

## Command Map

| Intent | Helper command |
| --- | --- |
| Auth status | `xurl-helper.sh status` |
| Current account | `xurl-helper.sh whoami` |
| Search posts | `xurl-helper.sh search "QUERY" --limit 10` |
| Read post | `xurl-helper.sh read POST_ID_OR_URL` |
| Timeline / mentions | `xurl-helper.sh timeline --limit 20` / `xurl-helper.sh mentions --limit 10` |
| Bookmarks / likes / DMs | `xurl-helper.sh bookmarks --limit 20` / `xurl-helper.sh likes --limit 20` / `xurl-helper.sh dms --limit 10` |
| User lookup | `xurl-helper.sh user @handle` |
| Post / reply / quote | add `--confirm-write` after explicit user approval |
| Raw read-only API | `xurl-helper.sh run -- /2/users/me` |

## Operating Workflow

1. Confirm the user requested X action and identify read-only vs write/destructive scope.
2. Run `xurl-helper.sh status`; if missing auth, stop and give setup steps without handling secrets.
3. For write actions, draft the exact text first unless the user already provided final copy.
4. Execute with `--confirm-write` only after explicit approval in the current conversation.
5. Return concise results: post ID/link, account acted as, query summary, or failure class. Do not dump raw JSON unless requested.

## OpenCode xAI Note

OpenCode's xAI/Grok provider connection can be used for reasoning by selecting that model in the runtime, but it does not replace X API OAuth. Keep model-provider auth and X API `xurl` auth separate so aidevops can run with any capable model while `xurl` owns X account permissions.
