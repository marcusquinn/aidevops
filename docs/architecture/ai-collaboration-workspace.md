<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# AI collaboration workspace implementation map

## Status

Accepted implementation map for issue #25708.

## Current state

The aidevops.app shell already exists. It is a local-first Vite React workspace,
not a Next.js application or hosted app scaffold:

- `packages/gui-web/src/App.tsx` owns top-level UI state, appearance
  persistence, active surface history, the device/session shell switch, and the
  selected conversation context.
- `packages/gui-web/src/AppNavigation.tsx` owns the machine rail, left sidebar,
  DevOps/Comms navigation groups, and AI/People conversation sidebar.
- `packages/gui-web/src/AppWorkspace.tsx` owns the workspace header, command
  palette trigger, notification/profile menus, assistant toggle, chat surface,
  and surface rendering.
- `packages/gui-web/src/app-model.ts` owns route-like surface IDs, navigation
  labels, sidebar grouping, sidebar mode selection, inventory surface metadata,
  and text constants.
- `packages/gui-web/package.json` currently depends on React 19,
  `react-dom`, `react-icons`, local fonts, and `@aidevops/gui-shared`; it does
  not yet include shadcn-derived chat primitives, Tambo, React Joyride, or
  Turbostarter AI packages.

Existing GUI architecture documents live under `docs/gui/`. This cross-cutting
workspace map lives under `docs/architecture/` because it coordinates future UI,
data, navigation, onboarding, and release work across the GUI packages.

## Navigation framework

The current app uses typed surface IDs instead of file-system routes.
Subsequent implementation issues should extend that registry rather than add an
independent router first.

### Route and surface registry

- Add or rename route-like entries in `packages/gui-web/src/app-model.ts` by
  updating `surfaceIds`, `SurfaceId`, `navGroups`, `dashboardNavItem`,
  `fileRootBySurface`, `findSurface`, `findSurfaceSectionLabel`,
  `sidebarModeForSurface`, and text constants as needed.
- The active route is `activeSurface: SurfaceId`, derived from the navigation
  history in `packages/gui-web/src/App.tsx`.
- The current history API is local state: `setActiveSurface`, `goBack`, and
  `goForward` in `packages/gui-web/src/App.tsx`. Do not introduce URL routing
  until a later routing ADR decides browser history, desktop deep links, and
  hosted route compatibility.

### Shell and sidebar ownership

- `ShellMode` currently supports `devices` and `sessions` in
  `packages/gui-web/src/app-model.ts`.
- `packages/gui-web/src/App.tsx` passes `shellMode`, `conversationMode`,
  selected repo index, selected session ID, and setters into `Sidebar` and
  `Workspace`.
- `packages/gui-web/src/AppNavigation.tsx` renders the normal DevOps/Comms
  sidebar when `shellMode === "devices"` and the conversation sidebar when
  `shellMode === "sessions"`.
- `ConversationMode` currently supports `ai` and `people`, matching the desired
  split between AI Sessions and Channels/DMs.

### Workspace ownership

- `packages/gui-web/src/AppWorkspace.tsx` chooses between
  `ConversationWorkspace` and `SurfaceContent` based on `shellMode`.
- `ConversationWorkspace` currently renders read-only placeholder AI session
  and People chat bubbles. This is the first target for shadcn chat primitive
  adoption after the shared conversation model lands.
- `SurfaceContent` maps static and inventory surfaces. New non-chat surfaces
  should be registered there only after the corresponding `SurfaceId` and nav
  metadata exist in `app-model.ts`.

## Header, notifications, and signposts

The workspace header action cluster already has the target placement for tours:

- `packages/gui-web/src/AppWorkspace.tsx` imports `FiBell` and `FiHelpCircle`.
- The help icon button currently appears inside `.header-action-menu`
  immediately before the notifications button.
- Issue #25714 should convert that help/signposts button into the per-page tour
  toggle while preserving the requirement that it sits immediately left of the
  notifications icon button.
- The notifications menu is currently local component state in
  `WorkspaceHeader`; any signposts/tour open state should remain nearby unless
  a later onboarding state store is introduced.

Recommended target names for issue #25714:

- `signpostsOpen` state in `WorkspaceHeader`.
- `SignpostsTour` or `WorkspaceSignposts` component in
  `packages/gui-web/src/AppWorkspace.tsx` until it grows large enough for a
  separate `SignpostsTour.tsx` module.
- Keep the icon button before the notifications button in `.header-actions` and
  use `activeSurface` to choose page-specific tour steps.

## Chat primitive decision

Use a hybrid architecture:

1. **Turbostarter AI remains the app-level AI chat/session foundation.** It is
   the reference for persistence, AI SDK transport, model selection,
   attachments, tool/reasoning panels, sharing, history, and actions.
2. **shadcn chat primitives are UI-layer building blocks.** Adopt equivalent
   local components where they fit the existing Vite app:
   - `MessageScroller` for streaming scroll behavior in AI sessions and
     channel/DM threads.
   - `Message`/`Bubble` for AI, user, system, channel, and direct-message rows.
   - `Attachment` for file cards and future repo/context artifacts.
   - `Marker` for system, tool, workflow, and event rows.
