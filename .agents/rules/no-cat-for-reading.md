---
id: no-cat-for-reading
ttsr_trigger: \bcat\b.*\.(md|sh|txt|json|yaml|yml|ts|js|py)|head -[0-9]|tail -[0-9]
severity: info
repeat_policy: once
tags: [efficiency, tools]
enabled: true
---

Use the Read tool instead of cat/head/tail for reading files. The Read tool:

- Supports line offsets and limits natively
- Preserves line numbers for accurate editing
- Is required before Edit/Write tools will work on a file
