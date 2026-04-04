<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Debugging

```bash
pulumi up --logtostderr -v=9   # verbose logging
pulumi preview                  # preview changes
pulumi stack export             # view resource state
pulumi stack --show-urns
pulumi state delete <urn>       # use with caution
```
