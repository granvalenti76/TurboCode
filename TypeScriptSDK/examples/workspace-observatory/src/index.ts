import {
  definePlugin,
  defineTool,
  defineWidget,
  runPlugin,
} from "@granvalenti/turbocode-sdk";

const observatory = defineWidget({
  id: "workspace-observatory",
  title: "Workspace Observatory",
  entrypoint: "dist/widget.html",
  description: "An interactive dashboard for workspace and session signals.",
});

const plugin = definePlugin({
  id: "workspace-observatory",
  name: "Workspace Observatory",
  version: "0.1.0",
  widgets: [observatory],
  tools: [
    defineTool({
      name: "openObservatory",
      description: "Open an interactive workspace and session observatory.",
      inputSchema: {
        type: "object",
        properties: {},
        required: [],
        additionalProperties: false,
      },
      async handler(_arguments, context) {
        const transcript = await context.session.transcript();
        const entries = transcript?.entries ?? [];
        const activity = entries.slice(-8).map((entry) => ({
          kind: entry.kind,
          text: entry.text.slice(0, 120),
          createdAt: entry.createdAt,
        }));

        return {
          text: "Workspace Observatory ready.",
          widget: {
            id: observatory.id,
            props: {
              session: {
                title: transcript?.title ?? "Untitled session",
                entries: entries.length,
                updatedAt: transcript?.updatedAt ?? new Date().toISOString(),
              },
              activity,
              signals: [
                { label: "Session memory", value: entries.length + " events", tone: "violet" },
                { label: "Plugin runtime", value: "Node 24", tone: "cyan" },
                { label: "Widget mode", value: "Interactive", tone: "green" },
              ],
              files: [
                { name: "Sources", kind: "folder", value: "24 files" },
                { name: "Tests", kind: "folder", value: "18 suites" },
                { name: "Package.swift", kind: "file", value: "Swift 6" },
                { name: "README.md", kind: "file", value: "Updated today" },
              ],
            },
          },
        };
      },
    }),
  ],
});

await runPlugin(plugin);
