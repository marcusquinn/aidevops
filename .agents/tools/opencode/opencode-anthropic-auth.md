---
description: Anthropic OAuth authentication plugin for OpenCode
mode: subagent
tools:
  read: true
  bash: true
  webfetch: true
---

# OpenCode Anthropic Auth Plugin

> **v1.2.30+**: The built-in `anthropic-auth` plugin was removed. Use the **aidevops OAuth pool** — run `opencode auth login` and select **"Anthropic Pool"**.
>
> **v1.1.36–v1.2.29**: Anthropic OAuth is built-in. Do NOT add `opencode-anthropic-auth` npm package to `opencode.json` — causes TypeError from double-loading.

<!-- AI-CONTEXT-START -->

## Quick Reference

| Method | OpenCode Version | Notes |
|--------|-----------------|-------|
| **Anthropic Pool** (aidevops) | v1.2.30+ required; all versions recommended | Multi-account rotation, $0 cost |
| **Claude Pro/Max OAuth** (built-in) | v1.1.36–v1.2.29 | Single-account, $0 cost |
| **Manual API Key** | All versions | Standard rates, best for CI/CD |

**Setup (v1.2.30+):**
```bash
opencode auth login  # Select: Anthropic Pool → enter email → complete OAuth in browser
# Repeat to add more accounts for automatic rotation
```

**Setup (v1.1.36–v1.2.29):**
```bash
opencode auth login  # Select: Anthropic → Claude Pro/Max
```

<!-- AI-CONTEXT-END -->

## OAuth Pool Setup (v1.2.30+)

The aidevops OAuth pool (`oauth-pool.mjs`) replaces the removed built-in auth, adding multi-account rotation — when one account hits a 429, requests switch to the next available account automatically.

**Prerequisite:** aidevops plugin registered (done by `setup.sh`). Verify:
```bash
grep -q "opencode-aidevops" ~/.config/opencode/opencode.json 2>/dev/null && echo "OK" || echo "Run: aidevops setup"
```

**Adding accounts:**
```bash
opencode auth login
# Select: "Anthropic Pool" → enter email → browser opens → sign in → paste authorization code
```

Accounts stored in `~/.aidevops/oauth-pool.json` (0600). Repeat for additional accounts.

**Managing the pool:**
```text
/model-accounts-pool list              # Show all accounts with status
/model-accounts-pool status            # Rotation statistics
/model-accounts-pool remove user@example.com
/model-accounts-pool reset-cooldowns   # Clear rate-limit cooldowns
```

**Pool models** (appear in model picker after adding accounts):
- `anthropic-pool/claude-opus-4-6`
- `anthropic-pool/claude-sonnet-4-6`
- `anthropic-pool/claude-haiku-4-5`

## Authentication Methods

### 1. Claude Pro/Max OAuth — Built-in (v1.1.36–v1.2.29)

> v1.2.30+: use the [aidevops OAuth pool](#oauth-pool-setup-v1230) instead.

```bash
opencode auth login
# Select: Anthropic → Claude Pro/Max → browser opens → sign in → paste code
```

### 2. Create API Key via OAuth

```bash
opencode auth login
# Select: Anthropic → Create an API Key → browser opens to console.anthropic.com → paste code
```

### 3. Manual API Key

```bash
opencode auth login
# Select: Anthropic → Manually enter API Key → paste key from console.anthropic.com
```

**Switch methods:** `opencode auth logout && opencode auth login`

## Troubleshooting

| Symptom | Solution |
|---------|----------|
| OAuth authorization fails | Check correct account, active subscription, clear anthropic.com cookies |
| Token refresh failures (401) | `opencode auth logout && opencode auth login`; check `~/.config/opencode/auth.json` |
| "Anthropic Pool" missing (v1.2.30+) | Re-run `aidevops setup` |
| Plugin not detected (pre-v1.1.36) | `npm list -g opencode-anthropic-auth`; reinstall; restart OpenCode |
| API key creation fails | Check Anthropic Console org permissions; use manual key as fallback |
| Pro/Max OAuth shows non-zero costs | Verify `type: "oauth"` in `~/.config/opencode/auth.json`; re-authenticate |

**Verify authentication:**
```bash
opencode auth status
opencode run "Hello, Claude!" --model anthropic/claude-sonnet-4-6
```

**Debug:**
```bash
DEBUG=opencode:* opencode run "test" --model anthropic/claude-sonnet-4-6
jq '.anthropic' ~/.config/opencode/auth.json  # Check token expiration
```

## Security & Integration

- PKCE prevents authorization code interception; tokens stored locally, never transmitted to third parties
- OAuth pool: `~/.aidevops/oauth-pool.json` (0600) | Built-in OAuth: `~/.config/opencode/auth.json`
- Use OAuth for personal accounts; use manual API keys for CI/CD
- Never commit credential files; monitor usage at console.anthropic.com
- `setup.sh` registers the aidevops plugin automatically (external `opencode-anthropic-auth` npm package removed in aidevops v2.90.0)

**Recommended:**
- Primary agent (Build+): aidevops OAuth pool — zero cost, automatic rotation
- CI/CD: manual API key
- Add 2–3 Claude Pro/Max accounts for uninterrupted sessions

## References

- **Plugin Repository**: https://github.com/anomalyco/opencode-anthropic-auth
- **OpenCode Plugins**: https://opencode.ai/docs/plugins
- **Anthropic OAuth**: https://docs.anthropic.com/en/api/oauth
- `tools/opencode/opencode-openai-auth.md` — OpenAI Pro pool (same architecture)
- `tools/opencode/opencode.md` — OpenCode integration overview
- `tools/credentials/api-key-management.md` — API key management
- `aidevops/setup.md` — Setup script details
