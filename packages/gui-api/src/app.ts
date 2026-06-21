import { Hono } from "hono";
import { BANNED_ROUTE_PATTERNS, STATUS_ROUTE_MANIFEST } from "../../gui-shared/src";
import { readStatus } from "./status-adapter";

export function createGuiApiApp() {
  const app = new Hono();

  app.get(STATUS_ROUTE_MANIFEST.route, (context) => {
    return context.json(readStatus());
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
