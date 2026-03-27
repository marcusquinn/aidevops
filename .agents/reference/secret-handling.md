# Secret Handling — Detail Reference

Loaded on-demand when handling credentials, running commands that touch secrets,
or debugging authentication issues.
Core pointer is in `prompts/build.txt` "Security Rules".

---

## 8.1 Session Transcript Exposure (t1457)

**Threat:** Users assume "terminal command" means private, but commands run by AI tools
and their output are usually captured in session transcripts and may be sent to a remote
model provider in cloud-model mode.

- Treat command input + stdout/stderr as transcript-visible by default. If printing it would be a secret leak in chat, it is also a leak in tool output.
- When giving secret setup instructions, start with an explicit warning line: `WARNING: Never paste secret values into AI chat. Run the command in your terminal and enter the value at the hidden prompt.`
- Prefer secret-safe patterns that avoid printing values: key-name listings, masked previews, one-way fingerprints, and exit-code checks.
- Avoid workflows that write raw secrets to temporary files (for example `/tmp/*.json`) unless there is no alternative and cleanup is immediate; prefer in-memory piping when possible.
- If a command can expose secrets and no safe alternative exists, do not run it via AI tools. Instruct the user to run it locally and do not request pasted output.

---

## 8. Secret Value Leaking in Conversation (t2846)

**Threat:** Agent suggests or runs commands whose output contains secret values, exposing
credentials in the conversation transcript. Transcripts are stored on disk and may be
synced, logged, or visible to other tools. Once a secret appears in conversation, it must
be rotated — the damage is done.

**Root cause:** Agents pattern-match on "I need to check the value" and reach for the
obvious command (`gopass show`, `cat .env`, `pm2 env`) without considering that the output
enters the conversation context.

**Incident:** ILDS t006 session — Zoho OAuth credentials exposed, required rotation.

### Forbidden commands (non-exhaustive)

NEVER run, suggest, or output any command whose stdout/stderr would contain secret values.
This is a principle, not a blocklist — apply judgment to ANY command that could print
credentials. Common violations:

- `gopass show <secret>`, `pass show`, `op read` (password managers)
- `cat .env`, `cat credentials.sh`, `cat dump.pm2`, `cat */secrets.*`
- `echo $SECRET_NAME`, `printenv SECRET_NAME`, `env | grep KEY`
- `pm2 env <app>` (dumps all env vars including secrets unfiltered)
- `docker inspect <container>` (includes env vars), `docker exec ... env`
- `kubectl get secret -o yaml`, `kubectl exec ... env`
- `systemctl show <service> --property=Environment`
- Python/Node/Ruby one-liners that parse files containing credentials (e.g., `python3 -c "import json; print(json.load(open('.env')))"`)
- `heroku config`, `vercel env pull`, `fly secrets list` (with values)
- `grep`/`rg` that may display secret values; only allow when patterns guarantee values are not printed (see safe examples below)

### Safe alternatives — show key NAMES only, never values

```bash
# pm2 — key names only (robust)
pm2 show <app> --json | jq -r '.[0].pm2_env | keys_unsorted[]'

# env — names only
printenv | cut -d= -f1 | sort

# .env file — names only
grep -oP '^[A-Z_]+(?==)' .env

# docker — names only
docker inspect <container> --format '{{range .Config.Env}}{{println .}}{{end}}' | cut -d= -f1
```

UNSAFE: anything that prints the right side of `KEY=VALUE`.

### Credential lookup protocol

For credential lookups, pre-stage the command for the user's own terminal:

- "Run this in your terminal (not here): `gopass show <path>`"
- "Paste the value directly into the config file / environment, not into this conversation"
- NEVER say "show me the output" or "paste the result here" for credential commands

### When a user pastes a credential value

When a user pastes what appears to be a credential value (API key, token, password, OAuth
secret, connection string with embedded credentials) directly into conversation:

- Immediately warn: "That looks like a credential. Conversation transcripts are stored on disk — treat this value as compromised. Rotate it and store the new value via `aidevops secret set NAME` in your terminal."
- Do NOT repeat, echo, or reference the pasted credential value in your response
- Continue helping with the task using a placeholder like `<YOUR_API_KEY>` instead

---

## 8.2 Secret as Command Argument Exposure (t4939)

**Threat:** A secret passed as a command argument (not an env var) can be echoed back in
error messages, appear in `ps` output, and leak into logs — even when the command's
*intent* is safe (e.g., a DB insert). The agent assesses the command as safe because it's
not a `cat` or `echo`, but any program can print its argv on failure. Error paths are
invisible at invocation time.

**Incident:** qs-agency migration — WEBHOOK_SECRET interpolated into `wp db query` SQL
argument, WP-CLI printed the full argument on parse failure, secret entered conversation
transcript. Required immediate rotation.

### Rule

When a subprocess needs a secret value, ALWAYS pass it as an environment variable, NEVER
as a command argument. Command arguments appear in error messages, `ps` output, and logs.
Environment variables do not.

