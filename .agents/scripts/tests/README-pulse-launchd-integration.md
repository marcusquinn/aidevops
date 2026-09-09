# Pulse launchd integration check

`test-pulse-launchd-integration.sh` is an explicit real-launchd validation for
macOS. It does not run in ordinary test discovery: no arguments prints `SKIP`

## Run

```bash
bash .agents/scripts/tests/test-pulse-launchd-integration.sh
bash .agents/scripts/tests/test-pulse-launchd-integration.sh --help
bash .agents/scripts/tests/test-pulse-launchd-integration-guards.sh
```

On an authorized macOS host with the current user's accessible GUI launchd

```bash
bash .agents/scripts/tests/test-pulse-launchd-integration.sh --run
```

The fixture refuses non-macOS hosts, missing `launchctl`, and inaccessible GUI

## Bounded side effects and cleanup

The runner creates a private `mktemp` root and a fresh
`com.aidevops.test.pulse.*` label. It only disables, enables, bootouts, and
checks that exact label in the current user's `gui/UID` domain. It sources the
checkout's production installer and lifecycle functions, but uses an inert,
self-expiring wrapper (75 seconds maximum) and a fixture HOME. It never uses
sudo, the production Pulse label/wrapper, network access, credentials, or a
system launchd domain.

The test proves disabled-state repair, registration, managed-start PID evidence,
cleanup and verifies that the owned job, disabled state, and wrapper process
are gone. Cleanup failure changes the result to failure and preserves a private
`RECOVERY.txt` in the fixture root with the exact owned identity. Do not use
global `launchctl` resets or broad `pkill` commands. SIGKILL prevents trap
execution; the wrapper's hard lifetime is the containment fallback. A retry
always creates a new label and must not adopt a previous fixture.

The guard suite is deterministic and safe on Linux; it verifies the opt-in,
production-source, ownership, inherited-override, and cleanup contracts. Run
the real fixture only where the launchd prerequisite is genuinely available.
