import { Hono } from "hono";
import { BANNED_ROUTE_PATTERNS, FILE_EXPLORER_ROUTE_MANIFEST, STATUS_ROUTE_MANIFEST } from "../../gui-shared/src";
import { readFileExplorer } from "./file-adapter";
import { readStatus } from "./status-adapter";

export function createGuiApiApp() {
  const app = new Hono();

  app.get(STATUS_ROUTE_MANIFEST.route, (context) => {
    return context.json(readStatus());
  });

  app.get(FILE_EXPLORER_ROUTE_MANIFEST.route, (context) => {
    const root = context.req.param("root");
    const path = context.req.query("path") ?? "";
    const response = readFileExplorer(root, path);
    const status = response.ok ? 200 : response.errors.includes("unknown_file_root") ? 404 : 400;

    return context.json(response, status);
  });

  for (const route of BANNED_ROUTE_PATTERNS) {
    app.post(route, (context) => {
      return context.json(
        {
          ok: false,
          operation_id: "capabilities.read",
          errors: ["write_actions_disabled"],
        },
        405,
      );
    });
  }

  app.notFound((context) => {
    return context.json(
      {
        ok: false,
        operation_id: "capabilities.read",
        errors: ["unknown_route"],
      },
      404,
    );
  });

  return app;
}

export const app = createGuiApiApp();
