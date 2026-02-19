/**
 * Storage utilities — Cookie and localStorage helpers
 *
 * Centralized persistence layer for the chat sidebar.
 * Handles serialization, size limits, and error recovery.
 *
 * Implementation task: t005.2
 * @see .agents/tools/ui/ai-chat-sidebar.md
 */

// ============================================
// Cookie Helpers
// ============================================

/**
 * Set a cookie with the given name, value, and max age.
 */
export function setCookie(name: string, value: string, maxAge: number): void {
  document.cookie = `${name}=${encodeURIComponent(value)}; path=/; max-age=${maxAge}`
}

/**
 * Get a cookie value by name. Returns null if not found.
 */
export function getCookie(name: string): string | null {
  const match = document.cookie.match(
    new RegExp(`(?:^|; )${name}=([^;]*)`),
  )
  return match ? decodeURIComponent(match[1]) : null
}

/**
 * Delete a cookie by setting max-age to 0.
 */
export function deleteCookie(name: string): void {
  document.cookie = `${name}=; path=/; max-age=0`
}

// ============================================
// localStorage Helpers
// ============================================

/**
 * Get a parsed JSON value from localStorage.
 * Returns the fallback value on any error.
 */
export function getStorageItem<T>(key: string, fallback: T): T {
  try {
    const stored = localStorage.getItem(key)
    if (stored === null) return fallback
    return JSON.parse(stored) as T
  } catch {
    return fallback
  }
}

/**
 * Set a JSON value in localStorage.
 * Fails silently if storage is full or unavailable.
 */
export function setStorageItem<T>(key: string, value: T): void {
  try {
    localStorage.setItem(key, JSON.stringify(value))
  } catch {
    // Storage full or unavailable — fail silently
  }
}

/**
 * Remove an item from localStorage.
 */
export function removeStorageItem(key: string): void {
  try {
    localStorage.removeItem(key)
  } catch {
    // Fail silently
  }
}

// ============================================
// Serialization Helpers
// ============================================

/**
 * Estimate the byte size of a JSON-serializable value.
 * Used to check if data will fit in cookies (~4KB) or localStorage (~5MB).
 */
export function estimateByteSize(value: unknown): number {
  try {
    return new Blob([JSON.stringify(value)]).size
  } catch {
    return 0
  }
}

/** Maximum cookie value size (conservative, accounting for name + metadata) */
export const MAX_COOKIE_BYTES = 3800

/** Maximum localStorage value size per key (conservative) */
export const MAX_STORAGE_BYTES = 4_500_000