3. **Tambo owns generative UI cards only.** Use it for rendered DevOps cards and
   interactive workflow components embedded in a conversation. Do not let Tambo
   own ordinary chat persistence, channel storage, DM transport, or the AI
   session adapter.

This keeps the current local-first Vite/Hono architecture, avoids adopting a
second persistence owner, and gives each child issue a clear boundary.

## Implementation map for child issues

### Issue #25709: unified conversations model

Primary targets:

- `docs/gui/data-model.md` for the durable conversation, participant,
  message, attachment, event, and card model.
- `packages/gui-shared/src/` for shared schema/types once the model is accepted.
- `packages/gui-api/src/` and `packages/gui-api/tests/` for read routes and
  fixtures when status/API projection work begins.
- `packages/gui-web/src/App.tsx` only for additional selected conversation state
  if `selectedSessionId` is no longer sufficient.

Recommended model names:

- `Conversation`, `ConversationParticipant`, `ConversationMessage`,
  `ConversationAttachment`, `ConversationEvent`, and `ConversationCard`.
- Conversation types: `ai_session`, `channel`, and `direct_message`.
- Message event kinds: `message`, `system`, `tool_call`, `workflow_event`, and
  `card`.

### Issue #25710: navigation destinations

Primary targets:

- `packages/gui-web/src/app-model.ts` for `SurfaceId` entries, nav labels, and
  side-bar grouping.
- `packages/gui-web/src/AppNavigation.tsx` for any sidebar rendering change
  that cannot be expressed through `navGroups`.
- `packages/gui-web/src/AppWorkspace.tsx` for `SurfaceContent` placeholders or
  dedicated surface components.
- `packages/gui-web/tests/component.test.ts` for navigation regression coverage.

Recommended destinations:

- Keep `shellMode === "sessions"` for the AI/People conversation workspace.
- Add explicit discoverable surfaces only where they help users navigate from
  the device shell: `aiSessions`, `channels`, and `directMessages` are preferred
  labels if the sidebar needs route-like entries outside the existing session
  shell tabs.

### Issue #25711: AI Sessions UI

Primary targets:

- `packages/gui-web/src/AppWorkspace.tsx`, replacing the placeholder AI branch
  inside `ConversationWorkspace` with composable thread primitives.
- `packages/gui-web/src/AppNavigation.tsx`, extending `ConversationSidebar` to
  show AI session grouping, create/continue controls, and repo/session filters.
- `packages/gui-web/src/status-client.ts` and `packages/gui-shared/src/` only
  when the API exposes session/message payloads beyond current metadata.

Use Turbostarter AI patterns for the adapter and session lifecycle, then render
with local shadcn-style primitives.

### Issue #25712: Channels and DMs

Primary targets:

- `packages/gui-web/src/AppNavigation.tsx`, extending `PeopleChannelList` into
  channel and direct-message lists.
- `packages/gui-web/src/AppWorkspace.tsx`, extending the People branch of
  `ConversationWorkspace`.
- `packages/gui-shared/src/` and `docs/gui/data-model.md` for channel, DM,
  participant, and policy metadata.

Keep protected message payloads behind Vault/trust-boundary policy. The UI may
render placeholders and metadata before write routes or encrypted transport are
available.

### Issue #25713: Tambo GenUI cards

Primary targets:

- `packages/gui-web/src/AppWorkspace.tsx` for initial card rendering inside
  conversation messages.
- A future `packages/gui-web/src/GenUiCards.tsx` module if card rendering grows
  beyond a small adapter.
- `packages/gui-shared/src/` for `ConversationCard` schema and card capability
  names.

Tambo cards should be embedded as message/card events. They should not replace
the thread model or own the conversation transport.

### Issue #25714: signposts and tours

Primary targets:

- `packages/gui-web/src/AppWorkspace.tsx` for the header button placement,
  `activeSurface`-scoped tour state, and first local tour component.
- `packages/gui-web/src/styles.css` for popover/overlay affordances if needed.
- `packages/gui-web/tests/component.test.ts` for placement and accessibility
  regression coverage.

The signposts icon button must remain immediately left of notifications.

### Issue #25715: QA and release

Primary targets:

- `packages/gui-web/tests/component.test.ts` for UI flows.
- `packages/gui-web/tests/security.test.ts` for browser-side trust-boundary
  assertions.
- `packages/gui-shared/tests/` and `packages/gui-api/tests/` for schema/API
  contracts added by the earlier children.
- `docs/gui/testing-ci-cd.md` for any changed required checks.

## Verification

Discovery command used for this map:

```bash
git ls-files 'apps/**' 'packages/**' 'src/**' 'app/**' 'docs/**'
```

Fast validation for this documentation-only change:

```bash
git diff --check
bun test packages/gui-web/tests
```
