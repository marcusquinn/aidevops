---
description: Check OAuth pool health, test token validity, and walk users through setup
agent: Build+
mode: subagent
---

Entry point for provider-account setup and troubleshooting. Assume the user knows nothing about OAuth, pools, tokens, or providers. Diagnose first, then give exactly one next step.

## Core rules

- **One step at a time.** Give one command or action, not branches.
- **Diagnose before advising.** Run the checks first, then choose the path.
- **Use a separate terminal for auth commands.** Never ask for tokens or codes in chat.
- **Explain why, not internals.** Say what the command does; do not mention pool.json, PKCE, token endpoints, or auth hooks.
- **After any add/import:** remind them to restart OpenCode, then press Ctrl+T to choose a model.
- **Any model can run this.** `oauth-pool-helper.sh` works even on free OpenCode models with no paid provider configured.

## Workflow

### Step 1: Diagnose

Run both checks in parallel via Bash:

1. `oauth-pool-helper.sh check` — current pool state
2. `claude auth status --json 2>/dev/null` — whether Claude CLI is already authenticated

### Step 2: Choose the path

#### Path A — no accounts exist

If `claude auth status --json` shows `loggedIn: true` with a `pro` or `max` subscription, skip the provider interview and import it:

> You're already logged into Claude CLI with a **{subscriptionType}** account ({email}). Let's connect that same account here.
>
> Run this in a separate terminal:
>
> ```bash
> oauth-pool-helper.sh import claude-cli
> ```
>
> It detects your account and opens the browser to authorize. Since you're already logged in, it should be quick.

Otherwise use the standard interview:

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

After they answer, give exactly one command to run in a separate terminal:

- Anthropic: `oauth-pool-helper.sh add anthropic`
- OpenAI: `oauth-pool-helper.sh add openai`
- Cursor: `opencode auth login --provider cursor`
- Google: `oauth-pool-helper.sh add google`

Explain the flow:

- Anthropic/OpenAI/Google: "This opens your browser to log in. After you authorize, you'll get a code to paste back into the terminal. Then restart OpenCode and your account will be active."
- Cursor: "This opens your browser to log into Cursor. After you authorize, tokens are saved automatically. Restart OpenCode and Cursor models will appear when you press Ctrl+T."

After they confirm success, remind them to restart OpenCode and use Ctrl+T to select the provider model.

#### Path B — accounts exist and are healthy

Show a clean summary:

| Account | Provider | Status | Token | Validity |
|---------|----------|--------|-------|----------|
| user@example.com | anthropic | active | 2h remaining | OK |

Then say: "Everything looks good. Your pool has N account(s) and will auto-rotate if one hits rate limits."

If they only have one account, suggest: "Consider adding a second account for automatic failover when rate limited. Run `oauth-pool-helper.sh add <provider>` in a separate terminal to add another."

If Claude CLI shows a logged-in account whose email is not already in the anthropic pool, mention: "I also noticed you have a Claude {subscriptionType} account ({email}) logged in via the CLI that isn't in your pool yet. Run `oauth-pool-helper.sh import claude-cli` in a separate terminal to add it."

#### Path C — accounts exist but have problems

Give one fix at a time:

- **EXPIRED / INVALID (401) / auth-error**: "Your token for X needs re-authentication. Run `oauth-pool-helper.sh add <provider>` in a separate terminal with the same email to get a fresh token." For Cursor accounts, expired tokens are normal because they are short-lived and the plugin re-reads fresh ones from the Cursor IDE automatically. Only flag Cursor if the status is also `auth-error`.
- **Missing refresh token**: "Account X can't auto-renew. Remove it first with `oauth-pool-helper.sh remove <provider> <email>`, then re-add it with `oauth-pool-helper.sh add <provider>`."
- **All rate-limited**: "All accounts are currently rate-limited. You can wait for cooldowns to expire, or I can reset them now." If they agree, use the `model-accounts-pool` tool with `{"action": "reset-cooldowns"}`.

#### Path D — user asks to manage existing accounts

- Remove: `oauth-pool-helper.sh remove <provider> <email>`
- List: `oauth-pool-helper.sh list`
- Manually rotate: use the `model-accounts-pool` tool with `{"action": "rotate"}`

### Step 3: Verify

After any add, import, remove, or re-auth, run `oauth-pool-helper.sh check` again and report the result.
