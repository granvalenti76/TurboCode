import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import {
  definePlugin,
  defineTool,
  defineWidget,
  runPlugin,
  type JSONValue,
  type PluginToolContext,
  type PluginToolResult,
} from "@granvalenti/turbocode-sdk";

type HandoffStatus = "in-progress" | "blocked" | "ready";

type Handoff = {
  id: string;
  title: string;
  status: HandoffStatus;
  summary: string;
  completed: string[];
  current: string;
  next: string;
  files: string[];
  risks: string[];
  sessionID: string | null;
  transcriptEntries: number;
  updatedAt: string;
};

const dataDirectory = join(process.cwd(), "data", "handoffs");

const widget = defineWidget({
  id: "session-handoff-card",
  title: "Session Handoff",
  entrypoint: "dist/widget.html",
  description: "A compact Continuity Card for resuming work.",
});

function asString(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value.trim() : fallback;
}

function asStringArray(value: unknown): string[] {
  return Array.isArray(value)
    ? value.map(String).map((item) => item.trim()).filter(Boolean)
    : [];
}

function slugify(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 48) || "handoff";
}

function fileFor(id: string): string {
  if (!/^[a-z0-9-]+$/.test(id)) throw new Error("Invalid handoff id.");
  return join(dataDirectory, `${id}.json`);
}

function propsFor(handoff: Handoff): { [key: string]: JSONValue } {
  return {
    id: handoff.id,
    title: handoff.title,
    status: handoff.status,
    summary: handoff.summary,
    completed: handoff.completed,
    current: handoff.current,
    next: handoff.next,
    files: handoff.files,
    risks: handoff.risks,
    sessionID: handoff.sessionID,
    transcriptEntries: handoff.transcriptEntries,
    updatedAt: handoff.updatedAt,
    kind: "handoff",
  };
}

function resultFor(handoff: Handoff, text: string): PluginToolResult {
  return {
    text,
    widget: { id: widget.id, props: propsFor(handoff) },
  };
}

async function transcriptMeta(context: PluginToolContext) {
  const transcript = await context.session.transcript();
  return {
    sessionID: transcript?.sessionID ?? null,
    transcriptEntries: transcript?.entries.length ?? 0,
  };
}

async function readHandoffs(): Promise<Handoff[]> {
  let names: string[];
  try {
    names = await readdir(dataDirectory);
  } catch {
    return [];
  }

  const handoffs = await Promise.all(
    names
      .filter((name) => name.endsWith(".json"))
      .map(async (name) => {
        try {
          return JSON.parse(await readFile(join(dataDirectory, name), "utf8")) as Handoff;
        } catch {
          return null;
        }
      }),
  );

  return handoffs
    .filter((handoff): handoff is Handoff => handoff !== null)
    .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
}

const plugin = definePlugin({
  id: "session-handoff",
  name: "Session Handoff",
  version: "0.1.0",
  widgets: [widget],
  tools: [
    defineTool({
      name: "saveHandoff",
      description: "Save the current work state so another turn or model can resume it.",
      inputSchema: {
        type: "object",
        properties: {
          title: { type: "string" },
          status: { type: "string", enum: ["in-progress", "blocked", "ready"] },
          summary: { type: "string" },
          completed: { type: "array", items: { type: "string" } },
          current: { type: "string" },
          next: { type: "string" },
          files: { type: "array", items: { type: "string" } },
          risks: { type: "array", items: { type: "string" } },
        },
        required: ["title", "status", "summary", "completed", "current", "next", "files", "risks"],
        additionalProperties: false,
      },
      async handler(arguments_, context) {
        if (context.signal.aborted) return { text: "Handoff cancelled.", isError: true };

        const title = asString(arguments_.title, "Untitled handoff");
        const statusValue = asString(arguments_.status, "in-progress");
        const status: HandoffStatus = ["in-progress", "blocked", "ready"].includes(statusValue)
          ? statusValue as HandoffStatus
          : "in-progress";
        const id = `${new Date().toISOString().replace(/[^0-9]/g, "").slice(0, 14)}-${slugify(title)}`;
        const meta = await transcriptMeta(context);
        const handoff: Handoff = {
          id,
          title,
          status,
          summary: asString(arguments_.summary),
          completed: asStringArray(arguments_.completed),
          current: asString(arguments_.current),
          next: asString(arguments_.next),
          files: asStringArray(arguments_.files),
          risks: asStringArray(arguments_.risks),
          ...meta,
          updatedAt: new Date().toISOString(),
        };

        await mkdir(dataDirectory, { recursive: true });
        await writeFile(fileFor(id), `${JSON.stringify(handoff, null, 2)}\n`, "utf8");
        return resultFor(handoff, `Saved handoff '${id}'.`);
      },
    }),
    defineTool({
      name: "listHandoffs",
      description: "List saved handoffs available for resuming previous work.",
      inputSchema: {
        type: "object",
        properties: {},
        required: [],
        additionalProperties: false,
      },
      async handler() {
        const handoffs = await readHandoffs();
        if (handoffs.length === 0) return "No saved handoffs.";
        return handoffs
          .map((handoff) => `${handoff.id} — ${handoff.title} [${handoff.status}]`)
          .join("\n");
      },
    }),
    defineTool({
      name: "loadHandoff",
      description: "Load one saved handoff by id and show its continuation card.",
      inputSchema: {
        type: "object",
        properties: { id: { type: "string" } },
        required: ["id"],
        additionalProperties: false,
      },
      async handler(arguments_) {
        try {
          const handoff = JSON.parse(await readFile(fileFor(asString(arguments_.id)), "utf8")) as Handoff;
          return resultFor(handoff, `Loaded handoff '${handoff.id}'.`);
        } catch {
          return { text: `Handoff '${asString(arguments_.id)}' was not found.`, isError: true };
        }
      },
    }),
  ],
});

await runPlugin(plugin);
