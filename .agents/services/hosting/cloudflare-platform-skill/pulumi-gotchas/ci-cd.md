<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# CI/CD

Use [`pulumi/actions@v4`](https://github.com/pulumi/actions) (GitHub Actions) or `pulumi/pulumi:latest` image (GitLab CI). Set `PULUMI_ACCESS_TOKEN` and `CLOUDFLARE_API_TOKEN` as secrets. Run `pulumi up --yes` with `--stack prod`.
