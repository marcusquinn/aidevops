/**
 * useChat — Orchestration hook combining chat context with streaming
 *
 * Bridges ChatContext state with the useStreaming hook.
 * Handles the full send → stream → finalize lifecycle.
 *
 * Implementation task: t005.3 / t005.4
 * @see .agents/tools/ui/ai-chat-sidebar.md "sendMessage flow"
 */

import { useCallback, useEffect, useRef } from 'react'
import type { ChatMessage, ChatRequest } from '../types'
import { useChat as useChatContext } from '../context/chat-context'
import { useSettings } from '../context/settings-context'
import { useStreaming } from './use-streaming'

/**
 * Orchestration hook that combines chat context with streaming.
 *
 * This hook is the primary interface for components that need to
 * send messages and display streaming responses.
 *
 * Usage:
 *   const chat = useChatOrchestrator()
 *   await chat.send('Hello, AI!')
 */
export function useChatOrchestrator() {
  const chatContext = useChatContext()
  const { settings } = useSettings()
  const streaming = useStreaming()
  const streamingMessageIdRef = useRef<string | null>(null)

  // When streaming content updates, sync to chat context
  // (Full implementation in t005.3 — this is the integration pattern)
  useEffect(() => {
    if (streaming.isStreaming && streaming.content) {
      // Update the streaming message content in the active conversation
      // This will be implemented when ChatContext gets message mutation methods
    }
  }, [streaming.isStreaming, streaming.content])

  // When streaming completes, finalize the message
  useEffect(() => {
    if (!streaming.isStreaming && streamingMessageIdRef.current && streaming.content) {
      // Finalize: update message status to 'complete', set final content
      // This will be implemented when ChatContext gets message mutation methods
      streamingMessageIdRef.current = null
    }
  }, [streaming.isStreaming, streaming.content])

  const send = useCallback(
    async (content: string) => {
      const conversation = chatContext.activeConversation
      if (!conversation) {
        // Auto-create a conversation if none exists
        chatContext.newConversation()
        // Note: need to wait for state update — full implementation in t005.3
        return
      }

      // Build the request
      const request: ChatRequest = {
        conversationId: conversation.id,
        message: content,
        model: settings.defaultModel,
        contextSources: settings.contextSources.filter((s) => s.enabled),
        maxTokens: settings.maxTokens,
        temperature: settings.temperature,
      }

      // Generate a message ID for the streaming response
      streamingMessageIdRef.current = crypto.randomUUID()

      // Start streaming
      streaming.startStream(request)
    },
    [chatContext, settings, streaming],
  )

  return {
    ...chatContext,
    send,
    isStreaming: streaming.isStreaming,
    streamingContent: streaming.content,
    streamingError: streaming.error,
    streamingModel: streaming.model,
    stopStreaming: streaming.stopStream,
  }
}
