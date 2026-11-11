<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Superseded dependency edges

Repointing retains the original native blocker edge as history. To opt a
dependant out of automatic supersession repointing, add
`<!-- aidevops:no-supersession-repoint -->` to its issue body. This prevents
both the sweep and consolidation paths from adding a successor edge or rewriting
the body; remove the marker to restore automatic repointing.

The marker does not change readiness checks, which can still follow a closed
superseded blocker to its open successor. When deliberately decoupling an
issue, also delete any closed superseded native blocker edges that are no longer
dependencies. Remove those blockers from `blocked-by` declarations in the issue
body and labels as well. When no native edges or declared blockers remain, the
reconciler leaves `status:blocked` unchanged on issues without an upstream
release gate. Existing issues are not opted out automatically.
