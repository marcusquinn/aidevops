---
id: no-hardcoded-secrets
ttsr_trigger: (api[_-]?key|password|secret|token)\s*[:=]\s*['"][A-Za-z0-9+/=_-]{16,}
severity: error
repeat_policy: always
tags: [security]
enabled: true
---

STOP: You are about to hardcode a secret value. This violates security rules.

- Never expose credentials in output, logs, or code
- Store secrets via `aidevops secret set NAME` (gopass encrypted)
- Or use `~/.config/aidevops/credentials.sh` (plaintext fallback, 600 permissions)
- Use environment variable references or placeholder values in code
