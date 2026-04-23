# Plist Environment Variable Overrides

Inject persistent environment variables into generated launchd plists without
losing them on every `aidevops update` or `setup.sh` run.

## Problem This Solves

`setup.sh` regenerates launchd plists on every run (~every 10 min via
`aidevops update`). Any manual edits to
`~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist`
are silently wiped.

The override file survives framework updates because it lives outside the
deployed agent scripts tree and is gitignored.

## Setup

```bash
# 1. Copy the committed template to the working file
cp ~/.aidevops/agents/configs/plist-env-overrides.json.txt \
   ~/.aidevops/agents/configs/plist-env-overrides.json

# 2. Edit the working file — add the env vars you want
#    Keys prefixed with _ are ignored (template examples)
nano ~/.aidevops/agents/configs/plist-env-overrides.json

# 3. Run setup.sh to regenerate the plist with your overrides
~/.aidevops/agents/../setup.sh --non-interactive
# or: aidevops update
```

## File Format

The override file is a JSON object keyed by **launchd plist label**. Each
value is an object of `{ "ENV_VAR_NAME": "value" }` pairs. All values must be
strings.

Keys prefixed with `_` are skipped — they serve as in-file comments.

```json
{
  "com.aidevops.aidevops-supervisor-pulse": {
    "SCANNER_NUDGE_AGE_HOURS": "0",
    "AUTO_DECOMPOSER_INTERVAL": "86400"
  }
}
```

## Supported Labels

Currently only the supervisor pulse label is handled:

| Label | Plist |
|-------|-------|
| `com.aidevops.aidevops-supervisor-pulse` | `~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist` |

Additional labels can be supported by extending
`_build_plist_env_overrides_xml` in `setup-modules/schedulers.sh`.

## Worked Example: Tune Per-Runner Thresholds

Runner A (aggressive nudging, wants decomposer every 24h):
```json
{
  "com.aidevops.aidevops-supervisor-pulse": {
    "SCANNER_NUDGE_AGE_HOURS": "0",
    "AUTO_DECOMPOSER_INTERVAL": "86400"
  }
}
```

Runner B (conservative, disable worker-briefed auto-merge for soak):
```json
{
  "com.aidevops.aidevops-supervisor-pulse": {
    "AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE": "0"
  }
}
```

After `aidevops update`, verify the plist was updated:

```bash
grep -A1 "SCANNER_NUDGE_AGE_HOURS\|AUTO_DECOMPOSER_INTERVAL" \
  ~/Library/LaunchAgents/com.aidevops.aidevops-supervisor-pulse.plist
```

## Precedence and Conflict

Injected vars are appended to the plist `EnvironmentVariables` dict. If you
inject a key that already exists in the dict (e.g. `PATH`, `HOME`), the
**later definition wins** under launchd's dict parsing rules. Overriding
`PATH`, `HOME`, `OPENCODE_BIN`, or `PULSE_DIR` is not recommended — use the
override file for aidevops-specific tuning variables only.

## Error Handling

| Condition | Behaviour |
|-----------|-----------|
| File absent | Silent no-op. Default plist generated. |
| File present, valid JSON, label not found | No-op for that plist. |
| File present, malformed JSON | `WARN` logged; plist generated without overrides. |
| `jq` not installed | `WARN` logged; plist generated without overrides. |

## Template Location

The committed template (with example keys, all `_`-prefixed) lives at:
`.agents/configs/plist-env-overrides.json.txt`

The working file (gitignored) lives at:
`.agents/configs/plist-env-overrides.json`
(deployed to `~/.aidevops/agents/configs/plist-env-overrides.json`)
