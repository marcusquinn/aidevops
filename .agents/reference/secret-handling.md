<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Secret Handling Reference

Rules for preventing credential exposure in AI agent sessions. Extracted from `AGENTS.md` "Security Rules".

**Trigger rules in AGENTS.md:** NEVER expose credentials in output/logs. Treat command output as transcript-visible. Full rules: `reference/secret-handling.md`.

---

## Storing multi-line secrets

Run secret setup in your own terminal, never paste secret values into AI chat.
The hidden `aidevops secret set NAME` prompt accepts **one line only**. For PEM
keys, JSON service-account credentials, or other multi-line values, initialize
encrypted storage with `aidevops secret init`, then use:

```bash
chmod 600 /secure/path/app.pem
aidevops secret set APP_KEY --from-file /secure/path/app.pem
```

`--from-file` requires a readable regular file, refuses symlinks and any
group/other permissions, and validates the opened descriptor before reading.
Alternatively, full redirected/piped stdin is accepted, for example
`aidevops secret set APP_KEY < /secure/path/app.pem` in your terminal.
Embedded newlines are preserved; trailing newlines are trimmed consistently
with environment injection. NUL bytes are rejected. PEM keys remain valid
without their final newline. The plaintext `credentials.sh` fallback refuses
multi-line input without changing existing credentials; use gopass instead.
It also refuses dollar signs and backticks, which its line-oriented readers
cannot safely round-trip as literal shell data.

Verify without printing the key:

```bash
aidevops secret APP_KEY -- sh -c 'printf "%s\n" "$APP_KEY" | openssl pkey -noout -check'
```

After successful storage and verification, delete the source file using your
local secure-deletion policy (ordinary removal does not guarantee erasure on
SSDs, snapshots or backups). A detected multi-line terminal paste is silently
drained and rejected, never stored as a first-line fragment. The drain waits
for a short quiet interval; it cannot protect arbitrary delayed input, so
always use file/stdin input for multi-line secrets. If a key was previously
pasted into the shell or appears in scrollback/history, revoke and replace it.

---

## Headless runner GPG availability

`aidevops secret check NAME` is status-only: exit 0 means readable, 1 means
missing (or empty plaintext), and 3 means a gopass-owned entry is unreadable
or empty. It never prints values or decryption errors. The runner capability
log reports `reason=secret_missing name=NAME`, `secret_unreadable`,
`check_timeout`, or `probe_failed path=...` without secret material.

Gopass is authoritative for names it owns: failed decryption **does not** fall
back to `credentials.sh`. Deferrals state `store=gopass fallback=disabled`.
A locked agent is the common cause, but an unreadable entry can also mean
corruption or missing decryption keys. Status-only decryption is bounded using
the existing four-second headless resolver; an owned entry that times out
returns 3. The outer capability watchdog reports `check_timeout` if the whole
command (including store listing) exceeds five seconds.
Pulse emits one `runner_health: gpg store locked or entry unreadable` line
per cycle and skips subsequent secret-gated checks for that cycle; ungated
candidates can still run. `runner_capability_health secret_gated_deferred=N`
records the running count of rejected gate calls, not a final candidate total.
Cycle state contains only names/counts in a mode-600 file under the runner's
workspace temp directory, with an exclusive lock shared across watchdog
subshells and concurrent candidates. Old cycle metadata expires after a day.
The next cycle retries, so unlocking does not require restarting pulse.

For unattended runners, provision the agent unlock outside AI chat. Set both
`default-cache-ttl` and `max-cache-ttl` in the operator's `gpg-agent.conf` long
enough for the intended unattended window, reload with `gpg-connect-agent
reloadagent /bye`, then perform one interactive unlock after every agent
restart. Reloading or connecting alone does **not** unlock a key. Finite cache
TTLs expire: renew the unlock before expiry rather than assuming an unlimited
cache. Longer TTLs increase the period a compromised runner can decrypt data;
choose them according to the runner's security policy, not automatically.

Alternatively, use a securely stored `credentials.sh` entry (mode 600) and
remove the corresponding gopass entry through the operator's normal secret
management process. Adding plaintext while retaining the gopass entry cannot
repair a locked-store deferral. Never put passphrases or secret values in
logs, issue bodies, command arguments, or transcripts.

---

## 8.1 Session Transcript Exposure (t1457)

**Threat:** AI tool inputs and outputs are captured in session transcripts and may be sent to a remote model provider.

- Treat command input + stdout/stderr as transcript-visible. If printing it would leak a secret in chat, it leaks in tool output too.
- When giving secret setup instructions, start with: `WARNING: Never paste secret values into AI chat. Run the command in your terminal and enter the value at the hidden prompt.`
- Prefer secret-safe patterns: key-name listings, masked previews, one-way fingerprints, exit-code checks.
- Avoid writing raw secrets to temp files (e.g., `/tmp/*.json`); prefer in-memory piping. If unavoidable, clean up immediately.
- If a command can expose secrets and no safe alternative exists, do not run it via AI tools — instruct the user to run it locally.

