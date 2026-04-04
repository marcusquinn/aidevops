<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `Missing required property 'accountId'` | Account ID not set | Add to stack config or pass explicitly |
| Binding name mismatch | Worker expects `MY_KV` but binding differs | Match binding names in Pulumi and worker code |
| `resource 'abc123' not found` | Resource missing in account/zone | Ensure resource exists in correct account/zone |
| API token permissions error | Token lacks required scopes | Verify token has Workers, KV, R2, D1 permissions |
