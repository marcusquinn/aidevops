---
description: Exact-service GET-only Render metadata readiness
mode: subagent
---

# Render service metadata readiness

Use the registered `render-service-readiness` capability (alias `render`), owned
by Build+, in `opencode` or `claude-code`:

```bash
python3 .agents/scripts/capability-readiness-helper.py route render --runtime opencode --target srv-example123 --operation read
```

The target must be an explicit service ID matching `srv-[a-z0-9]+`, not a
project name, logical target, URL, account, or service list. Provision the token
outside the helper and inject it only through `RENDER_API_KEY`. The helper never
searches credential stores, invokes subprocesses to obtain credentials, stores
tokens, or prints provider responses, headers, config values, or exceptions.

## Contract and limits

- Only `GET https://api.render.com/v1/services/{target}` is permitted. No endpoint
  override, proxy from environment, redirects, retries, listing, or mutations.
- Scope validation rejects fixtures (including empty fixtures), missing/invalid
  targets, unsupported assistant runtimes, and write/admin operations before
  reading credentials or starting network access. Fixtures cannot establish or
  replace Render live authority, including in catalogue queries.
- Requests use a 10-second socket timeout and read at most 262145 bytes to enforce
  a 262144-byte response limit. Failures return finite reason codes only.
- HTTP 200 alone is insufficient: UTF-8 JSON must be an object without duplicate
  keys or nonstandard numeric constants, with an `id` equal to the selected ID
  and an object `serviceDetails`. Its `runtime` must be a nonempty lowercase
  identifier (maximum 64 characters); its `url` must be HTTPS with a hostname,
  no credentials/query/fragment/whitespace, and no nonstandard port. This URL is
  validated as metadata only and is **never contacted**.
- If `envSpecificDetails` is present, it must be an object, and known build,
  start, and Docker command/path fields must be strings. No config is executed
  or emitted. Additional metadata fields do not expand the readiness scope.
- Success binds evidence to the selected service and `read` operation. It proves
  access to that service's minimum metadata schema, **not** app health, deployment
  readiness, restoration authority, ownership, or lease permission. Other service
  types without this minimum metadata fail closed.

Route exit statuses: `0` for verified metadata access, `3` for fallback (missing
token, provider denial, transport or schema failure), and `2` for invalid scope.
No live read is implied by documentation or offline tests; an operator must
authorize the exact service read separately.
