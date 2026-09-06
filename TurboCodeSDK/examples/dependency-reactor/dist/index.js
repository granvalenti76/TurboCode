import { definePlugin, defineTool, defineWidget, runPlugin } from "@granvalenti/turbocode-sdk";
import { scan } from "./scan.js";
await runPlugin(definePlugin({
    id: "dependency-reactor", name: "Dependency Reactor", version: "0.5.0",
    widgets: [defineWidget({ id: "reactor", title: "Dependency Reactor", entrypoint: "dist/widget.html" })],
    tools: [defineTool({
            name: "dependency_reactor",
            description: "Explore an interactive orbital graph of Swift import references grouped by source folder. Not a symbol-level or compiler-resolved dependency graph.",
            inputSchema: { type: "object", properties: { path: { type: "string", description: "Absolute workspace directory to inspect." } }, required: ["path"], additionalProperties: false },
            async handler(args, ctx) {
                try {
                    if (typeof args.path !== "string")
                        throw new Error("An absolute workspace path is required.");
                    const result = await scan(args.path, ctx.signal);
                    return { text: `Dependency Reactor: ${result.fileCount} Swift files, ${result.nodes.length} nodes, ${result.edges.length} import relationships. Folder groups are not inferred compiler modules. ${result.notes.join(" ")}`, widget: { id: "reactor", props: result } };
                }
                catch (error) {
                    return { isError: true, text: error instanceof Error ? error.message : "Unable to scan workspace." };
                }
            }
        })]
}));
