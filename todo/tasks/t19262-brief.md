## What

Add `safety.actions_event_policy_auto_apply` to `.agents/configs/aidevops-config.schema.json` so the shipped defaults validate against the shipped schema again.

## Why

PR #37860 (`30a6a92905`, opt-in event policy routine) added `"actions_event_policy_auto_apply": false` to the `safety` block of `.agents/configs/aidevops.defaults.jsonc:261`. It is read by `.agents/scripts/actions-event-policy-routine.sh:16` (`config_get safety.actions_event_policy_auto_apply false`). The schema's `safety` object (`aidevops-config.schema.json:325-353`) has `additionalProperties: false` and no entry for this key.

Effects:

- `test-config-schema-defaults.sh` (GH#27401 regression) fails: `defaults /safety: must NOT have additional properties`. This was hidden because the scheduled Shell Suite Main Health runner could not load `ajv/dist/2020`; PR #39724 (GH#39718) installs ajv there, so the suite will go red on main once that merges.
- `config-helper.sh validate` validates the merged config (defaults + user) against the schema when `ajv-cli` or Python `jsonschema` is installed (`config-helper.sh:1044-1084`). Every such install therefore reports `Config fails JSON Schema validation`, whatever the user config contains.
- Editors using the `$schema` pointer flag the key in any user config that sets it. GitHub blocks `pull_request_target` by default from 2026-12-02, so users are about to opt in.
- `config set` has no schema type for the key (`_cmd_set_schema_type`, `config-helper.sh:719-726`).

### Files Scope

- `.agents/configs/aidevops-config.schema.json`

## How

- In the `safety.properties` object, add `actions_event_policy_auto_apply`: `"type": "boolean"`, `"default": false`, and a description matching the defaults comment ("GitHub blocks pull_request_target by default from 2026-12-02. True allows Pulse to mutate public repository Actions event policies."). Place it after `verification_tier`, which mirrors the defaults file order.
- Do not relax `additionalProperties: false`.

## Acceptance

- `test-config-schema-defaults.sh` passes with ajv resolvable, e.g. `NODE_PATH=<prefix>/node_modules` after `npm install --prefix <prefix> --ignore-scripts ajv@<package.json version>`, run from a cwd without `node_modules`.
- `jq` parses the schema, and `jq -r '.properties.safety.properties.actions_event_policy_auto_apply.type'` prints `boolean`.
- No other defaults/schema key drift remains: the suite reports no further errors.
