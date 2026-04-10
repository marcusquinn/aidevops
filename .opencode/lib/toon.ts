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

function formatTabularCell(val: unknown, delimiter: string): string {
  if (val === null) return 'null'
  if (val === undefined) return ''
  if (typeof val === 'string' && val.includes(delimiter)) return `"${val}"`
  return String(val)
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

const LITERAL_MAP: Record<string, unknown> = {
  null: null,
  undefined: undefined,
  true: true,
  false: false,
  '[]': [],
  '{}': {},
}

function parseLiteral(line: string): ParseResult | null {
  if (Object.prototype.hasOwnProperty.call(LITERAL_MAP, line)) {
    return { value: LITERAL_MAP[line], consumed: 1 }
  }
  if (/^-?\d+(\.\d+)?$/.test(line)) return { value: Number(line), consumed: 1 }
  return null
}

function parseTabularBlock(lines: string[], startIndex: number, match: RegExpMatchArray): ParseResult {
  const count = parseInt(match[1], 10)
  const keys = match[2].split(',')
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

function parseKeyValuePair(lines: string[], startIndex: number, match: RegExpMatchArray): ParseResult {
  const key = match[1].trim()
  const valueStr = match[2].trim()

  if (valueStr) {
    return {
      value: { [key]: parseValue(valueStr) },
      consumed: 1,
    }
  }

  const nested = parseToon(lines, startIndex + 1)
  return {
    value: { [key]: nested.value },
    consumed: 1 + nested.consumed,
  }
}

function parseToon(lines: string[], startIndex: number): ParseResult {
  if (startIndex >= lines.length) {
    return { value: null, consumed: 0 }
  }

  const line = lines[startIndex].trim()

  const literal = parseLiteral(line)
  if (literal !== null) return literal

  const tabularMatch = line.match(/^\[(\d+)\]\{([^}]+)\}:$/)
  if (tabularMatch) {
    return parseTabularBlock(lines, startIndex, tabularMatch)
  }

  const kvMatch = line.match(/^([^:]+):\s*(.*)$/)
  if (kvMatch) {
    return parseKeyValuePair(lines, startIndex, kvMatch)
  }

  return { value: line, consumed: 1 }
}

function parseDelimitedRow(row: string, delimiter: string): string[] {
  const result: string[] = []
  let current = ''
  let inQuotes = false

  for (const char of row) {
    if (char === '"') {
      inQuotes = !inQuotes
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

const KNOWN_VALUES: Record<string, unknown> = {
  null: null,
  undefined: undefined,
  true: true,
  false: false,
}

function detectKnownValue(trimmed: string): { known: true; value: unknown } | { known: false } {
  if (Object.prototype.hasOwnProperty.call(KNOWN_VALUES, trimmed)) {
    return { known: true, value: KNOWN_VALUES[trimmed] }
  }
  if (/^-?\d+(\.\d+)?$/.test(trimmed)) return { known: true, value: Number(trimmed) }
  return { known: false }
}

function parseValue(str: string): unknown {
  const trimmed = str.trim()

  const detected = detectKnownValue(trimmed)
  if (detected.known) return detected.value

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

async function convertJsonToToonFile(content: string, outputPath: string) {
  const data = JSON.parse(content)
  await Bun.write(outputPath, jsonToToon(data))
  return { success: true, stats: compareSizes(data) }
}

async function convertToonToJsonFile(content: string, outputPath: string) {
  const json = JSON.stringify(toonToJson(content), null, 2)
  await Bun.write(outputPath, json)
  return { success: true, stats: null }
}

const FILE_CONVERTERS = {
  toToon: convertJsonToToonFile,
  toJson: convertToonToJsonFile,
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
  return FILE_CONVERTERS[direction](content, outputPath)
}
