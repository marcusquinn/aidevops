/**
 * TOON Utility Functions — size comparison, token estimation, and file I/O.
 *
 * Extracted from toon.ts to reduce file-level complexity below the qlty
 * maintainability threshold while keeping the core converter focused.
 */

import { jsonToToon, toonToJson } from './toon'

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

/**
 * Convert a file between JSON and TOON formats using Bun.
 */
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
  // nosemgrep: javascript.lang.security.audit.unsafe-dynamic-method.unsafe-dynamic-method
  // FILE_CONVERTERS keys are constrained by the 'toToon' | 'toJson' type union — not user-controlled.
  return FILE_CONVERTERS[direction](content, outputPath)
}
