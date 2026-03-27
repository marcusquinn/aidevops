/**
 * TOON Format Tool for OpenCode
 * 
 * Native Bun implementation - ~10x faster than npx @toon-format/cli
 * Converts between JSON and TOON (Token-Oriented Object Notation)
 */

import { tool } from "@opencode-ai/plugin"
import { jsonToToon, toonToJson, compareSizes, compareTokens, convertFile } from "../lib/toon"

async function resolveInputData(input: string, action: string): Promise<{ data: unknown; content: string } | string> {
  const isFile = input.endsWith('.json') || input.endsWith('.toon') || input.includes('/')

  if (isFile) {
    const file = Bun.file(input)
    if (!(await file.exists())) {
      return `Error: File not found: ${input}`
    }
    const content = await file.text()
    const data = (input.endsWith('.json') || action === 'encode')
      ? JSON.parse(content)
      : toonToJson(content)
    return { data, content }
  }

  // Inline content
  let data: unknown
  try {
    data = JSON.parse(input)
  } catch {
    data = toonToJson(input)
  }
  return { data, content: input }
}

async function handleEncode(data: unknown, output?: string, delimiter?: string): Promise<string> {
  const toon = jsonToToon(data, { delimiter: delimiter || ',' })

  if (output) {
    await Bun.write(output, toon)
    const stats = compareSizes(data)
    return `✅ Converted to TOON: ${output}\n` +
           `   JSON size: ${stats.jsonSize} bytes\n` +
           `   TOON size: ${stats.toonSize} bytes\n` +
           `   Savings: ${stats.savings} bytes (${stats.savingsPercent})`
  }

  return toon
}

async function handleDecode(data: unknown, output?: string): Promise<string> {
  const json = JSON.stringify(data, null, 2)

  if (output) {
    await Bun.write(output, json)
    return `✅ Converted to JSON: ${output}`
  }

  return json
}

function handleCompare(data: unknown): string {
  const sizeStats = compareSizes(data)
  const tokenStats = compareTokens(data)

  return `📊 TOON vs JSON Comparison\n` +
         `━━━━━━━━━━━━━━━━━━━━━━━━━━\n` +
         `Size:\n` +
         `  JSON: ${sizeStats.jsonSize} bytes\n` +
         `  TOON: ${sizeStats.toonSize} bytes\n` +
         `  Savings: ${sizeStats.savings} bytes (${sizeStats.savingsPercent})\n\n` +
         `Tokens (estimated):\n` +
         `  JSON: ~${tokenStats.jsonTokens} tokens\n` +
         `  TOON: ~${tokenStats.toonTokens} tokens\n` +
         `  Savings: ~${tokenStats.tokensSaved} tokens (${tokenStats.savingsPercent})`
}

function handleStats(data: unknown): string {
  const tokenStats = compareTokens(data)
  const jsonStr = JSON.stringify(data)
  const toonStr = jsonToToon(data)

  const jsonBrackets = (jsonStr.match(/[{}\[\]]/g) || []).length
  const jsonQuotes = (jsonStr.match(/"/g) || []).length
  const toonLines = toonStr.split('\n').length

  return `📈 Token Analysis\n` +
         `━━━━━━━━━━━━━━━━━\n` +
         `JSON structure:\n` +
         `  Brackets: ${jsonBrackets}\n` +
         `  Quotes: ${jsonQuotes}\n` +
         `  Characters: ${jsonStr.length}\n\n` +
         `TOON structure:\n` +
         `  Lines: ${toonLines}\n` +
         `  Characters: ${toonStr.length}\n\n` +
         `Token efficiency:\n` +
         `  JSON tokens: ~${tokenStats.jsonTokens}\n` +
         `  TOON tokens: ~${tokenStats.toonTokens}\n` +
         `  Reduction: ${tokenStats.savingsPercent}`
}

export default tool({
  description: "Convert between JSON and TOON format with native Bun performance (~10x faster than npx)",
  args: {
    action: tool.schema.enum(["encode", "decode", "compare", "stats"]).describe(
      "Action: encode (JSON→TOON), decode (TOON→JSON), compare (show savings), stats (token analysis)"
    ),
    input: tool.schema.string().describe("Input file path or inline JSON/TOON content"),
    output: tool.schema.string().optional().describe("Output file path (optional, prints to stdout if not provided)"),
    delimiter: tool.schema.string().optional().describe("Delimiter for tabular data (default: comma)"),
  },
  async execute(args) {
    const { action, input, output, delimiter } = args

    try {
      const resolved = await resolveInputData(input, action)
      if (typeof resolved === 'string') return resolved
      const { data } = resolved

      switch (action) {
        case 'encode':
          return await handleEncode(data, output, delimiter)
        case 'decode':
          return await handleDecode(data, output)
        case 'compare':
          return handleCompare(data)
        case 'stats':
          return handleStats(data)
        default:
          return `Unknown action: ${action}`
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      return `Error: ${message}`
    }
  },
})
