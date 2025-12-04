/**
 * SQLite-based Configuration Cache
 * 
 * Uses Bun's native SQLite for ultra-fast config caching.
 * ~10x faster than reading JSON files repeatedly.
 * 
 * Usage:
 *   import { configCache } from './lib/config-cache'
 *   const config = configCache.get('hostinger')
 *   configCache.set('hostinger', { ... }, 60000)
 */

import { Database } from 'bun:sqlite'

interface CacheRow {
  key: string
  value: string
  expires_at: number
  created_at: number
}

class ConfigCache {
  private db: Database

  constructor(dbPath: string = ':memory:') {
    this.db = new Database(dbPath)
    this.init()
  }

  private init(): void {
    this.db.run(`
      CREATE TABLE IF NOT EXISTS config_cache (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        expires_at INTEGER NOT NULL,
        created_at INTEGER NOT NULL
      )
    `)

    this.db.run(`
      CREATE INDEX IF NOT EXISTS idx_expires_at ON config_cache(expires_at)
    `)
  }

  /**
   * Get a cached value
   */
  get<T>(key: string): T | null {
    const row = this.db.query<CacheRow, [string, number]>(
      'SELECT value FROM config_cache WHERE key = ? AND expires_at > ?'
    ).get(key, Date.now())

    if (!row) return null

    try {
      return JSON.parse(row.value) as T
    } catch {
      return null
    }
  }

  /**
   * Set a cached value with TTL (default: 60 seconds)
   */
  set<T>(key: string, value: T, ttl: number = 60000): void {
    const now = Date.now()
    this.db.run(
      `INSERT OR REPLACE INTO config_cache (key, value, expires_at, created_at) 
       VALUES (?, ?, ?, ?)`,
      [key, JSON.stringify(value), now + ttl, now]
    )
  }

  /**
   * Delete a cached value
   */
  delete(key: string): boolean {
    const result = this.db.run('DELETE FROM config_cache WHERE key = ?', [key])
    return result.changes > 0
  }

  /**
   * Clear all cached values
   */
  clear(): number {
    const result = this.db.run('DELETE FROM config_cache')
    return result.changes
  }

  /**
   * Clear expired entries
   */
  cleanup(): number {
    const result = this.db.run(
      'DELETE FROM config_cache WHERE expires_at < ?',
      [Date.now()]
    )
    return result.changes
  }

  /**
   * Get cache statistics
   */
  stats(): { total: number; expired: number; active: number } {
    const now = Date.now()
    const total = this.db.query<{ count: number }, []>(
      'SELECT COUNT(*) as count FROM config_cache'
    ).get()?.count || 0

    const expired = this.db.query<{ count: number }, [number]>(
      'SELECT COUNT(*) as count FROM config_cache WHERE expires_at < ?'
    ).get(now)?.count || 0

    return {
      total,
      expired,
      active: total - expired,
    }
  }

  /**
   * Get or set with a factory function
   */
  async getOrSet<T>(
    key: string,
    factory: () => Promise<T>,
    ttl: number = 60000
  ): Promise<T> {
    const cached = this.get<T>(key)
    if (cached !== null) {
      return cached
    }

    const value = await factory()
    this.set(key, value, ttl)
    return value
  }

  /**
   * Load a JSON config file with caching
   */
  async loadConfig<T>(
    filePath: string,
    ttl: number = 300000 // 5 minutes default
  ): Promise<T> {
    const cacheKey = `file:${filePath}`
    
    return this.getOrSet(cacheKey, async () => {
      const file = Bun.file(filePath)
      if (!(await file.exists())) {
        throw new Error(`Config file not found: ${filePath}`)
      }
      return file.json() as Promise<T>
    }, ttl)
  }

  /**
   * Close the database connection
   */
  close(): void {
    this.db.close()
  }
}

// Singleton instance for in-memory caching
export const configCache = new ConfigCache()

// Factory for persistent caching
export function createPersistentCache(dbPath: string): ConfigCache {
  return new ConfigCache(dbPath)
}

export { ConfigCache }
