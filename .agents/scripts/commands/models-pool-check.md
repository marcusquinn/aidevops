---
description: Check OAuth pool health, test token validity, and walk users through setup
agent: Build+
mode: subagent
---

This command is the single entry point for users to understand and manage their AI model provider accounts. Assume the user knows nothing about OAuth, pools, tokens, or providers. Your job is to diagnose their situation and guide them through exactly what they need — step by step, one thing at a time.

## Workflow

### Step 1: Diagnose

Run two checks in parallel via Bash:

1. `oauth-pool-helper.sh check` — current pool state
2. `claude auth status --json 2>/dev/null` — check if Claude CLI is already authenticated

This works on any model, including free OpenCode models — it doesn't require a paid provider to run.

### Step 2: Interpret and act

Based on the output, follow the appropriate path:

**Path A — No accounts exist:**

First, check the Claude CLI auth result. If `claude auth status --json` returned `loggedIn: true` with a `pro` or `max` subscription, the user already has a working Claude account — they just haven't connected it to the pool yet. Skip the "which provider?" interview and go straight to the import:

> You're already logged into Claude CLI with a **{subscriptionType}** account ({email}). Let's connect that same account here.
>
> Run this in a separate terminal:
>
> ```
> oauth-pool-helper.sh import claude-cli
> ```
>
> It will detect your account and open the browser to authorize. Since you're already logged in, it should be quick.

If Claude CLI is not installed or not logged in, fall back to the standard interview:

> You don't have any AI provider accounts connected yet. Let's set one up.
>
> You'll need a paid subscription to one of these:
>
> - **Claude Pro or Max** ($20-100/mo from anthropic.com) — for Claude models
> - **ChatGPT Plus or Pro** ($20-200/mo from openai.com) — for GPT/o-series models
> - **Cursor Pro** ($20/mo from cursor.com) — for models via Cursor's proxy
> - **Google AI Pro or Ultra** ($25-65/mo from one.google.com) — for Gemini models via Gemini CLI
>
> Which provider do you have a subscription with?

Once they answer, give them the exact command to run in a separate terminal (not in this chat):

For Anthropic: `oauth-pool-helper.sh add anthropic`

For OpenAI: `oauth-pool-helper.sh add openai`

For Cursor: `opencode auth login --provider cursor`

For Google: `oauth-pool-helper.sh add google`

For Anthropic/OpenAI/Google, explain: "This will open your browser to log in. After you authorize, you'll get a code to paste back into the terminal. Once done, restart OpenCode and your account will be active."

For Cursor, explain: "This opens your browser to log into Cursor. After you authorize, tokens are saved automatically. Restart OpenCode and Cursor models will appear when you press Ctrl+T."

After they confirm it worked, tell them to restart OpenCode, then use Ctrl+T to select a model from the provider.

**Path B — Accounts exist and are healthy:**

Show a clean summary:

| Account | Provider | Status | Token | Validity |
|---------|----------|--------|-------|----------|
| user@example.com | anthropic | active | 2h remaining | OK |

Then: "Everything looks good. Your pool has N account(s) and will auto-rotate between them if one hits rate limits."

If they only have one account, suggest: "Consider adding a second account for automatic failover when rate limited. Run `oauth-pool-helper.sh add <provider>` in a separate terminal to add another."

Additionally, if `claude auth status --json` shows a logged-in account whose email is NOT already in the anthropic pool, mention: "I also noticed you have a Claude {subscriptionType} account ({email}) logged in via the CLI that isn't in your pool yet. Run `oauth-pool-helper.sh import claude-cli` in a separate terminal to add it."

**Path C — Accounts exist but have problems:**

For each problem, give the specific fix — one at a time:

- **EXPIRED / INVALID (401) / auth-error**: "Your token for X needs re-authentication. Run `oauth-pool-helper.sh add <provider>` in a separate terminal with the same email to get a fresh token." For Cursor accounts, expired tokens are normal — Cursor tokens are short-lived and the plugin re-reads fresh ones from the Cursor IDE automatically. Only flag it if the status is also `auth-error`.
- **Missing refresh token**: "Account X can't auto-renew. Remove it first with `oauth-pool-helper.sh remove <provider> <email>`, then re-add it with `oauth-pool-helper.sh add <provider>`."
- **All rate-limited**: "All accounts are currently rate-limited. You can wait for cooldowns to expire, or I can reset them for you now." If they say yes, use the `model-accounts-pool` tool with `{"action": "reset-cooldowns"}`.

**Path D — User asks about removing or managing:**

- To remove: `oauth-pool-helper.sh remove <provider> <email>`
- To list: `oauth-pool-helper.sh list`
- To manually rotate: use the `model-accounts-pool` tool with `{"action": "rotate"}`

### Step 3: Verify

After any change (add/remove/re-auth), run `oauth-pool-helper.sh check` again to confirm the fix worked. Tell the user the result.

## Key principles

- **One step at a time.** Don't dump all commands at once. Guide through the immediate next action, wait for confirmation, then proceed.
- **Separate terminal for add commands.** The `oauth-pool-helper.sh add` command needs a real terminal. For Anthropic/OpenAI/Google it opens a browser; for Cursor it reads from the IDE (instant, no browser). Always say "run this in a separate terminal" — never suggest pasting tokens or codes into this chat.
- **Explain why, not just what.** "This connects your Claude subscription so you can use Claude models here" is better than "This adds an OAuth token to the pool."
- **Any model can run this.** The diagnostic uses `oauth-pool-helper.sh` (a shell script). It works even on free OpenCode models with no provider configured. The user doesn't need a working paid provider to check their setup.
- **Don't mention internals.** Users don't need to know about pool.json, PKCE, token endpoints, auth hooks, or OAuth flows. They need "run this command, then restart."
- **After adding, always remind:** restart OpenCode, then Ctrl+T to pick a model.
