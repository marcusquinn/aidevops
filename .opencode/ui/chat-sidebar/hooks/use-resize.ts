/**
 * useResize — Drag-to-resize hook for sidebar width
 *
 * Handles pointer events for resizing the sidebar panel.
 * Clamps width between MIN and MAX, persists on pointer up.
 *
 * Implementation task: t005.2
 * @see .agents/tools/ui/ai-chat-sidebar.md "ResizeHandle"
 */

import { useCallback, useRef, useState } from 'react'
import type { UseResizeReturn } from '../types'
import {
  DEFAULT_SIDEBAR_WIDTH,
  MAX_SIDEBAR_WIDTH,
  MIN_SIDEBAR_WIDTH,
} from '../constants'

interface UseResizeOptions {
  /** Initial width */
  initialWidth?: number
  /** Callback when width changes (for persisting) */
  onWidthChange?: (width: number) => void
  /** Which side the sidebar is on (affects drag direction) */
  position?: 'left' | 'right'
}

/**
 * Hook for drag-to-resize behavior on the sidebar.
 *
 * Usage:
 *   const { width, isDragging, handleProps } = useResize({
 *     initialWidth: 420,
 *     onWidthChange: setWidth,
 *   })
 *   <div {...handleProps} />
 */
export function useResize({
  initialWidth = DEFAULT_SIDEBAR_WIDTH,
  onWidthChange,
  position = 'right',
}: UseResizeOptions = {}): UseResizeReturn {
  const [width, setWidth] = useState(initialWidth)
  const [isDragging, setIsDragging] = useState(false)
  const startXRef = useRef(0)
  const startWidthRef = useRef(initialWidth)

  const handlePointerMove = useCallback(
    (e: PointerEvent) => {
      const delta = position === 'right'
        ? startXRef.current - e.clientX  // Dragging left increases width
        : e.clientX - startXRef.current  // Dragging right increases width

      const newWidth = Math.min(
        Math.max(startWidthRef.current + delta, MIN_SIDEBAR_WIDTH),
        MAX_SIDEBAR_WIDTH,
      )

      setWidth(newWidth)
    },
    [position],
  )

  const handlePointerUp = useCallback(
    (e: PointerEvent) => {
      setIsDragging(false)
      document.body.style.userSelect = ''
      document.body.style.cursor = ''

      // Calculate final width
      const delta = position === 'right'
        ? startXRef.current - e.clientX
        : e.clientX - startXRef.current

      const finalWidth = Math.min(
        Math.max(startWidthRef.current + delta, MIN_SIDEBAR_WIDTH),
        MAX_SIDEBAR_WIDTH,
      )

      // Persist the final width
      onWidthChange?.(finalWidth)

      // Clean up global listeners
      document.removeEventListener('pointermove', handlePointerMove)
      document.removeEventListener('pointerup', handlePointerUp)
    },
    [position, onWidthChange, handlePointerMove],
  )

  const handlePointerDown = useCallback(
    (e: React.PointerEvent) => {
      e.preventDefault()
      setIsDragging(true)
      startXRef.current = e.clientX
      startWidthRef.current = width

      // Prevent text selection during drag
      document.body.style.userSelect = 'none'
      document.body.style.cursor = 'col-resize'

      // Attach global listeners for drag tracking
      document.addEventListener('pointermove', handlePointerMove)
      document.addEventListener('pointerup', handlePointerUp)
    },
    [width, handlePointerMove, handlePointerUp],
  )

  return {
    width,
    isDragging,
    handleProps: {
      onPointerDown: handlePointerDown,
      style: {
        cursor: 'col-resize',
        touchAction: 'none',
      },
    },
  }
}
