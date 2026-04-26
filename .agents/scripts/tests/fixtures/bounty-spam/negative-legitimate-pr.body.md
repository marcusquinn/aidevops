## Summary

Adds **peer-productivity-monitor** (t2932) — a launchd/systemd-scheduled
job that observes peer GitHub activity and updates
`~/.config/aidevops/dispatch-override.conf` automatically.

## Why

Today, broken peer runners poison cross-runner dispatch coordination
for the full 1800s claim TTL. The current mitigation is manual editing.

## How

- **NEW:** `.agents/scripts/peer-productivity-monitor.sh` — core script.
- **NEW:** `tests/test-peer-productivity-monitor.sh` — 38 unit tests.
- **EDIT:** `setup-modules/schedulers.sh` — adds installer.

## Acceptance

- [ ] All 38 tests pass
- [ ] launchd plist installs cleanly on macOS
- [ ] systemd timer installs cleanly on Linux

Resolves #21127
