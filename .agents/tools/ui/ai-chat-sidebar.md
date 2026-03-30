---
description: AI chat sidebar component architecture — design, state management, and integration patterns
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  task: true
---

# AI Chat Sidebar — Component Architecture

<!-- AI-CONTEXT-START -->

- **Stack**: React 19 + TypeScript + Tailwind CSS + Elysia (API)
- **State**: 3 split React Contexts with cookie/localStorage persistence
- **Streaming**: SSE from Elysia backend
- **Source**: `.opencode/ui/chat-sidebar/`

| Task | Scope | Depends on |
|------|-------|------------|
| t005.1 | Architecture & types (this doc) | — |
| t005.2 | Collapsible panel, resize, toggle | t005.1 |
| t005.3 | Chat message UI, streaming, markdown | t005.1, t005.2 |
| t005.4 | AI backend integration, context, API routing | t005.1 |

<!-- AI-CONTEXT-END -->

## Architecture

Layout: Main Content Area (left) + AI Chat Sidebar (right, fixed-position panel). Toggle button floats bottom-right when closed.

- React scoped to sidebar only — existing dashboard uses vanilla JS; chat needs complex interactive state
- React Context (3 split) — app is small; avoids extra deps; split prevents cross-concern re-renders
- SSE not WebSocket — unidirectional streaming; simpler, proxy-friendly, auto-reconnects
- Elysia `/api/chat/*` — keeps backend unified with existing API gateway

## File Structure

```text
.opencode/ui/chat-sidebar/
├── types.ts / constants.ts                    # Shared types + config (t005.1)
├── context/
│   ├── sidebar-context.tsx                    # Panel open/close/width (t005.2)
│   ├── chat-context.tsx                       # Conversation + streaming (t005.3)
│   └── settings-context.tsx                   # Model, context config (t005.4)
├── components/
│   ├── ChatSidebar.tsx / ChatHeader.tsx        # Root + header (t005.2)
│   ├── MessageList.tsx / ChatMessage.tsx       # Message container + item (t005.3)
│   ├── StreamingMessage.tsx / ChatInput.tsx    # Streaming + input (t005.3)
│   ├── ResizeHandle.tsx / ToggleButton.tsx     # Resize + open button (t005.2)
├── hooks/
│   ├── use-chat.ts / use-streaming.ts / use-resize.ts
├── lib/
│   ├── api-client.ts / markdown.ts / storage.ts
└── index.tsx                                  # Provider composition (t005.2)

.opencode/server/chat-api.ts                   # Elysia chat routes (t005.4)
```

## Types

```typescript
type MessageRole = 'user' | 'assistant' | 'system'
type MessageStatus = 'pending' | 'streaming' | 'complete' | 'error'

interface ChatMessage {
  id: string; role: MessageRole; content: string; status: MessageStatus
  timestamp: number; model?: string; tokenCount?: number; error?: string
}
interface Conversation {
  id: string; title: string; messages: ChatMessage[]
  createdAt: number; updatedAt: number; model: string; contextSources: ContextSource[]
}
interface ContextSource { type: 'file'|'directory'|'memory'|'agent'|'custom'; path: string; label: string; enabled: boolean }
interface SidebarState { open: boolean; width: number; position: 'right'|'left' }
interface ChatState { conversations: Conversation[]; activeConversationId: string|null; isStreaming: boolean; streamingContent: string }
interface SettingsState { defaultModel: string; contextSources: ContextSource[]; maxTokens: number; temperature: number }
```

## State Management

| Context | Updates | Persistence | Scope |
|---------|---------|-------------|-------|
| `SidebarContext` | On toggle/resize | Cookie 7d | Panel open/close, width (320–640px default 420) |
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

`useSidebar()` returns safe no-op fallback when used outside provider.

**`sendMessage` flow**: add user message (optimistic) → create assistant message `status:'streaming'` → open SSE `/api/chat/stream` → accumulate `streamingContent` → finalize `status:'complete'` → persist to localStorage.

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

**Context injection** (prepended as system message):

| Source | Resolution |
|--------|-----------|
| `file` | Read file content (line range support) |
| `directory` | List + read key files |
| `memory` | `memory-helper.sh recall <query> --limit 5` |
| `agent` | Read agent markdown file |
| `custom` | User-provided text |

## Components

| Component | Key behaviour |
|-----------|--------------|
| `ChatSidebar` | Fixed-position right panel; `transform:translateX()` animation; `Cmd+Shift+L` toggle |
| `ResizeHandle` | Left-edge drag; clamps 320–640px; persists width on `pointerup` |
| `MessageList` | `overflow-y:auto`; auto-scroll to bottom; preserves position on scroll-up; date separators |
| `ChatMessage` | User: right-aligned accent; assistant: left-aligned neutral; markdown + syntax highlight; copy on code blocks |
| `StreamingMessage` | Blinking cursor; updates on SSE delta; "Stop generating" button |
| `ChatInput` | Auto-expanding textarea (max 6 lines); `Enter` send / `Shift+Enter` newline; disabled during streaming |
| `ToggleButton` | Fixed bottom-right; hidden when open; `aria-label="Open AI chat"` |

## Accessibility & Performance

| Concern | Rule |
|---------|------|
| Interactive elements | `aria-label` or visible label; Tab/Escape keyboard nav; `aria-live="polite"` for new messages |
| Motion | `prefers-reduced-motion`: instant show/hide; `h-dvh` (not `h-screen`) |
| Re-renders | 3 split contexts; `useCallback`/`useMemo` throughout |
| Streaming | SSE chunks update `streamingContent` string (not full array); lazy-load markdown; no `will-change` unless animating |

## Dependencies

| Package | Purpose |
|---------|---------|
| `react` + `react-dom` | UI (~85KB gzipped) |
| `@types/react` + `@types/react-dom` | TypeScript types (dev) |
| `marked`/`markdown-it` *(optional)* | Markdown rendering |
| `highlight.js`/`shiki` *(optional)* | Syntax highlighting |

## Integration

```typescript
const apiKey = await getCredential('ANTHROPIC_API_KEY')  // gopass → credentials.sh → env
const model = await resolveModel(settings.defaultModel)  // 'sonnet' → concrete model ID
const memories = await execCommand('memory-helper.sh', ['recall', query, '--limit', '5'])
```

## Testing

| Layer | Tool | What |
|-------|------|------|
| Types | `tsc --noEmit` | Type correctness |
| Components | Bun test + React Testing Library | Render, interaction, a11y |
| Hooks | Bun test | State transitions, streaming lifecycle |
| API | Bun test + Elysia test client | Routes, SSE format, errors |
| E2E | Playwright | Full sidebar flow |

## Migration Path

| Task | Deliverable |
|------|-------------|
| t005.2 | Panel works (SidebarContext + ChatSidebar + ResizeHandle + ToggleButton), no chat |
| t005.3 | Chat works with mock data (ChatContext + message components + ChatInput) |
| t005.4 | Real AI responses (SettingsContext + chat-api.ts + api-client.ts) |
