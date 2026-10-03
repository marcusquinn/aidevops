<!-- aidevops:brief-schema=v2 -->

# t18579: fix(wordpress): resolve config-http/test-http Application Passwords from secret names, not argv or config

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `wordpress mcp helper application password secret` → 0 hits — no relevant lessons
- [x] Discovery pass: 1 commit (`17b9165508`, t18577) / 1 merged PR (#33179) / 0 open PRs touch target files in last 48h
- [x] File refs verified: 6 refs checked, all present at HEAD `e5692a461d`
- [x] Tier: `tier:standard` — behaviour decided below; worker must restructure two existing functions and reuse t18577 helpers
- [x] Seeded draft PR decision recorded: skipped — small change; the reference pattern already sits in the same file

## Origin

- **Created:** 2026-09-30
- **Session:** opencode:interactive (t18577 follow-up)
- **Created by:** ai-interactive
- **Conversation context:** t18577 (GH#33175, PR #33179) added `serve-http`, `rankmath-config` and `rankmath-check`, which resolve the WordPress Application Password from a secret name at launch. The older generic `config-http` and `test-http` commands still take the literal password. The user asked to file this follow-up.

## What

`wordpress-mcp-helper.sh config-http` and `test-http` take a **secret name** instead of a literal Application Password, matching the t18577 commands:

- `config-http <site> <url> <user> <secret-name>` prints `mcpServers` JSON. The JSON launches `wordpress-mcp-helper.sh serve-http <url> <user> <secret-name>`, and no `WP_API_PASSWORD` value is written.
- `test-http <url> <user> <secret-name> [server]` resolves the secret with `resolve_secret_value` and passes credentials to curl through `-K -` on stdin, never `-u` on argv.
- Invalid or literal-looking third arguments (spaces, not `^[A-Za-z_][A-Za-z0-9_]*$`) are rejected by `validate_remote_args`. The error says to run `aidevops secret set <NAME>` and retry with the name.

## Why

- `generate_http_config` (`.agents/scripts/wordpress-mcp-helper.sh:172-199`) writes the literal password into `env.WP_API_PASSWORD` in generated MCP config. Users then paste that config into runtime files such as `opencode.json` and `~/.claude.json`.
- `test_http_connection` (`:288-317`) passes `-u "$username:$app_password"` on the curl argv, which any local user can see in the process list. The help text (`:578`, `:613`) teaches users to type the password on the command line, which puts it in shell history.
- The framework rule is to never expose or accept secrets in conversation or argv (`reference/secret-handling.md`). t18577 already shipped the safe pattern in the same file.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The behaviour and the reference pattern (`serve_http`, `generate_rankmath_config` json branch, `mcp_http_post`) are decided and live in the same file. The worker still has to restructure two function bodies and choose the exact output for the HTTP-status check, so there is no verbatim oldString/newString contract.

## PR Conventions

Leaf task: the PR uses `Resolves` with this task's issue number.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/wordpress-mcp-helper.sh:172-199` — `generate_http_config`: replace the heredoc with the `jq` output used by the `generate_rankmath_config` `"json"` branch (`:462-465`). Server name is `wordpress-<site>`; command is `$HOME/.aidevops/agents/scripts/wordpress-mcp-helper.sh`; args are `["serve-http", url, user, secret-name, server]`. Validate the site name with the same regex as `generate_rankmath_config` (`:439-442`) and call `validate_remote_args`.
- `EDIT: .agents/scripts/wordpress-mcp-helper.sh:288-317` — `test_http_connection`: call `validate_remote_args`, then `resolve_secret_value`. Build the curl config line `user = "<user>:<password>"` the way `rankmath_check` builds its credentials (read `:508-530` for the exact quoting/escaping), and pipe it to `curl -sS -K - -o /dev/null -w '%{http_code}' "$endpoint"`. Keep the existing 200/401 → reachable semantics.
- `EDIT: .agents/scripts/wordpress-mcp-helper.sh:578,582,613` — help text: `<pass>` → `<secret-name>`. Replace the literal-password example with `aidevops secret set WP_EXAMPLE_APP_PASSWORD` followed by `test-http https://example.com admin WP_EXAMPLE_APP_PASSWORD`.
- `EDIT: .agents/scripts/wordpress-mcp-helper.sh:691-692` — dispatch: pass `"${arg4:-mcp-adapter-default-server}"` as the server argument (today `arg4` is the password).
- `EDIT: .agents/scripts/wordpress-mcp-helper.sh:660` — add `config-http`, `http-config` and `test-http` to the no-sites-config case list, because they no longer need `load_config`.
- `EDIT: configs/mcp-templates/wordpress-mcp-adapter.json:17-30` — change the `wordpress-remote-http` example to the `serve-http` launcher with a `YOUR_SECRET_NAME` placeholder and no `WP_API_PASSWORD`.
- `EDIT: .agents/tools/wordpress/wp-dev.md:52` — point to `config-http <site> <url> <user> <secret-name>` as the way to generate config.

### Complete Write Surface

- **Callers/readers:** `git grep -n -E 'config-http|test-http|http-config|generate_http_config|test_http_connection'` matches only `.agents/scripts/wordpress-mcp-helper.sh`. No other script calls these commands. Docs that mention the HTTP transport: `.agents/tools/wordpress/wp-dev.md:52` and `.agents/tools/wordpress/rankmath-mcp.md` (already uses `serve-http`; no change).
- **Writers/mutation paths:** `generate_http_config` in `.agents/scripts/wordpress-mcp-helper.sh` writes only to stdout (heredoc `cat << EOF` at `:179`). `git grep -n -E 'wordpress-mcp-helper\.sh (config-http|http-config)'` finds no script that redirects that output into `opencode.json`, `~/.claude.json` or `~/.config/aidevops/`. Users paste it by hand, so no code writes runtime config. `test_http_connection` writes nothing; it prints one status line.
- **Existing verification/tests:** `git ls-files '.agents/scripts/tests/*wordpress*'` returns nothing, so no existing tests cover this. Verify by running the commands (below) against a local mock endpoint, as t18577 did.
- **Schemas/config:** `configs/mcp-templates/wordpress-mcp-adapter.json` (example only; not parsed by code).
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts/` to `~/.aidevops/agents/scripts/`. The generated config references that deployed path, which is the same as the t18577 behaviour.
- **Migrations/backfills:** N/A, with evidence: the helper keeps no state file. `load_config` only reads `~/.config/aidevops/wordpress-sites-config.json`, and neither command reads or writes that file. Existing hand-pasted configs with an inlined `WP_API_PASSWORD` keep working, because `@automattic/mcp-wordpress-remote` still accepts that env var. The `.agents/tools/wordpress/wp-dev.md:52` line tells users to regenerate with `config-http ... <secret-name>` and to delete the old password from their runtime config.
- **Cleanup/rollback paths:** rollback is `git revert` of the implementing PR, which restores the positional-password `config-http`/`test-http` in `.agents/scripts/wordpress-mcp-helper.sh` and the old example in `configs/mcp-templates/wordpress-mcp-adapter.json`. The commands create no temp files; `test_http_connection` writes curl output to `/dev/null`, so there are no temp paths to clean up. Deployed copies under `~/.aidevops/agents/scripts/` refresh on the next `setup.sh --non-interactive`.

### Implementation Steps

1. Rewrite `generate_http_config` as above. Reuse `validate_remote_args` and the `jq -n --arg ... '{mcpServers: {($name): {command: $h, args: $a}}}'` shape from `generate_rankmath_config`.
2. Rewrite `test_http_connection` to resolve the secret and send credentials over `curl -K -` stdin. Follow `mcp_http_post` (`:476-493`) and the credential string built in `rankmath_check`.
3. Update dispatch (`:660`, `:676-677`, `:691-692`) and help text.
4. Update the JSON template and `wp-dev.md:52`.
5. Run `shellcheck`, then exercise the commands (Verification below).

### Hazards and Compatibility

- **Concurrency/atomicity:** N/A. These are single-shot CLI commands with no shared state, the same as today.
- **Migration/rollback:** a revert restores the positional-password behaviour. Nothing persisted depends on the new output.
- **Mixed-version/backward compatibility:** this is an intentional breaking change to argument 3, from password to secret name. WordPress Application Passwords contain spaces (`xxxx xxxx ...`), so `validate_remote_args` rejects them with a clear migration message; a password is never silently treated as a secret name. Configs generated by the old version keep working.
- **Idempotency/retry:** both commands are read-only and safe to rerun.
- **Partial failure/recovery:** a missing secret fails before any network call, with the `aidevops secret set` hint that `resolve_secret_value` already prints.

### Complexity Impact

- **Target functions:** `generate_http_config` (28 lines → about 25), `test_http_connection` (30 lines → about 35), `main` (64 lines → about 65). All stay well under the 100-line gate.
- **Action required:** None.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/wordpress-mcp-helper.sh
# config output has the launcher and no password field
WP_EXAMPLE_APP_PASSWORD=dummy bash .agents/scripts/wordpress-mcp-helper.sh config-http example https://example.com admin WP_EXAMPLE_APP_PASSWORD | jq -e '.mcpServers["wordpress-example"].args[0] == "serve-http" and ((tostring | test("dummy|WP_API_PASSWORD")) | not)'
# literal password rejected (non-zero exit)
! bash .agents/scripts/wordpress-mcp-helper.sh config-http example https://example.com admin "abcd efgh ijkl mnop"
# test-http: credentials never on argv; run against a local mock (e.g. python3 -m http.server) and check `ps` while it runs, or read the code path
rg -n -- '-u "\$username' .agents/scripts/wordpress-mcp-helper.sh && exit 1 || true
```

- **Surface mapping:** the shellcheck line covers all helper edits. The `jq` check covers `generate_http_config` and its no-secret acceptance criterion. The rejection check covers the mixed-version hazard. The `rg` check covers the `test_http_connection` argv removal.
- **Broad verification trigger:** Not required. The change is limited to one helper script, one example template and one doc line.

### Files Scope

- `.agents/scripts/wordpress-mcp-helper.sh`
- `configs/mcp-templates/wordpress-mcp-adapter.json`
- `.agents/tools/wordpress/wp-dev.md`
- `TODO.md`
- `todo/tasks/t18579-brief.md`

## Acceptance Criteria

- [ ] `config-http <site> <url> <user> <secret-name>` prints valid `mcpServers` JSON whose command runs `serve-http` with the secret name, and whose output contains no password value and no `WP_API_PASSWORD` key.

  ```yaml
  verify:
    method: bash
    run: "WP_T18579_PW=dummy bash .agents/scripts/wordpress-mcp-helper.sh config-http example https://example.com admin WP_T18579_PW | jq -e '(.mcpServers[\"wordpress-example\"].args[0] == \"serve-http\") and ((tostring | test(\"dummy|WP_API_PASSWORD\")) | not)'"
  ```

- [ ] `test-http <url> <user> <secret-name>` resolves the secret and reports HTTP 200/401 reachability. Credentials go to curl via `-K -` stdin, never `-u` on argv.

  ```yaml
  verify:
    method: codebase
    pattern: '-u "\$username:\$app_password"'
    path: ".agents/scripts/wordpress-mcp-helper.sh"
    expect: absent
  ```

- [ ] Regression guard: a literal Application Password passed as argument 3 (for example `"abcd efgh ijkl mnop"`) is rejected with a non-zero exit and an `aidevops secret set` hint. It is never echoed and never written to output.

  ```yaml
  verify:
    method: bash
    run: "! bash .agents/scripts/wordpress-mcp-helper.sh config-http example https://example.com admin 'abcd efgh ijkl mnop' 2>&1 | grep -q 'abcd efgh'"
  ```

- [ ] `shellcheck .agents/scripts/wordpress-mcp-helper.sh` is clean, and `help` shows `<secret-name>` for both commands.

## Context & Decisions

- Keep the transport as `@automattic/mcp-wordpress-remote` through `serve-http`, which is already verified end to end in t18577 (including preserving MCP stdin during secret resolution).
- Don't add a deprecated `--password` escape hatch. Accepting secrets on argv is the defect being removed.
- `config-stdio` and `config-ssh` carry no secrets, so they are out of scope.

## Relevant Files

- `.agents/scripts/wordpress-mcp-helper.sh:367-428` — `validate_remote_args`, `resolve_secret_value`, `serve_http` (reuse)
- `.agents/scripts/wordpress-mcp-helper.sh:432-472` — `generate_rankmath_config` (JSON output pattern)
- `.agents/scripts/wordpress-mcp-helper.sh:476-530` — `mcp_http_post` and `rankmath_check` (curl `-K -` credential pattern)
- `.agents/tools/wordpress/rankmath-mcp.md` — user-facing description of the safe pattern

## Dependencies

- **Blocked by:** none (t18577 merged in #33179)
- **Blocks:** none
- **External:** none; the mock endpoint is local

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 10m | ~200 lines of the helper |
| Implementation | 30m | two functions, dispatch, help, template, one doc line |
| Verification | 15m | shellcheck plus command runs |
| **Total** | **~1h** | |
