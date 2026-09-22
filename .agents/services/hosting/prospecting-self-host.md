---
description: Local and self-hosted operation for the private prospecting service
---

# Self-host prospecting

The supported default is a private loopback service with persistent local storage.
It requires Python 3.12+ in the current framework checkout and no hosted database,
Clerk, AnyAPI, Lurk, cloud wallet, or model subscription.

## Local operation

```bash
python3 .agents/scripts/prospecting-service-helper.py --store "$HOME/.aidevops/prospecting" start --ui-dir .agents/templates/prospecting-workbench
python3 .agents/scripts/prospecting-service-helper.py --store "$HOME/.aidevops/prospecting" stop
```

The store directory and database are private. `stop` retains all volumes/data;
delete only after an explicit export and verified backup. `service-state.json`
prevents a second managed server. Restore only a validated private backup, then
use the existing import/export contract to confirm profiles and dispositions.

## Optional container

```bash
cp .agents/templates/prospecting-container/env.example .env.prospecting
docker compose --env-file .env.prospecting -f .agents/templates/prospecting-container/compose.yaml up -d
docker compose --env-file .env.prospecting -f .agents/templates/prospecting-container/compose.yaml down
```

The compose file uses Linux host networking so the service itself binds
`127.0.0.1` only; a one-shot initializer assigns the persistent volume to the
unprivileged service user. It retains `prospecting-data` on stop. On non-Linux
Docker hosts, use the direct local command rather than loosening the listener.
It runs without root and accepts no credentials from the image. Inject provider
secret *handles* through the operator's secure environment only after an explicit
capability/readiness and cost review. The default empty handle activates nothing.

## External access and recovery

External binding is intentionally refused unless the service receives
`--allow-external`, an exact public host, and TLS certificate/key paths. Complete
the TLS/auth/network/exposure review and public-launch workflow first; public
launch is separate authority. Configure an MCP client manually against a scoped
loopback endpoint after creating a per-project key; do not alter host MCP config.

For upgrades: stop the service, copy/export the private data, validate the backup,
start the new version, and run a synthetic restore check. A failed provider or
container check is recorded as unavailable coverage, never presented as parity.