---

## 8.2 Never Run Commands That Print Secret Values (t2846)

**Threat:** Agent runs commands whose output contains secret values, exposing credentials in the transcript. Once a secret appears in conversation, it must be rotated.

**Incident:** ILDS t006 — Zoho OAuth credentials exposed via `gopass show`, required rotation.

- NEVER run, suggest, or output any command whose stdout/stderr would contain secret values. Principle, not a blocklist — apply judgment to ANY command that could print credentials. Common violations:
  - `gopass show <secret>`, `pass show`, `op read` (password managers)
  - `cat .env`, `cat credentials.sh`, `cat dump.pm2`, `cat */secrets.*`
  - `echo $SECRET_NAME`, `printenv SECRET_NAME`, `env | grep KEY`
  - `pm2 env <app>` (dumps all env vars unfiltered)
  - `docker inspect <container>` (includes env vars), `docker exec ... env`
  - `kubectl get secret -o yaml`, `kubectl exec ... env`
  - `systemctl show <service> --property=Environment`
  - Python/Node/Ruby one-liners parsing credential files (e.g., `python3 -c "import json; print(json.load(open('.env')))"`)
  - `heroku config`, `vercel env pull`, `fly secrets list` (with values)
  - `grep`/`rg` that may display secret values; allow only when patterns guarantee values are not printed
- When debugging env var issues, show key NAMES only, never values:
  - SAFE: `pm2 show <app> --json | jq -r '.[0].pm2_env | keys_unsorted[]'`
  - SAFE: `printenv | cut -d= -f1 | sort`
  - SAFE: `grep -oP '^[A-Z_]+(?==)' .env`
  - SAFE: `docker inspect <container> --format '{{range .Config.Env}}{{println .}}{{end}}' | cut -d= -f1`
  - UNSAFE: anything that prints the right side of `KEY=VALUE`
- For credential lookups, pre-stage the command for the user's terminal:
  - "Run this in your terminal (not here): `gopass show <path>`"
  - "Paste the value directly into the config file / environment, not into this conversation"
  - NEVER say "show me the output" or "paste the result here" for credential commands
- When a user pastes a credential value (API key, token, password, OAuth secret, connection string) into conversation:
  - Immediately warn: "That looks like a credential. Conversation transcripts are stored on disk — treat this value as compromised. Rotate it and store the new value via `aidevops secret set NAME` in your terminal."
  - Do NOT repeat, echo, or reference the pasted value in your response
  - Continue with a placeholder like `<YOUR_API_KEY>` instead

### Layered secret-read and egress controls (GH#22368)

Secret protection is deliberately layered so one missed path does not expose raw material:

1. **Pre-read deny:** OpenCode file-read tools are blocked by `quality-hooks-secret-read.mjs`; Claude Code `Read|Glob|NotebookRead` calls are blocked by `secret_file_read_guard.py`. Obvious secret paths include private SSH key names, `.pem`, `.key`, `.env`, credentials files, cloud/kube credential stores, and password-manager exports. Public key files ending `.pub` remain allowed.
2. **Command guard:** `sandbox-exec-helper.sh` blocks shell reads of the same high-risk paths unless the caller explicitly uses the audited local bypass for a user-approved operation.
3. **Transcript scrub:** `credential-transcript-scrub.py` redacts known token prefixes and PEM/private-key blocks if upstream prevention misses a result.
4. **GitHub egress guard:** the `gh` PATH shim scans issue/PR/comment body text and body files before writes to public repositories, blocking private-key material and credential-token patterns.
5. **Pre-push guard:** `privacy-guard-pre-push.sh` blocks public pushes that introduce synthetic or real private-key material. Tests must use synthetic fixtures only; never read or commit real credential files.

---

## 8.3 Secret as Command Argument Exposure (t4939)

**Threat:** A secret passed as a command argument can appear in error messages, `ps` output, and logs — even when the command's intent is safe.

**Incident:** qs-agency migration — WEBHOOK_SECRET interpolated into `wp db query` SQL argument; WP-CLI printed the full argument on parse failure. Required immediate rotation.