### Examples

```bash
# UNSAFE — if cmd fails, it may print the argument including the secret
SECRET=$(gopass show -o name) cmd "INSERT INTO t VALUES ('$SECRET')"

# UNSAFE — ps shows the full command line; error output may echo headers
curl -H "Authorization: Bearer $TOKEN" ...

# UNSAFE — password visible in process list
mysql -p"$PASSWORD" dbname

# SAFE — subprocess reads via getenv("MY_SECRET"); error handlers never print env vars
SECRET=$(gopass show -o name) MY_SECRET="$SECRET" cmd

# SAFE — injects as env var with automatic output redaction
aidevops secret NAME -- cmd

# SAFE — env-based auth, no secret in argv
SSH_AUTH_SOCK=... ssh ...
```

The subprocess must read the value from its environment (`getenv()` in C/PHP,
`process.env` in Node, `os.environ` in Python, `ENV[]` in Ruby), not from `$1`/`argv`.

### Last resort: temp file

When the target program only accepts secrets as arguments (no env var support), write the
secret to a temporary file, pass the file path as the argument, and ensure robust cleanup:

```bash
SECRET_FILE=$(mktemp)
chmod 0600 "$SECRET_FILE"
trap 'rm -f "$SECRET_FILE"' EXIT
gopass show -o name/secret > "$SECRET_FILE"
cmd --secret-file "$SECRET_FILE"
```

### SSH/remote commands

`ssh host "ENV_VAR='value' command"` passes the secret in the remote shell's environment,
not as an argument to `ssh` itself. Alternatively, use `ssh -o SendEnv=VAR` with
server-side `AcceptEnv` configuration.

---

## 8.3 Post-Execution Secret Detection (t4939, layer 2)

**Trigger:** After any Bash command whose input references a credential variable (`gopass`,
`$*_SECRET`, `$*_TOKEN`, `$*_KEY`, `$*_PASSWORD`), verify the output doesn't contain the
secret value before presenting it to the user.

- After running any command that references a credential variable, assess whether the output could contain the secret value. If the command failed (non-zero exit) and the secret was passed as an argument (violating 8.2), assume the output is contaminated — do not present it to the user. Flag for immediate credential rotation.
- This is a judgment call, not a regex check. The agent knows which variables contain secrets and can assess whether output looks like it contains credential material (long base64 strings, API key patterns, JSON with auth fields).

---

## 8.4 Application Config Contains Embedded Credentials (t4954)

**Threat:** Application configuration tables (webhook settings, integration records, OAuth
configs, API endpoint metadata) store authenticated callback URLs with secrets as query
parameters (e.g., `?secret=<value>`). A general `SELECT *` or `SELECT value` on these
tables returns the full record including embedded credentials — even though the command
itself doesn't reference any credential variable. Sections 8.2 and 8.3 don't catch this
because the secret isn't passed as an argument or referenced as a variable.

**Incident:** FluentForms webhook config queried via `wp db query`, output contained
`request_url` with `?secret=<value>`. Required immediate rotation.

### Rule

When querying application config (webhook settings, integration records, OAuth configs,
API endpoint metadata), NEVER fetch raw record values with `SELECT *` or unfiltered column
reads. Query schema/keys first, then extract only non-credential fields via targeted
selectors.

### Examples

```bash
# UNSAFE — returns full JSON including request_url with embedded ?secret=<value>
wp db query "SELECT value FROM wp_fluentform_form_meta WHERE meta_key='fluentform_webhook_feed'"

# UNSAFE — option values often contain authenticated URLs
SELECT * FROM wp_options WHERE option_name LIKE '%webhook%'

# UNSAFE — raw JSON dump may contain OAuth tokens, API keys, or signed URLs
wp option get <integration_config>

# SAFE — schema/key discovery only, no values
wp db query "SELECT meta_key FROM wp_fluentform_form_meta WHERE form_id=1"

# SAFE — key names only
wp eval 'echo json_encode(array_keys(json_decode(get_option("webhook_config"), true)));'

# SAFE — specific non-secret columns
wp db query "SELECT name, status, form_id FROM wp_fluentform_form_meta WHERE ..."

# SAFE — strip credential fields before display
<command> | jq 'del(.request_url, .secret, .token, .api_key)'
```

### URL fields in config records

URLs in config records frequently contain embedded secrets as query parameters
(`?secret=`, `?token=`, `?key=`, `?api_key=`, `?password=`). Treat any URL field in
application config as potentially containing credentials.

This applies broadly: WordPress options/meta, Stripe webhook endpoints, Zapier/Make.com
integration configs, OAuth redirect URIs with state tokens, any SaaS callback URL stored
in a database.

When investigating webhook or integration issues, describe the config structure (field
names, record count, status) without exposing field values. If a specific URL is needed
for debugging, ask the user to check it in their admin UI.
