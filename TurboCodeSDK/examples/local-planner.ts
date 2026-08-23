import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import {
  definePlugin,
  defineTool,
  runPlugin,
} from "@granvalenti/turbocode-sdk";

const plugin = definePlugin({
  id: "local-planner",
  name: "Local Planner",
  version: "0.1.0",
  tools: [
    defineTool({
      name: "savePlan",
      description: "Writes a Markdown implementation plan in the plugin data directory.",
      inputSchema: {
        type: "object",
        properties: {
          name: { type: "string", minLength: 1 },
          steps: { type: "array", items: { type: "string" }, minItems: 1 },
        },
        required: ["name", "steps"],
        additionalProperties: false,
      },
      async handler(arguments_) {
        const name = String(arguments_.name ?? "plan").replace(/[^a-z0-9-]/gi, "-");
        const steps = Array.isArray(arguments_.steps)
          ? arguments_.steps.map(String)
          : [];
        const directory = join(process.cwd(), "data", "plans");
        await mkdir(directory, { recursive: true });
        const file = join(directory, `${name}.md`);
        await writeFile(
          file,
          `# ${name}\n\n${steps.map((step, index) => `${index + 1}. ${step}`).join("\n")}\n`,
          "utf8",
        );
        return `Saved ${file}`;
      },
    }),
  ],
});

await runPlugin(plugin);
