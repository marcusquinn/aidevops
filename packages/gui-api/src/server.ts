import { serve } from "bun";
import { app } from "./app";

const port = Number.parseInt(process.env.AIDEVOPS_GUI_API_PORT ?? "8787", 10);

serve({
  fetch: app.fetch,
  hostname: "127.0.0.1",
  port,
});

console.log(`aidevops GUI API listening read-only on http://127.0.0.1:${port}`);
