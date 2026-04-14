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

const PRIMITIVE_CONVERTERS: Record<string, (data: unknown) => string> = {
  string: (data) => data as string,
  number: (data) => String(data),
  boolean: (data) => String(data),
}

function convertPrimitive(data: unknown): string | null {
  if (data === null) return 'null'
  if (data === undefined) return 'undefined'
  const converter = PRIMITIVE_CONVERTERS[typeof data]
  return converter ? converter(data) : null
}

function convertArrayToToon(data: unknown[], opts: ToonOptions, depth: number): string {
  const indent = ' '.repeat(depth * opts.indent!)

  if (data.length > 0 && isTabularArray(data)) {
    return convertTabularArray(data, opts, depth)
  }
  if (data.length === 0) return '[]'

  const items = data.map(item => convertToToon(item, opts, depth + 1))
  return `[\n${items.map(i => `${indent}  ${i}`).join('\n')}\n${indent}]`
}

function convertObjectToToon(obj: Record<string, unknown>, opts: ToonOptions, depth: number): string {
  const indent = ' '.repeat(depth * opts.indent!)
  const keys = Object.keys(obj)

  if (keys.length === 0) return '{}'

  const lines = keys.map(key => {
    const value = convertToToon(obj[key], opts, depth + 1)
    if (value.includes('\n')) {
      return `${indent}${key}:\n${value}`
    }
    return `${indent}${key}: ${value}`
  })

  return lines.join('\n')
}

function convertToToon(data: unknown, opts: ToonOptions, depth: number): string {
  const primitive = convertPrimitive(data)
  if (primitive !== null) return primitive

  if (Array.isArray(data)) {
    return convertArrayToToon(data, opts, depth)
  }

  if (typeof data === 'object') {
    return convertObjectToToon(data as Record<string, unknown>, opts, depth)
  }

  return String(data)
}

function isPlainObject(val: unknown): val is Record<string, unknown> {
  return typeof val === 'object' && val !== null && !Array.isArray(val)
}

/**
 * Check if array is tabular (array of objects with same keys)
 */
function isTabularArray(arr: unknown[]): boolean {
  if (arr.length < 2 || !isPlainObject(arr[0])) return false

  const firstKeys = Object.keys(arr[0]).sort().join(',')
  return arr.every(item => isPlainObject(item) && Object.keys(item).sort().join(',') === firstKeys)
}

/**
 * Check if a string value requires CSV-style quoting (contains delimiter,
 * quotes, newlines, or leading/trailing whitespace).
 */
function needsCsvQuoting(str: string, delimiter: string): boolean {
  const hasSpecialChars = str.includes(delimiter) || str.includes('"')
  const hasWhitespaceIssues = str.includes('\n') || str.includes('\r') || str !== str.trim()
  return hasSpecialChars || hasWhitespaceIssues
}

function formatTabularCell(val: unknown, delimiter: string): string {
  if (val === null) return 'null'
  if (val === undefined) return ''
  const str = String(val)
  if (typeof val === 'string' && needsCsvQuoting(str, delimiter)) {
    return `"${str.replace(/"/g, '""')}"`
  }
  return str
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
  const rows = arr.map(obj => keys.map(key => formatTabularCell(obj[key], delimiter)).join(delimiter))

  return `${header}\n${rows.map(r => `${indent}  ${r}`).join('\n')}`
}

import { parseToon } from './toon-parser'

/**
 * Convert TOON format back to JSON
 */
export function toonToJson(toon: string): unknown {
  const lines = toon.split('\n').filter(line => line.trim())
  return parseToon(lines, 0).value
}

// Re-export utility functions for backward compatibility
export { compareSizes, estimateTokens, compareTokens, convertFile } from './toon-utils'
