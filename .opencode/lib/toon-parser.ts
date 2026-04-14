/**
 * TOON Parser — converts TOON format back to JSON data structures.
 *
 * Extracted from toon.ts to keep the converter and parser under the qlty
 * file-complexity threshold independently.
 */

export interface ParseResult {
  value: unknown
  consumed: number
}

const LITERAL_FACTORIES: Record<string, () => unknown> = {
  null: () => null,
  undefined: () => undefined,
  true: () => true,
  false: () => false,
  '[]': () => [],
  '{}': () => ({}),
}

function parseLiteral(line: string): ParseResult | null {
  if (Object.prototype.hasOwnProperty.call(LITERAL_FACTORIES, line)) {
    return { value: LITERAL_FACTORIES[line](), consumed: 1 }
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
      obj[key] = parseValue(values[idx] || '', true)
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

export function parseToon(lines: string[], startIndex: number): ParseResult {
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

interface RowParserState {
  current: string
  inQuotes: boolean
  pos: number
}

function parseQuotedChar(row: string, state: RowParserState): void {
  const char = row[state.pos]
  if (char === '"') {
    if (state.pos + 1 < row.length && row[state.pos + 1] === '"') {
      state.current += '"'
      state.pos += 2
    } else {
      state.inQuotes = false
      state.pos++
    }
  } else {
    state.current += char
    state.pos++
  }
}

function parseUnquotedChar(
  row: string, delimiter: string, state: RowParserState, result: string[],
): void {
  const char = row[state.pos]
  if (char === '"' && state.current === '') {
    state.inQuotes = true
    state.pos++
  } else if (char === delimiter) {
    result.push(state.current)
    state.current = ''
    state.pos++
  } else {
    state.current += char
    state.pos++
  }
}

function parseDelimitedRow(row: string, delimiter: string): string[] {
  const result: string[] = []
  const state: RowParserState = { current: '', inQuotes: false, pos: 0 }

  while (state.pos < row.length) {
    if (state.inQuotes) {
      parseQuotedChar(row, state)
    } else {
      parseUnquotedChar(row, delimiter, state, result)
    }
  }

  result.push(state.current)
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

function parseValue(str: string, fromTabular = false): unknown {
  const trimmed = str.trim()

  const detected = detectKnownValue(trimmed)
  if (detected.known) return detected.value

  if (!fromTabular && trimmed.startsWith('"') && trimmed.endsWith('"')) {
    return trimmed.slice(1, -1)
  }

  return fromTabular ? str : trimmed
}
