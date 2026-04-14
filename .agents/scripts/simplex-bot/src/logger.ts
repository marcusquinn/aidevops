/**
 * SimpleX Bot Logger — level-filtered console output.
 * Extracted from index.ts to reduce file-level complexity.
 */

export type LogLevel = "debug" | "info" | "warn" | "error";

const LOG_LEVELS: Record<LogLevel, number> = {
  debug: 0,
  info: 1,
  warn: 2,
  error: 3,
};

/** Level-filtered console logger for bot output */
export class Logger {
  private level: number;

  constructor(level: LogLevel) {
    this.level = LOG_LEVELS[level];
  }

  debug(msg: string, ...args: unknown[]): void {
    if (this.level <= LOG_LEVELS.debug) console.log(`[DEBUG] ${msg}`, ...args);
  }

  info(msg: string, ...args: unknown[]): void {
    if (this.level <= LOG_LEVELS.info) console.log(`[INFO] ${msg}`, ...args);
  }

  warn(msg: string, ...args: unknown[]): void {
    if (this.level <= LOG_LEVELS.warn) console.warn(`[WARN] ${msg}`, ...args);
  }

  error(msg: string, ...args: unknown[]): void {
    if (this.level <= LOG_LEVELS.error) console.error(`[ERROR] ${msg}`, ...args);
  }
}
