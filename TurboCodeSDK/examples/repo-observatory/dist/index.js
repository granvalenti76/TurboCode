import { definePlugin, defineTool, defineWidget, runPlugin } from "@granvalenti/turbocode-sdk";
import { snapshot } from "./repository.js";
const widget = defineWidget({ id: "change-mosaic", title: "Repo Observatory", entrypoint: "dist/widget.html" });
await runPlugin(definePlugin({
    id: "repo-observatory", name: "Repo Observatory", version: "0.5.0", widgets: [widget],
    tools: [defineTool({
            name: "repo_observatory",
            description: "Show an interactive, read-only Git change mosaic for an absolute workspace path. Call again for a fresh snapshot.",
            inputSchema: { type: "object", properties: { path: { type: "string", description: "Absolute path to the workspace to inspect." } }, required: ["path"], additionalProperties: false },
            async handler(args, context) {
                try {
                    if (typeof args.path !== "string")
                        throw new Error("Provide an absolute workspace path.");
                    const data = await snapshot(args.path, context.signal);
                    return {
                        text: data.state === "no-repository" ? "This directory is not inside a Git working tree."
                            : `${data.name}: ${data.files.length} changed files on ${data.branch}. Snapshot ${data.capturedAt}. Line counts sum staged and unstaged edits; untracked contents are not read.`,
                        widget: { id: widget.id, props: data },
                    };
                }
                catch (error) {
                    return { isError: true, text: error instanceof Error ? error.message : "Unable to inspect repository." };
                }
            },
        })],
}));
