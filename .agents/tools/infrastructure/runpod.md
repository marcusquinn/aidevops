---
description: Runpod GPU pods, network volumes and Serverless - runpodctl CLI first, official hosted MCP on demand with approval-gated billable writes
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: false
  grep: true
  webfetch: false
  task: false
  runpod_*: true
mcp:
  - runpod
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Runpod

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Use the CLI for scripts and renders**: `runpodctl` (GitHub `runpod/runpodctl`, GPL-3.0). JSON output by default, stable error `code`s, `--wait` until usable, resumable network-volume transfers.
- **Use the MCP for interactive inspection**: invoke `@runpod`; it connects the official hosted server `https://mcp.runpod.io/` (OAuth "Sign in with Runpod", no key on disk) on demand and disconnects afterwards. aidevops sends `X-Runpod-Analytics: off`.
- **MCP permissions**: catalog, pod, volume, template, endpoint, log, billing and docs reads are allowed. Pod, network-volume, template and Serverless writes ask for approval. Organization admin, cost centers, clusters, secrets, registry credentials, ECR delegations, SSH-key updates, `exec-pod` and `deploy-hub-repo` are not exposed.
- **Credentials**: store an account-named key (`aidevops secret set RUNPOD_<ACCOUNT>_API_KEY --provider runpod --account <ref>`), make it the default once with `aidevops secret default runpod RUNPOD_<ACCOUNT>_API_KEY`, then run the CLI as `aidevops secret RUNPOD_API_KEY -- runpodctl ...` so the key never lands in argv, history or chat. Switch accounts by changing the default. S3 transfer keys: `RUNPOD_S3_ACCESS_KEY` / `RUNPOD_S3_SECRET_KEY`.
- **Money rule**: any create, start, update, run or volume change bills. Follow the billable deployment contract in `tools/infrastructure/cloud-gpu.md`, report every resource ID and tear down when done.
- **Rendering playbook**: `tools/design/3d-render-backends.md`; Blender jobs on Runpod: `scripts/blender-render-helper.sh` (dry-run by default). Media models: `content/video-runpod.md`.

<!-- AI-CONTEXT-END -->

## Which interface

| Need | Use |
|------|-----|
| Repeatable render or batch job, CI, helper scripts | `runpodctl` |
| Upload scenes/assets, download frames (resume after drops) | `runpodctl network-volume upload/download` |
| "What is running and what is it costing?" in conversation | `@runpod` MCP (reads) or `runpodctl pod list` |
| One-off pod or endpoint change during a conversation | `@runpod` MCP with approval, or `runpodctl` |
| Organization, team, secret or registry administration | Runpod console (deliberately not exposed) |

## runpodctl

Install: `brew install runpod/runpodctl/runpodctl` (macOS) or the installer in
the upstream README; conda-forge and nix packages also exist. Pods ship with
`runpodctl` and a pod-scoped key. `runpodctl update --check` reports new
releases; set `RUNPOD_NO_UPDATE_CHECK=1` in CI.

```bash
# Verify setup (reads RUNPOD_API_KEY from the environment, never prompts)
aidevops secret RUNPOD_API_KEY -- runpodctl doctor

# Catalog and state (JSON by default; --output yaml also works)
aidevops secret RUNPOD_API_KEY -- runpodctl gpu list
aidevops secret RUNPOD_API_KEY -- runpodctl pod list
aidevops secret RUNPOD_API_KEY -- runpodctl pod get <pod-id>
aidevops secret RUNPOD_API_KEY -- runpodctl pod logs <pod-id> --tail 50

# Create and wait until SSH answers (bills from creation)
aidevops secret RUNPOD_API_KEY -- runpodctl pod create --name render-01 \
  --image <cuda-image> --gpu-id "NVIDIA GeForce RTX 4090" --wait --wait-timeout 10m

# Lifecycle
aidevops secret RUNPOD_API_KEY -- runpodctl pod stop <pod-id>    # disk kept, storage still bills
aidevops secret RUNPOD_API_KEY -- runpodctl pod delete <pod-id>  # terminate

# Network-volume files over the S3-compatible API (resumable; rerun to continue)
aidevops secret RUNPOD_S3_ACCESS_KEY RUNPOD_S3_SECRET_KEY -- \
  runpodctl network-volume upload <volume-id> ./scene scenes/shot-010
aidevops secret RUNPOD_S3_ACCESS_KEY RUNPOD_S3_SECRET_KEY -- \
  runpodctl network-volume download <volume-id> renders/shot-010 ./renders

# Serverless
aidevops secret RUNPOD_API_KEY -- runpodctl serverless run <endpoint-id> --input-file payload.json --wait 15m
aidevops secret RUNPOD_API_KEY -- runpodctl serverless status <endpoint-id> <job-id>
```

Check `runpodctl <noun> <verb> --help` for the installed version's flags
before relying on any flag above. `aidevops secret` redacts secret values from
command output.

### Errors and waits

- Errors are one JSON object on stderr; branch on `code`, never the message.
- `create_uncertain`, `wait_timeout` and `wait_interrupted` mean the resource
  **may exist and bill**: read the `id` field, check `pod list`, then delete or
  keep it deliberately. Never blindly retry a create.
- `timeout` from `serverless run --wait` means the CLI stopped waiting; poll
  `serverless status` instead of resubmitting.
- `transfer_incomplete`: rerun the same transfer command; finished files and
  multipart parts are reused. `volume_full`: grow the volume, then rerun.
- Pod readiness: wait for `runtimeStatus: running`; `desiredStatus: RUNNING`
  only means scheduled.
- Avoid the deprecated legacy forms (`config --apiKey`, `create pod`,
  `get pod`, `remove pod`, `start/stop pod`); they print plaintext errors
  without codes.

## MCP (`@runpod`)

Setup is automatic: aidevops registers the server disabled, and the `runpod`
agent connects it with `aidevops_mcp`. The first connection opens the Runpod
OAuth sign-in in the browser. The key is minted for the account or team profile
selected in the console at approval time; switch profile there first if you
belong to several teams.

If you already ran `npx @runpod/mcp-server add --client opencode`, that entry
stays yours (aidevops only keeps it disconnected until `@runpod` connects it);
add `X-Runpod-Analytics: off` under its `headers` if you want the opt-out.

Safe operation:

1. Call `get-account` and state the account or team before acting.
2. Prefer reads: `list-gpu-types`, `get-capacity`, `list-pods`, `get-pod`,
   `stream-pod-logs`, `list-network-volumes`, the billing lists and
   `search-docs`.
3. Before an approval-gated write, show the exact payload, GPU type and count,
   cloud type, storage, hourly price and stop condition.
4. Read back the result and record resource IDs; stop or delete what you
   created when the task ends unless the user says otherwise.
5. Serverless job output (`run-endpoint`, `stream-job`, `get-job-status`) is not
   size-capped; for large results set storage output in the job instead of
   streaming it into context.

`approvalRequiredTools` maps to OpenCode `ask`. `opencode --auto` launches
approve those silently, so the explicit approval in step 3 is still required.

## Related

- `tools/infrastructure/cloud-gpu.md` — provider comparison, billable deployment contract
- `tools/infrastructure/saladcloud.md` — interruptible consumer RTX alternative
- `tools/design/3d-render-backends.md` — Blender render routes and job contract
- `content/video-runpod.md` — Public Endpoints, Hub and Serverless media models
- Upstream: GitHub `runpod/runpodctl`, `runpod/runpod-mcp`; docs `https://docs.runpod.io/`
