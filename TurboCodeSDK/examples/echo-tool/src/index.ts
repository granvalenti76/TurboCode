import {
  definePlugin,
  defineTool,
  runPlugin,
} from "@granvalenti/turbocode-sdk";

const plugin = definePlugin({
  id: "echo-tool",
  name: "Echo Tool",
  version: "0.1.0",
  tools: [
    defineTool({
      name: "echo",
      description: "Echo one string.",
      inputSchema: {
        type: "object",
        properties: { value: { type: "string" } },
        required: ["value"],
        additionalProperties: false,
      },
      async handler(arguments_) {
        return String(arguments_.value ?? "");
      },
    }),
  ],
});

await runPlugin(plugin);
