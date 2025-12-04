/**
 * Native TOON (Token-Oriented Object Notation) Processing
 * 
 * ~10x faster than npx @toon-format/cli by using native Bun.
 * TOON is a compact, human-readable format optimized for LLM token efficiency.
 * 
 * Usage:
 *   import { jsonToToon, toonToJson, compareSizes } from './lib/toon'
 *   const toon = jsonToToon(jsonData)
 *   const json = toonToJson(toonString)
 */

export interface ToonOptions {
  delimiter?: string
  indent?: number
  includeTypes?: boolean
}

const DEFAULT_OPTIONS: ToonOptions = {
  delimiter: ',',
  indent: 2,
  includeTypes: false,
}

/**
 * Convert JSON to TOON format
 */
export function jsonToToon(data: unknown, options: ToonOptions = {}): string {
  const opts = { ...DEFAULT_OPTIONS, ...options }
  return convertToToon(data, opts, 0)
}

function convertToToon(data: unknown, opts: ToonOptions, depth: number): string {
  const indent = ' '.repeat(depth * opts.indent!)

  if (data === null) return 'null'
  if (data === undefined) return 'undefined'

  if (typeof data === 'string') return data
  if (typeof data === 'number') return String(data)
  if (typeof data === 'boolean') return String(data)

  if (Array.isArray(data)) {
    // Check if array of objects with same keys (tabular data)
    if (data.length > 0 && isTabularArray(data)) {
      return convertTabularArray(data, opts, depth)
    }

    // Regular array
    if (data.length === 0) return '[]'
    
    const items = data.map(item => convertToToon(item, opts, depth + 1))
    return `[\n${items.map(i => `${indent}  ${i}`).join('\n')}\n${indent}]`
  }

  if (typeof data === 'object') {
    const obj = data as Record<string, unknown>
    const keys = Object.keys(obj)
    
    if (keys.length === 0) return '{}'

    const lines = keys.map(key => {
      const value = convertToToon(obj[key], opts, depth + 1)
      // If value is multiline, put it on next line
      if (value.includes('\n')) {
        return `${indent}${key}:\n${value}`
      }
      return `${indent}${key}: ${value}`
    })

    return lines.join('\n')
  }

  return String(data)
}

/**
 * Check if array is tabular (array of objects with same keys)
 */
function isTabularArray(arr: unknown[]): boolean {
  if (arr.length < 2) return false
  if (typeof arr[0] !== 'object' || arr[0] === null) return false
  if (Array.isArray(arr[0])) return false

  const firstKeys = Object.keys(arr[0] as object).sort().join(',')
  
  return arr.every(item => {
    if (typeof item !== 'object' || item === null || Array.isArray(item)) {
      return false
    }
    return Object.keys(item).sort().join(',') === firstKeys
  })
}

/**
 * Convert tabular array to compact TOON format
 * Example: users[2]{id,name,role}:
 *            1,Alice,admin
 *            2,Bob,user
 */
function convertTabularArray(
  arr: Record<string, unknown>[],
  opts: ToonOptions,
  depth: number
): string {
  const indent = ' '.repeat(depth * opts.indent!)
  const keys = Object.keys(arr[0])
  const delimiter = opts.delimiter!

  const header = `[${arr.length}]{${keys.join(',')}}:`
  const rows = arr.map(obj => {
    return keys.map(key => {
      const val = obj[key]
      if (val === null) return 'null'
      if (val === undefined) return ''
      if (typeof val === 'string' && val.includes(delimiter)) {
        return `"${val}"`
      }
      return String(val)
    }).join(delimiter)
  })

  return `${header}\n${rows.map(r => `${indent}  ${r}`).join('\n')}`
}

/**
 * Convert TOON format back to JSON
 */
export function toonToJson(toon: string): unknown {
  const lines = toon.split('\n').filter(line => line.trim())
  return parseToon(lines, 0).value
}

interface ParseResult {
  value: unknown
  consumed: number
}

