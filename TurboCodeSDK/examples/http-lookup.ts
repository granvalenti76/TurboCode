import {
  definePlugin,
  defineTool,
  runPlugin,
} from "@granvalenti/turbocode-sdk";

const plugin = definePlugin({
  id: "http-lookup",
  name: "HTTP Lookup",
  version: "0.1.0",
  tools: [
    defineTool({
      name: "fetchJSON",
      description: "Fetches a JSON document from an HTTP endpoint.",
      inputSchema: {
        type: "object",
        properties: { url: { type: "string", format: "uri" } },
        required: ["url"],
        additionalProperties: false,
      },
      async handler(arguments_, context) {
        const url = String(arguments_.url ?? "");
        const response = await fetch(url, { signal: context.signal });
        if (!response.ok) {
          throw new Error(`HTTP ${response.status} from ${url}`);
        }
        return JSON.stringify(await response.json());
      },
    }),
  ],
});

await runPlugin(plugin);
