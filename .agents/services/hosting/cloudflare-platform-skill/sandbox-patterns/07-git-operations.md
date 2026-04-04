<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Git Operations

Handler-body-only examples — all use the Worker boilerplate from `sandbox.md` Quick Start.

```typescript
await sandbox.exec('git clone https://github.com/user/repo.git /workspace/repo');
await sandbox.exec('git clone -b main --single-branch https://github.com/user/repo.git /workspace/repo'); // shallow
await sandbox.exec(`git clone https://${env.GITHUB_TOKEN}@github.com/user/private-repo.git`); // authenticated
await sandbox.exec('git pull', { cwd: '/workspace/repo' });
await sandbox.exec('git checkout -b feature', { cwd: '/workspace/repo' });
```
