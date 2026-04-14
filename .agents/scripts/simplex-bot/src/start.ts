/**
 * SimpleX Bot — Entry point and lifecycle management.
 * Extracted from index.ts to reduce file-level complexity.
 */

import { SimplexAdapter } from "./index";
import { loadConfig } from "./config";

async function main(): Promise<void> {
  const config = loadConfig();

  console.log(`SimpleX Bot v1.0.0`);
  console.log(`Config: port=${config.port}, host=${config.host}, businessAddress=${config.businessAddress}`);

  const bot = new SimplexAdapter(config);

  process.on("SIGINT", () => {
    console.log("\nShutting down...");
    bot.disconnect();
    process.exit(0);
  });

  process.on("SIGTERM", () => {
    bot.disconnect();
    process.exit(0);
  });

  try {
    await bot.connect();
    console.log("SimpleX bot is running. Press Ctrl+C to stop.");
  } catch (err) {
    console.error("Failed to start bot:", err);
    console.error("\nMake sure SimpleX CLI is running as WebSocket server:");
    console.error(`  simplex-chat -p ${config.port}`);
    process.exit(1);
  }
}

main();
