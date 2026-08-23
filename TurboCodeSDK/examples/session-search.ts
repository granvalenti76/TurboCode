import {
  definePlugin,
  defineTool,
  runPlugin,
} from "@granvalenti/turbocode-sdk";

const plugin = definePlugin({
  id: "session-search",
  name: "Session Search",
  version: "0.1.0",
  tools: [
    defineTool({
      name: "findInSession",
      description: "Finds earlier user or assistant messages containing text.",
      inputSchema: {
        type: "object",
        properties: { query: { type: "string", minLength: 1 } },
        required: ["query"],
        additionalProperties: false,
      },
      async handler(arguments_, context) {
        const query = String(arguments_.query ?? "").toLowerCase();
        const transcript = await context.session.transcript();
        const matches = transcript?.entries.filter((entry) =>
          entry.text.toLowerCase().includes(query),
        ) ?? [];
        return JSON.stringify({
          query,
          matches: matches.map(({ kind, text, createdAt }) => ({
            kind,
            text,
            createdAt,
          })),
        });
      },
    }),
  ],
});

await runPlugin(plugin);