function parseToon(lines: string[], startIndex: number): ParseResult {
  if (startIndex >= lines.length) {
    return { value: null, consumed: 0 }
  }

  const line = lines[startIndex].trim()

  // Null/undefined
  if (line === 'null') return { value: null, consumed: 1 }
  if (line === 'undefined') return { value: undefined, consumed: 1 }

  // Boolean
  if (line === 'true') return { value: true, consumed: 1 }
  if (line === 'false') return { value: false, consumed: 1 }

  // Number
  if (/^-?\d+(\.\d+)?$/.test(line)) {
    return { value: Number(line), consumed: 1 }
  }

  // Empty array/object
  if (line === '[]') return { value: [], consumed: 1 }
  if (line === '{}') return { value: {}, consumed: 1 }

  // Tabular array header: [count]{keys}:
  const tabularMatch = line.match(/^\[(\d+)\]\{([^}]+)\}:$/)
  if (tabularMatch) {
    const count = parseInt(tabularMatch[1], 10)
    const keys = tabularMatch[2].split(',')
    const result: Record<string, unknown>[] = []

    for (let i = 0; i < count && startIndex + 1 + i < lines.length; i++) {
      const rowLine = lines[startIndex + 1 + i].trim()
      const values = parseDelimitedRow(rowLine, ',')
      const obj: Record<string, unknown> = {}
      keys.forEach((key, idx) => {
        obj[key] = parseValue(values[idx] || '')
      })
      result.push(obj)
    }

    return { value: result, consumed: count + 1 }
  }

  // Key-value pair: key: value
  const kvMatch = line.match(/^([^:]+):\s*(.*)$/)
  if (kvMatch) {
    const key = kvMatch[1].trim()
    const valueStr = kvMatch[2].trim()

    if (valueStr) {
      // Value on same line
      return {
        value: { [key]: parseValue(valueStr) },
        consumed: 1,
      }
    }

    // Value on next lines - need to parse nested structure
    // For simplicity, treat remaining as the value
    const nested = parseToon(lines, startIndex + 1)
    return {
      value: { [key]: nested.value },
      consumed: 1 + nested.consumed,
    }
  }

  // Plain string value
  return { value: line, consumed: 1 }
}

function parseDelimitedRow(row: string, delimiter: string): string[] {
  const result: string[] = []
  let current = ''
  let inQuotes = false

  for (let i = 0; i < row.length; i++) {
    const char = row[i]
    
    if (char === '"' && !inQuotes) {
      inQuotes = true
    } else if (char === '"' && inQuotes) {
      inQuotes = false
    } else if (char === delimiter && !inQuotes) {
      result.push(current)
      current = ''
    } else {
      current += char
    }
  }
  
  result.push(current)
  return result
}

function parseValue(str: string): unknown {
  const trimmed = str.trim()
  
  if (trimmed === 'null') return null
  if (trimmed === 'undefined') return undefined
  if (trimmed === 'true') return true
  if (trimmed === 'false') return false
  if (/^-?\d+(\.\d+)?$/.test(trimmed)) return Number(trimmed)
  
  // Remove quotes if present
  if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return trimmed.slice(1, -1)
  }
  
  return trimmed
}

/**
 * Compare JSON vs TOON sizes
 */
export function compareSizes(data: unknown): {
  jsonSize: number
  toonSize: number
  savings: number
  savingsPercent: string
} {
  const jsonStr = JSON.stringify(data)
  const toonStr = jsonToToon(data)

  const jsonSize = new TextEncoder().encode(jsonStr).length
  const toonSize = new TextEncoder().encode(toonStr).length
  const savings = jsonSize - toonSize

  return {
    jsonSize,
    toonSize,
    savings,
    savingsPercent: `${((savings / jsonSize) * 100).toFixed(1)}%`,
  }
}

/**
 * Estimate token count (rough approximation)
 * Uses ~4 chars per token as a rough estimate
 */
export function estimateTokens(text: string): number {
  return Math.ceil(text.length / 4)
}

/**
 * Compare token usage between JSON and TOON
 */
export function compareTokens(data: unknown): {
  jsonTokens: number
  toonTokens: number
  tokensSaved: number
  savingsPercent: string
} {
  const jsonStr = JSON.stringify(data)
  const toonStr = jsonToToon(data)

  const jsonTokens = estimateTokens(jsonStr)
  const toonTokens = estimateTokens(toonStr)
  const tokensSaved = jsonTokens - toonTokens

  return {
    jsonTokens,
    toonTokens,
    tokensSaved,
    savingsPercent: `${((tokensSaved / jsonTokens) * 100).toFixed(1)}%`,
  }
}

// File operations using Bun
export async function convertFile(
  inputPath: string,
  outputPath: string,
  direction: 'toToon' | 'toJson'
): Promise<{ success: boolean; stats: ReturnType<typeof compareSizes> | null }> {
  const inputFile = Bun.file(inputPath)
  
  if (!(await inputFile.exists())) {
    throw new Error(`Input file not found: ${inputPath}`)
  }

  const content = await inputFile.text()

  if (direction === 'toToon') {
    const data = JSON.parse(content)
    const toon = jsonToToon(data)
    await Bun.write(outputPath, toon)
    return { success: true, stats: compareSizes(data) }
  } else {
    const data = toonToJson(content)
    const json = JSON.stringify(data, null, 2)
    await Bun.write(outputPath, json)
    return { success: true, stats: null }
  }
}
