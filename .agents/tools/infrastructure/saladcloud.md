---
description: SaladCloud interruptible consumer GPUs - saladcloud CLI for container groups, job queues, logs and capacity, with aidevops secret auth and approval rules
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: false
  grep: true
  webfetch: true
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# SaladCloud

<!-- AI-CONTEXT-START -->

## Quick Reference

- **What**: per-second consumer RTX GPUs (3090/4090/5090 class) on interruptible nodes with ephemeral local disk. Cheapest route for resumable batch work such as frame-range renders; wrong for long stateful sessions.
- **CLI**: `saladcloud` (GitHub `SaladTechnologies/salad-cloud-cli`, MIT, **beta**, examples here target v0.2.0). Always run `saladcloud -o json <command>`; `<command> --help` is the reference for the installed version.
- **Credentials**: store an account-named key (`aidevops secret set SALAD_<ACCOUNT>_API_KEY --provider saladcloud --account <ref>`), declare it once with `aidevops secret default saladcloud SALAD_<ACCOUNT>_API_KEY`, then run `aidevops secret SALAD_API_KEY -- saladcloud ...`. Set `SALAD_ORGANIZATION`, `SALAD_PROJECT` (URL names) or pass `--org`/`--project`. Prefer this over `saladcloud login`, which stores the key in a plaintext config file.
- **No prompts**: export `SALAD_CLI_NO_PROMPT=1` for agent runs; a missing key then fails with a JSON hint instead of waiting.
- **Money rule**: a container group bills while it runs. `container-groups delete` is immediate with no confirmation and the name is never reusable. Follow the billable deployment contract in `tools/infrastructure/cloud-gpu.md`.
- **Rendering playbook**: `tools/design/3d-render-backends.md`.

<!-- AI-CONTEXT-END -->

## Install and verify

```bash
# macOS/Linux installer verifies release checksums; installs to ~/.local/bin
# Pin while in beta: SALAD_CLI_VERSION=v0.2.0 (see the overview page under Sources)
saladcloud version
saladcloud changelog --since 0.2.0   # offline: what changed since the docs you know

export SALAD_CLI_NO_PROMPT=1
aidevops secret SALAD_API_KEY -- saladcloud -o json whoami   # masked key, org, project and their sources
aidevops secret SALAD_API_KEY -- saladcloud -o json doctor
```

Alternatives: `go install github.com/saladtechnologies/salad-cloud-cli/cmd/saladcloud@latest`
(Go 1.26+), or download a release archive and check it with
`gh attestation verify <archive> --repo SaladTechnologies/salad-cloud-cli`.

Account creation, organizations, projects, billing, API keys, AI Gateway keys
and SSH public-key registration stay in the Portal. A new key authenticates
(`whoami` shows `"authenticated": true`) but `orgs list` stays empty until an
organization is created in the Portal; organizations need credits before
anything can start. The API cannot read back the registered SSH key.

## Common commands

Prefix every command with `aidevops secret SALAD_API_KEY --` (omitted below
for width):

```bash
saladcloud -o json gpus list --org <org>        # GPU classes with price per priority tier
saladcloud -o json quotas get --org <org>
saladcloud -o json container-groups list --org <org> --project <project>
saladcloud -o json container-groups get <group> --org <org> --project <project>   # status, counts, failure reason
saladcloud -o json container-groups logs <group> --org <org> --project <project> --since 5m

# Billable: ask first. Group names are never reusable, so make them unique.
saladcloud -o json container-groups create <unique-name> --org <org> --project <project> \
  --image <image> --cpu 4 --memory 16384 --priority batch --wait --timeout 15m -- <command...>

# Interrupting or destructive: ask first. delete is immediate.
saladcloud -o json container-groups stop <group> --org <org> --project <project>
saladcloud -o json container-groups delete <group> --org <org> --project <project>
```

Check each verb's `--help` for exact flags (GPU class selection, scaling,
queue options) before running. `availability` is read-only but expensive for
the platform: run it once before a deployment, never in a loop. `gpus` and
`inference` are organization-scoped and reject `--project`; `ai-gateway`
rejects both scope flags.

## Agent rules

- Branch on exit codes: `1` general, `2` usage, `3` auth, `4` not found,
  `5` rate limited, `6` invalid input, `7` network, `10` AI Gateway billing
  refusal. In JSON mode the last stderr line is `{"error":{...,"hint":...}}`; act
  on the `hint`.
- Auth failures (`3`): check `aidevops secret resolve saladcloud`; if no default
  is declared, ask the user to store or declare the key in their own terminal
  (see Credentials above). Never ask for a key in chat.
- Pass `--org`/`--project` on every command instead of `use` or `config set`.
  If a name is not found, ask; never pick one from a list.
- Read `warning:` and `note:` lines on stderr after every write; verify every
  write with a read.
- A timeout or interrupted `--wait` does not cancel accepted work: inspect the
  group or job ID before retrying. Never auto-repeat a job submission with an
  uncertain outcome.
- `container-groups update` restarts every instance when image, command, env,
  probes or gateway settings change.
- One-shot `container-groups ssh <group> -- <command>` exits `1` even on
  success (the relay drops exit codes); check the output instead.
- Logs, env vars, job input/output and transcripts can contain secrets: redact
  before quoting.

| Policy | Commands |
|--------|----------|
| Allow | `whoami`, `doctor`, `version`, `changelog`, `logs`, `container-groups logs`, `quotas get`, `list`/`get` of `orgs`, `gpus`, `container-groups`, `instances`, `queues`, `queues jobs`, `inference`, `inference jobs` |
| Ask: adds cost | `container-groups create`/`start`/scale up, `queues jobs create`, `inference jobs create`, `inference transcribe`, `inference transcription-lite`, `ai-gateway test` |
| Ask: interrupts or removes | `container-groups delete`/`stop`/scale down/`update`, `instances restart`/`recreate`/`reallocate`, `queues delete`, `queues jobs cancel`, `inference jobs cancel` |
| Ask: reaches into a container | `container-groups ssh`/`cp`/`sftp` |
| User only | `login`, `logout`, `use`, `config set`, `ai-gateway login`, `ssh-key setup`, `webhook-secret get`/`rotate` |

## Rendering on SaladCloud

Nodes are interruptible and local disk is ephemeral, so design for loss:

1. Bake the pinned Blender build and `enable_gpu.py` into the image
   (`tools/design/3d-render-backends.md`).
2. Keep scenes and frames in external object storage; each worker pulls its
   inputs and uploads every finished frame immediately.
3. Feed frame ranges through a job queue (`queues`, `queues jobs create`) so a
   reallocated node's range is retried, and make workers skip frames that
   already exist.
4. Use `batch` priority for price; check `gpus list` prices and `quotas get`
   before scaling.
5. Delete (or stop) the container group when the queue drains, then confirm
   with `container-groups list`.

## Sources

- CLI overview: `https://docs.salad.com/cli/explanation/overview`
- Agent guide: `https://docs.salad.com/cli/how-to-guides/use-with-ai-agents`
- Agent operations runbooks: `https://docs.salad.com/agents/overview`
- `saladcloud agent init` writes the vendor's agent section into a project
  `AGENTS.md`/`CLAUDE.md`; use it in project repos that deploy to SaladCloud.

## Related

- `tools/infrastructure/cloud-gpu.md` — provider comparison, billable deployment contract
- `tools/infrastructure/runpod.md` — Runpod CLI and MCP
- `tools/design/3d-render-backends.md` — Blender render routes and job contract
