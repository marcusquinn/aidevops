/**
 * Chat API Client — HTTP client for the Elysia chat backend
 *
 * Provides typed methods for all chat API endpoints.
 * Streaming is handled by useStreaming hook directly (SSE via fetch).
 *
 * Implementation task: t005.4
 * @see .agents/tools/ui/ai-chat-sidebar.md "API Design"
 */

import type {
  ChatRequest,
  ChatResponse,
  Conversation,
  ContextSource,
  ModelInfo,
  ResolvedContext,
} from '../types'
import { CHAT_API } from '../constants'

/**
 * Send a message and get a complete (non-streaming) response.
 * Use this for simple requests where streaming is not needed.
 */
export async function sendMessage(request: ChatRequest): Promise<ChatResponse> {
  const response = await fetch(CHAT_API.send, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(request),
  })

  if (!response.ok) {
    const error = await response.json().catch(() => ({ message: 'Unknown error' }))
    throw new Error((error as { message: string }).message || `Request failed: ${response.status}`)
  }

  return response.json() as Promise<ChatResponse>
}

/**
 * List all conversations stored on the server.
 * Falls back to empty array on error.
 */
export async function listConversations(): Promise<Conversation[]> {
  try {
    const response = await fetch(CHAT_API.conversations)
    if (!response.ok) return []
    return (await response.json()) as Conversation[]
  } catch {
    return []
  }
}

/**
 * List available models and their current status.
 */
export async function listModels(): Promise<ModelInfo[]> {
  const response = await fetch(CHAT_API.models)
  if (!response.ok) {
    throw new Error(`Failed to fetch models: ${response.status}`)
  }
  return (await response.json()) as ModelInfo[]
}

/**
 * Resolve context sources to their content.
 * Used to preview what context will be injected into a conversation.
 */
export async function resolveContext(
  sources: ContextSource[],
): Promise<ResolvedContext[]> {
  const response = await fetch(CHAT_API.context, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ sources }),
  })

  if (!response.ok) {
    throw new Error(`Failed to resolve context: ${response.status}`)
  }

  return (await response.json()) as ResolvedContext[]
}
