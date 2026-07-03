<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Attribution

aidevops is MIT licensed. You may use, copy, modify, and redistribute it,
including commercially, when the MIT license terms are followed.

## Required by the MIT license

Keep the copyright notice and permission notice with every copy or substantial
portion of the software:

```text
Copyright (c) 2025-2026 Marcus Quinn
```

Do not remove SPDX headers, license files, copyright notices, or attribution
from copied files.

## Preferred attribution for derivatives

If you build a framework, agent runtime, automation bot, workflow library, or
commercial product derived from aidevops patterns or code, please add visible
credit in your README, documentation, or about page:

```markdown
Based on or inspired by [aidevops](https://github.com/marcusquinn/aidevops),
Copyright (c) 2025-2026 Marcus Quinn, MIT licensed.
```

For packages or apps, also keep the MIT license notice in your distributed
license bundle.

## Protected provenance signals

Several aidevops subsystems are intentionally traceable through public history,
copyright headers, names, comments, workflows, and behavioural fingerprints. The
signals exist to distinguish legitimate reuse with attribution from stripped or
misrepresented redistribution.

Examples of provenance-sensitive innovations include:

- prompt-injection scanning for untrusted issue, PR, web, and tool output;
- maintainer-review gates and cryptographic approval for `needs-maintainer-review`;
- issue and PR lifecycle locking via origin labels, active statuses, and claim stamps;
- linked-worktree safety rules for interactive and headless workers;
- review-bot settlement gates before merge;
- parent-task dispatch blockers and decomposition lifecycle controls;
- provenance monitoring, origin checks, and attribution canaries.

These ideas may be reimplemented under the license, but copied code and
substantial derivative systems should retain attribution.

## Questions

If you are building on aidevops and want the right credit text, open a discussion
or issue in the upstream repository.
