/**
 * useStreaming — SSE streaming hook for AI responses
 *
 * Manages a Server-Sent Events connection to the chat API.
 * Accumulates delta events into a content string.
 * Handles start, delta, done, and error events.
 *
 * Implementation task: t005.3
 * @see .agents/tools/ui/ai-chat-sidebar.md "SSE Stream Format"
 */

import { useCallback, useRef, useState } from 'react'
import type {
  ChatRequest,
  StreamEvent,
  UseStreamingReturn,
} from '../types'
import { CHAT_API, SSE_TIMEOUT } from '../constants'

/**
 * Hook for managing SSE streaming from the chat API.
 *
 * Usage:
 *   const { isStreaming, content, startStream, stopStream, error } = useStreaming()
 *   startStream({ conversationId, message, model, ... })
 */
export function useStreaming(): UseStreamingReturn {
  const [isStreaming, setIsStreaming] = useState(false)
  const [content, setContent] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [model, setModel] = useState<string | null>(null)
  const [tokenCount, setTokenCount] = useState<number | null>(null)

  // AbortController ref for cancellation
  const abortRef = useRef<AbortController | null>(null)

  const stopStream = useCallback(() => {
    if (abortRef.current) {
      abortRef.current.abort()
      abortRef.current = null
    }
    setIsStreaming(false)
  }, [])

  const startStream = useCallback((request: ChatRequest) => {
    // Abort any existing stream
    if (abortRef.current) {
      abortRef.current.abort()
    }

    // Reset state
    setContent('')
    setError(null)
    setModel(null)
    setTokenCount(null)
    setIsStreaming(true)

    const controller = new AbortController()
    abortRef.current = controller

    // Timeout safety
    const timeout = setTimeout(() => {
      controller.abort()
      setError('Stream timed out')
      setIsStreaming(false)
    }, SSE_TIMEOUT)

    // Start SSE connection via fetch (EventSource doesn't support POST)
    fetch(CHAT_API.stream, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(request),
      signal: controller.signal,
    })
      .then(async (response) => {
        if (!response.ok) {
          throw new Error(`Stream request failed: ${response.status}`)
        }

        const reader = response.body?.getReader()
        if (!reader) {
          throw new Error('No response body')
        }

        const decoder = new TextDecoder()
        let buffer = ''

        while (true) {
          const { done, value } = await reader.read()
          if (done) break

          buffer += decoder.decode(value, { stream: true })

          // Parse SSE events from buffer
          const lines = buffer.split('\n')
          buffer = lines.pop() ?? '' // Keep incomplete line in buffer

          let eventType = ''
          for (const line of lines) {
            if (line.startsWith('event: ')) {
              eventType = line.slice(7).trim()
            } else if (line.startsWith('data: ')) {
              const data = line.slice(6)
              try {
                const event = JSON.parse(data) as StreamEvent
                handleEvent({ ...event, type: eventType as StreamEvent['type'] })
              } catch {
                // Malformed JSON — skip
              }
            }
          }
        }
      })
      .catch((err: Error) => {
        if (err.name !== 'AbortError') {
          setError(err.message)
        }
      })
      .finally(() => {
        clearTimeout(timeout)
        setIsStreaming(false)
        abortRef.current = null
      })

    function handleEvent(event: StreamEvent): void {
      switch (event.type) {
        case 'start':
          setModel(event.model)
          break
        case 'delta':
          setContent((prev) => prev + event.content)
          break
        case 'done':
          setTokenCount(event.tokenCount)
          setModel(event.model)
          break
        case 'error':
          setError(event.message)
          stopStream()
          break
      }
    }
  }, [stopStream])

  return {
    isStreaming,
    content,
    startStream,
    stopStream,
    error,
    model,
    tokenCount,
  }
}