- ALWAYS pass secrets as environment variables, NEVER as command arguments:
  - UNSAFE: `SECRET=$(gopass show -o name) cmd "INSERT INTO t VALUES ('$SECRET')"` — `cmd` failure may print the argument
  - UNSAFE: `curl -H "Authorization: Bearer $TOKEN" ...` — `ps` shows full command line; error output may echo headers
  - UNSAFE: `mysql -p"$PASSWORD" dbname` — password visible in process list
  - SAFE: `SECRET=$(gopass show -o name) MY_SECRET="$SECRET" cmd` — subprocess reads via `getenv("MY_SECRET")`; error handlers never print env vars
  - SAFE: `aidevops secret NAME -- cmd` — injects as env var with automatic output redaction
  - SAFE: `SSH_AUTH_SOCK=... ssh ...` — env-based auth, no secret in argv
  - Subprocess must read value from environment (`getenv()` in C/PHP, `process.env` in Node, `os.environ` in Python, `ENV[]` in Ruby), not from `$1`/`argv`.
  - Last resort (program only accepts args): write secret to `mktemp` file (`chmod 0600`), pass the path, clean up via `trap EXIT`.
  - SSH/remote: `ssh host "ENV_VAR='value' command"` or `ssh -o SendEnv=VAR` with server-side `AcceptEnv`.

### Post-Execution Secret Detection (t4939, layer 2)

After any Bash command referencing a credential variable (`gopass`, `$*_SECRET`, `$*_TOKEN`, `$*_KEY`, `$*_PASSWORD`), verify the output doesn't contain the secret before presenting it.

- If the command failed (non-zero exit) and the secret was passed as an argument (violating 8.3), assume the output is contaminated — do not present it. Flag for immediate credential rotation.
- Judgment call, not a regex check. Assess whether output contains credential material (long base64 strings, API key patterns, JSON with auth fields).

---

## 8.4 Application Config Contains Embedded Credentials (t4954)

**Threat:** Application config tables store authenticated callback URLs with secrets as query parameters (e.g., `?secret=<value>`). A `SELECT *` returns embedded credentials — even without referencing any credential variable. Sections 8.3 and post-execution detection don't catch this.

**Incident:** FluentForms webhook config queried via `wp db query`; output contained `request_url` with `?secret=<value>`. Required immediate rotation.

- When querying application config, NEVER fetch raw record values with `SELECT *` or unfiltered column reads. Query schema/keys first, then extract only non-credential fields:
  - UNSAFE: `wp db query "SELECT value FROM wp_fluentform_form_meta WHERE meta_key='fluentform_webhook_feed'"` — returns full JSON including `request_url` with embedded `?secret=<value>`
  - UNSAFE: `SELECT * FROM wp_options WHERE option_name LIKE '%webhook%'` — option values often contain authenticated URLs
  - UNSAFE: `wp option get <integration_config>` — raw JSON dump may contain OAuth tokens, API keys, or signed URLs
  - SAFE: `wp db query "SELECT meta_key FROM wp_fluentform_form_meta WHERE form_id=1"` — schema/key discovery only
  - SAFE: `wp eval 'echo json_encode(array_keys(json_decode(get_option("webhook_config"), true)));'` — key names only
  - SAFE: `wp db query "SELECT name, status, form_id FROM wp_fluentform_form_meta WHERE ..."` — specific non-secret columns
  - SAFE: pipe raw output through `jq 'del(.request_url, .secret, .token, .api_key)'` to strip credential fields before display
- URLs in config records frequently contain embedded secrets (`?secret=`, `?token=`, `?key=`, `?api_key=`, `?password=`). Treat any URL field in application config as potentially containing credentials.
- Applies broadly: WordPress options/meta, Stripe webhook endpoints, Zapier/Make.com integration configs, OAuth redirect URIs with state tokens, any SaaS callback URL stored in a database.
- When investigating webhook or integration issues, describe the config structure (field names, record count, status) without exposing field values. If a specific URL is needed for debugging, ask the user to check it in their admin UI.

---

## 8.5 Private Repository and Local Path References (t3468)

**Threat:** Public code, issues, PR bodies, comments, or reviews can leak private repository names, bare private repo basenames, or local filesystem paths even when no credential value is present.

- Use placeholders in public surfaces: `<webapp>`, `[private-repo]`, `[local-path]`, "a managed private repo", or "cross-repo project".
- Deterministic guard locations:
  - `.agents/scripts/privacy-guard-helper.sh` centralizes detection for full private slugs, bare private basenames, built-in local path patterns, and configured private path patterns.
  - `.agents/scripts/gh` scans public-target issue/PR create/edit/comment/review bodies and supported `gh api` REST write fields before they reach GitHub.
  - `.agents/hooks/privacy-guard-pre-push.sh` scans public-repo pushes across the configured diff surface; aidevops defaults to full-repo scanning.
- Extra private slugs: `~/.aidevops/configs/privacy-guard-extra-slugs.txt` (one slug per line).
- Extra local/private path regexes: `~/.aidevops/configs/privacy-guard-private-path-patterns.txt` (one POSIX ERE per line). Matches are reported as `[configured-private-path]` so the raw path is not repeated.
- Private target repos fail open/allowed: internal work should not be blocked just because it references its own private name.
- Bypasses are explicit and auditable: `AIDEVOPS_GH_PRIVACY_BYPASS=1` for gh writes; `PRIVACY_GUARD_DISABLE=1` or `git push --no-verify` for pre-push.
