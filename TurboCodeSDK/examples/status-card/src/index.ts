import {
  definePlugin,
  defineTool,
  defineWidget,
  runPlugin,
} from "@granvalenti/turbocode-sdk";

const widget = defineWidget({
  id: "status-card",
  title: "Status Card",
  entrypoint: "widget.html",
  description: "A compact status card rendered from tool props.",
});

const plugin = definePlugin({
  id: "status-card",
  name: "Status Card",
  version: "0.1.0",
  widgets: [widget],
  tools: [
    defineTool({
      name: "openStatusCard",
      description: "Open a card showing a title, message, and status tone.",
      inputSchema: {
        type: "object",
        properties: {
          title: { type: "string" },
          message: { type: "string" },
          tone: { type: "string", enum: ["info", "success", "warning", "error"] },
        },
        required: ["title", "message", "tone"],
        additionalProperties: false,
      },
      async handler(arguments_) {
        const title = String(arguments_.title ?? "Status");
        const message = String(arguments_.message ?? "");
        const allowedTones = new Set(["info", "success", "warning", "error"]);
        const tone = allowedTones.has(String(arguments_.tone))
          ? String(arguments_.tone)
          : "info";

        return {
          text: `${title}: ${message}`,
          widget: {
            id: widget.id,
            props: { title, message, tone },
          },
        };
      },
    }),
  ],
});

await runPlugin(plugin);
