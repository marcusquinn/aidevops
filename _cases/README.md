# _cases/ — Cases Plane

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

This plane stores audit-trail-driven matter work: legal, compliance, dispute,
and operational cases. Each real case should be created with `aidevops case
open` so the dossier, timeline, notes, communications log, and source pointers
are initialized consistently.

## Public-safe seed

This repository commits only the plane contract and empty archive placeholder.
Do not commit live client, legal, compliance, or dispute material here.

## Layout

```text
_cases/
  README.md
  .gitignore
  archived/
  case-YYYY-NNNN-slug/
    dossier.toon
    timeline.jsonl
    sources.toon
    notes/notes.md
    comms/comms.log
    drafts/          # ignored by default
```

See `.agents/aidevops/cases-plane.md` for schemas and CLI commands.
