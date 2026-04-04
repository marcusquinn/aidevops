---
description: Vercel AI SDK - streaming chat, useChat hook, AI providers
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
  context7_*: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Vercel AI SDK - AI Integration

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Build AI-powered applications with streaming support
- **Packages**: `ai`, `@ai-sdk/react`, `@ai-sdk/openai`
- **Docs**: Use Context7 MCP for current documentation

**Key Components**:
- `useChat` - React hook for chat interfaces
- `streamText` - Server-side streaming
- Provider adapters (OpenAI, Anthropic, etc.)

**Basic Chat Implementation**:

```tsx
// Client: useChat hook
"use client";
import { useChat } from "@ai-sdk/react";

function Chat() {
  const { messages, input, handleInputChange, handleSubmit, status } = useChat({
    api: "/api/chat",
  });

  return (
    <div>
      {messages.map((m) => (
        <div key={m.id}>
          {m.role}: {m.parts.map(p => p.type === "text" ? p.text : null)}
        </div>
      ))}
      <form onSubmit={handleSubmit}>
        <input value={input} onChange={handleInputChange} />
        <button type="submit" disabled={status === "streaming"}>Send</button>
      </form>
    </div>
  );
}
```

```tsx
// Server: API route
import { openai } from "@ai-sdk/openai";
import { streamText } from "ai";

export async function POST(req: Request) {
  const { messages } = await req.json();
  const result = streamText({ model: openai("gpt-4o"), messages });
  return result.toDataStreamResponse();
}
```

**Custom Transport** (for Hono/custom APIs):

```tsx
import { useChat } from "@ai-sdk/react";
import { DefaultChatTransport } from "ai";

const { messages, sendMessage, status } = useChat({
  transport: new DefaultChatTransport({ api: "/api/ai/chat" }),
});
```

**Message Parts** — iterate `message.parts`; types: `text` (render `part.text`), `tool-call` (render custom component):

```tsx
{message.parts.map((part, i) =>
  part.type === "text" ? <p key={i}>{part.text}</p> :
  part.type === "tool-call" ? <ToolResult key={i} call={part} /> : null
)}
```

**Status Values**:

| Status | Meaning |
|--------|---------|
| `idle` | No request in progress |
| `submitted` | Request sent, waiting for response |
| `streaming` | Receiving streamed response |
| `error` | Request failed |

<!-- AI-CONTEXT-END -->

## Detailed Patterns

### Full Chat Component with Markdown

Key additions over Quick Reference: markdown rendering with XSS protection, auto-scroll, `sendMessage` API, error handling.

```tsx
"use client";
import { useChat } from "@ai-sdk/react";
import { DefaultChatTransport } from "ai";
import { marked } from "marked";
import DOMPurify from "dompurify"; // npm install dompurify @types/dompurify
import { useState, useRef, useEffect } from "react";

const sanitizeMarkdown = (text: string) =>
  DOMPurify.sanitize(marked.parse(text) as string, {
    ALLOWED_TAGS: ["p", "br", "strong", "em", "code", "pre", "ul", "ol", "li", "a", "h1", "h2", "h3", "blockquote"],
    ALLOWED_ATTR: ["href", "class"],
  });

export function AIChatSidebar() {
  const [input, setInput] = useState("");
  const scrollRef = useRef<HTMLDivElement>(null);
  const { messages, error, sendMessage, status } = useChat({
    transport: new DefaultChatTransport({ api: "/api/ai/chat" }),
    onError: (err) => console.error("Chat Error:", err),
  });
  const displayMessages = messages.filter((m) => ["assistant", "user"].includes(m.role));
  const isLoading = ["submitted", "streaming"].includes(status);

  useEffect(() => {
    if (scrollRef.current) scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
  }, [messages]);

  const handleSubmit = () => { if (input.trim()) { sendMessage({ text: input }); setInput(""); } };

  if (error) return <div>Error: {error.message}</div>;

  return (
    <div className="flex flex-col h-full">
      <div ref={scrollRef} className="flex-1 overflow-auto p-4">
        {displayMessages.map((message) => (
          <div key={message.id} className={message.role === "user" ? "text-right" : "text-left"}>
            {message.parts.map((part, i) =>
              part.type === "text" ? (
                message.role === "assistant"
                  ? <div key={i} className="prose" dangerouslySetInnerHTML={{ __html: sanitizeMarkdown(part.text) }} />
                  : <p key={i}>{part.text}</p>
              ) : null
            )}
          </div>
        ))}
        {isLoading && <div>Thinking...</div>}
      </div>
      <div className="p-4 border-t">
        <textarea value={input} onChange={(e) => setInput(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); handleSubmit(); } }}
          disabled={isLoading} placeholder="Type a message..." />
        <button onClick={handleSubmit} disabled={isLoading || !input.trim()}>Send</button>
      </div>
    </div>
  );
}
```

### Server Route with Hono

```tsx
import { Hono } from "hono";
import { openai } from "@ai-sdk/openai";
import { streamText } from "ai";

export const aiRoutes = new Hono()
  .post("/chat", async (c) => {
    const { messages } = await c.req.json();
    const result = streamText({ model: openai("gpt-4o"), system: "You are a helpful assistant.", messages });
    return result.toDataStreamResponse();
  });
```

### Tool Calling

```tsx
import { streamText, tool } from "ai";
import { z } from "zod";

const result = streamText({
  model: openai("gpt-4o"),
  messages,
  tools: {
    getWeather: tool({
      description: "Get weather for a location",
      parameters: z.object({ location: z.string() }),
      execute: async ({ location }) => ({ temperature: 72, condition: "sunny" }),
    }),
  },
});
```

### Multiple Providers

Swap the `model:` argument — same `streamText` API for all providers:

```tsx
import { anthropic } from "@ai-sdk/anthropic";
// model: anthropic("claude-sonnet-4-6")  or  openai("gpt-4o")  or  any @ai-sdk/* adapter
```

### Structured Output

```tsx
import { generateObject } from "ai";
import { z } from "zod";

const result = await generateObject({
  model: openai("gpt-4o"),
  schema: z.object({ title: z.string(), summary: z.string(), tags: z.array(z.string()) }),
  prompt: "Analyze this article...",
});
console.log(result.object); // Typed!
```

## Common Mistakes

1. **Not handling all message parts** — iterate `message.parts`, not `message.content`; parts can be `text`, `tool-call`, etc.
2. **Forgetting to filter messages** — `messages` includes system messages; filter to `["user", "assistant"]` for display.
3. **Not checking status** — disable input and show loading indicator during `submitted`/`streaming`.
4. **Missing error handling** — always handle `error` from `useChat`; provide a retry mechanism.
5. **XSS with markdown** — never use `dangerouslySetInnerHTML` with unsanitized content; use `DOMPurify.sanitize(marked.parse(text))`.

## Related

- `tools/api/hono.md` - API routes for AI endpoints
- `tools/ui/react-context.md` - Managing chat state
- Context7 MCP for AI SDK documentation
