# Native compatibility evidence

Keep one latest report for each validator and operating system. Each report
qualifies only its recorded source or bundle fingerprint and environment, not
every build of that OS or a subsequently rebuilt validator.

| Validator | Linux | macOS |
|-----------|-------|-------|
| Process | [Linux report](reports/validation-process-linux.json) | [macOS report](reports/validation-process-macos.json) |
| Registry | [Linux report](reports/validation-registry-linux.json) | [macOS report](reports/validation-registry-macos.json) |

The tested hosts are Linux 6.18.55 x86-64 with Python 3.13.15, and Darwin 21.6.0
x86-64 with Python 3.14.6. Read each report for its timestamp, exact fingerprint,
checks and limitations. Different fingerprints are not proof of the same build.
The Linux and macOS registry reports validate the same current artifact: 35 tests
pass on each host, including
concurrent first-launch initialization, preservation of unknown existing state,
atomic attempt rollback, owned-process crashes and unchanged-observation rotation.
The retained macOS process report covers an earlier artifact and does not
validate the current process artifact.

## Process validation

`worker-lifecycle-process-validate.pyz` exercises process identity, readiness,
serialization, live child observation, a fresh observer and natural termination.
Include zombie observation when collecting the retained report:

```bash
python3 -I -B worker-lifecycle-process-validate.pyz --check zombie-state --output validation-process-linux.json
```

On macOS use `validation-process-macos.json` as the output filename. To list
available checks without inspecting processes:

```bash
python3 -I -B worker-lifecycle-process-validate.pyz --list-checks
```

Exit 0 means the selected checks passed. Exit 2 means validation or report
creation failed. The probe inspects itself and its owned child, not existing
workers; it never reboots the host. Compare `code_sha256`, which fingerprints
the process sources rather than the zipapp bytes.

## Registry validation

`worker-lifecycle-registry-validate.pyz` exercises SQLite transactions, replay,
capacity, concurrent writers, owned-process crashes, reconciliation and pre-exec
observation. It also checks isolated Python startup with an invalid Python
environment. See [REGISTRY-VALIDATION.md](REGISTRY-VALIDATION.md).

Compare `bundle_sha256`, which identifies the entire tested artifact. Exit 0
means all included tests passed without skips; exit 1 indicates failed tests;
exit 2 indicates unavailable validation or an output error.

## Limits and adding environments

Run as an unprivileged user without weakening host security. Return the JSON
even on failure. Review its environment metadata, preserve its contents, and
replace only the corresponding suite/OS report after verifying its fingerprint.
Validators require a new output path; collect a rerun separately before replacing
the retained report. See [reports/README.md](reports/README.md).

These reports do not establish real PID reuse, timestamp uniqueness, reboot,
power-loss durability, disk-full handling, Apple Silicon compatibility, real
macOS AI-worker/sandbox integration or long-term reliability. The registry has
no cleanup authority. A terminated process does not prove descendant quiescence.
Native ABI details are in [NATIVE-ABI.md](NATIVE-ABI.md).
