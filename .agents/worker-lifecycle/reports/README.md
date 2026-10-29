# Validation reports

Retain exactly four reports: the latest result for each validator/OS pair.

| Validator | Linux | macOS |
|-----------|-------|-------|
| Process | `validation-process-linux.json` | `validation-process-macos.json` |
| Registry | `validation-registry-linux.json` | `validation-registry-macos.json` |

Dates, architecture, OS and Python versions belong in the JSON, not filenames.
Preserve report contents, including failures and fingerprints. Never change a
reported hash to make an existing result describe a different artifact.

Process reports use schema `worker-lifecycle.validation/v1` and `code_sha256`
for the tested process sources. Registry reports use schema `1`, suite
`registry-integration` and `bundle_sha256` for the complete zipapp. Report schema
and database schema are independent formats.

Validators refuse to overwrite files. Collect a rerun at a new path, inspect its
result and fingerprint, then replace the corresponding retained report. Remove
superseded copies and update [compatibility documentation](../COMPATIBILITY.md).

A report describes its own build and environment only. It does not establish
cleanup authority, descendant quiescence or real AI-worker/sandbox integration.
Review metadata before publication; reports must not contain identity tokens,
process IDs, user IDs or private paths.
