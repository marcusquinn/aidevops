---
description: AI chat sidebar component architecture — design, state management, and integration patterns
mode: subagent
tools: [read, write, edit, bash, glob, grep, task]
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# AI Chat Sidebar — Component Architecture

- **Stack**: React 19 + TypeScript + Tailwind CSS + Elysia (API)
- **State**: 3 split React Contexts with cookie/localStorage persistence
- **Streaming**: SSE from Elysia backend
- **Source**: `.opencode/ui/chat-sidebar/`

## Architecture

Main Content (left) + AI Chat Sidebar (right, fixed-position panel). Toggle button bottom-right when closed.

| Decision | Rationale |
|----------|-----------|
| React scoped to sidebar | Dashboard is vanilla JS; chat needs interactive state |
| 3 split Contexts (no libs) | Split prevents cross-concern re-renders |
| SSE not WebSocket | Unidirectional; simpler, proxy-friendly, auto-reconnects |
| Elysia `/api/chat/*` | Unified with existing API gateway |

## File Structure

```text
.opencode/ui/chat-sidebar/
├── types.ts / constants.ts                    # Shared types + config
├── context/
│   ├── sidebar-context.tsx                    # Panel open/close/width
│   ├── chat-context.tsx                       # Conversation + streaming
│   └── settings-context.tsx                   # Model, context config
├── components/
│   ├── ChatSidebar.tsx / ChatHeader.tsx        # Root + header
│   ├── MessageList.tsx / ChatMessage.tsx       # Message container + item
│   ├── StreamingMessage.tsx / ChatInput.tsx    # Streaming + input
│   ├── ResizeHandle.tsx / ToggleButton.tsx     # Resize + open button
├── hooks/
│   ├── use-chat.ts / use-streaming.ts / use-resize.ts
├── lib/
│   ├── api-client.ts / markdown.ts / storage.ts
└── index.tsx                                  # Provider composition

.opencode/server/chat-api.ts                   # Elysia chat routes
```

## Types

```typescript
type MessageRole = 'user' | 'assistant' | 'system'
type MessageStatus = 'pending' | 'streaming' | 'complete' | 'error'

interface ChatMessage { id: string; role: MessageRole; content: string; status: MessageStatus; timestamp: number; model?: string; tokenCount?: number; error?: string }
interface Conversation { id: string; title: string; messages: ChatMessage[]; createdAt: number; updatedAt: number; model: string; contextSources: ContextSource[] }
interface ContextSource { type: 'file'|'directory'|'memory'|'agent'|'custom'; path: string; label: string; enabled: boolean }
interface SidebarState { open: boolean; width: number; position: 'right'|'left' }
interface ChatState { conversations: Conversation[]; activeConversationId: string|null; isStreaming: boolean; streamingContent: string }
interface SettingsState { defaultModel: string; contextSources: ContextSource[]; maxTokens: number; temperature: number }
```

## State Management

| Context | Updates | Persistence | Scope |
|---------|---------|-------------|-------|
| `SidebarContext` | On toggle/resize | Cookie 7d | Panel open/close, width (320-640px default 420) |
| `ChatContext` | Every message/chunk | localStorage | Messages, streaming state |
| `SettingsContext` | Rarely | Cookie 30d | Model, temperature, context sources |

```tsx
// Provider nesting — outer = least frequent updates
<SettingsProvider defaultModel="sonnet">
  <SidebarProvider defaultOpen={false} defaultWidth={420}>
    <ChatProvider><ChatSidebar /></ChatProvider>
  </SidebarProvider>
</SettingsProvider>
```

`useSidebar()` returns no-op fallback outside provider.

**`sendMessage` flow**: optimistic user message → assistant `status:'streaming'` → SSE `/api/chat/stream` → accumulate `streamingContent` → `status:'complete'` → persist localStorage.

## API

```text
POST /api/chat/send          — Full response (non-streaming)
POST /api/chat/stream        — SSE stream
GET  /api/chat/conversations — List conversations
GET  /api/chat/models        — Available models + status
POST /api/chat/context       — Resolve context sources
```

**SSE format:**

```text
event: start  data: {"conversationId":"abc","model":"claude-sonnet-4-20250514"}
event: delta  data: {"content":"chunk"}
event: done   data: {"tokenCount":150,"model":"claude-sonnet-4-20250514"}
event: error  data: {"message":"Rate limit exceeded","code":"rate_limited"}
```

**Context injection** (prepended as system message): `file` (read content, line range support), `directory` (list + read key files), `memory` (`memory-helper.sh recall`), `agent` (read agent md), `custom` (user text).

## Components

| Component | Key behaviour |
|-----------|--------------|
| `ChatSidebar` | Fixed-position right panel; `transform:translateX()` animation; `Cmd+Shift+L` toggle |
| `ResizeHandle` | Left-edge drag; clamps 320-640px; persists width on `pointerup` |
| `MessageList` | `overflow-y:auto`; auto-scroll to bottom; preserves position on scroll-up; date separators |
| `ChatMessage` | User: right-aligned accent; assistant: left-aligned neutral; markdown + syntax highlight; copy on code blocks |
| `StreamingMessage` | Blinking cursor; updates on SSE delta; "Stop generating" button |
| `ChatInput` | Auto-expanding textarea (max 6 lines); `Enter` send / `Shift+Enter` newline; disabled during streaming |
| `ToggleButton` | Fixed bottom-right; hidden when open; `aria-label="Open AI chat"` |

## Accessibility & Performance

- `aria-label`/visible label on all interactive elements; Tab/Escape nav; `aria-live="polite"` for messages
- `prefers-reduced-motion`: instant show/hide; `h-dvh` not `h-screen`
- `useCallback`/`useMemo` throughout; SSE updates `streamingContent` string (not array); lazy-load markdown

## Integration & Dependencies

```typescript
const apiKey = await getCredential('ANTHROPIC_API_KEY')   // gopass → credentials.sh → env
const model = await resolveModel(settings.defaultModel)    // 'sonnet' → concrete model ID
const memories = await execCommand('memory-helper.sh', ['recall', query, '--limit', '5'])
```

`react` + `react-dom` (~85KB gzipped). Optional: `marked`/`markdown-it` (markdown), `highlight.js`/`shiki` (syntax).

## Testing

Types: `tsc --noEmit`. Components/hooks: Bun test + React Testing Library. API: Bun test + Elysia test client. E2E: Playwright.
