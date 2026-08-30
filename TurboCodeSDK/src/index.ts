/**
 * Public TypeScript SDK for TurboCode plugins.
 *
 * This module defines the typed plugin authoring surface and the runtime bridge
 * used by a plugin process. TurboCode owns the host boundary, approvals,
 * cancellation, timeouts, and presentation; plugin code receives only the
 * value-based APIs exposed by this module. The runtime communicates with the
 * host through JSON-RPC 2.0 messages framed as one JSON object per stdout line.
 *
 * Keep this file provider-neutral and free of Swift or application-store
 * dependencies. Changes to the exported types are SDK contract changes and
 * must remain compatible with the host protocol version.
 */
import readline from "node:readline";

/** Version of the JSON-RPC contract understood by the TurboCode host. */
export const PROTOCOL_VERSION = 1 as const;

/** Minimum Node.js engine required by the plugin runtime. */
export const NODE_ENGINE = ">=24.0.0" as const;

/** Recursive set of values that can cross the JSON-RPC boundary. */
export type JSONValue =
  | null
  | boolean
  | number
  | string
  | JSONValue[]
  | { [key: string]: JSONValue };

/** JSON Schema passed through to the selected TurboCode provider. */
export type JSONSchema = { [key: string]: JSONValue };

/**
 * Cross-provider object schema required for a plugin tool's arguments.
 *
 * TurboCode's native Foundation Models adapter currently represents every
 * declared property as required, so plugin authors must list every property
 * in `required`. Use an empty array for a tool with no arguments.
 */
export type ToolInputSchema = JSONSchema & {
  type: "object";
  properties: JSONSchema;
  required: string[];
};

/** One provider-neutral entry in the active TurboCode session transcript. */
export type SessionTranscriptEntry = {
  id: string;
  kind: string;
  text: string;
  createdAt: string;
  model: string | null;
  providerID: string | null;
};

/** Read-only snapshot returned by the host for the active session. */
export type SessionTranscript = {
  sessionID: string | null;
  title: string | null;
  updatedAt: string;
  entries: SessionTranscriptEntry[];
};

/** Host APIs available to a plugin while a tool is executing. */
export type PluginSession = {
  /** Returns a read-only snapshot, or null when no session is active. */
  transcript(): Promise<SessionTranscript | null>;
};

/** Declarative widget metadata exposed by a plugin in its manifest. */
export type PluginWidgetDefinition = {
  id: string;
  title: string;
  entrypoint: string;
  description?: string;
};

/** Widget request returned by a tool result for host-side rendering. */
export type PluginWidgetInvocation = {
  id: string;
  props?: JSONValue;
};

/** Normalized textual result and optional widget request returned by a tool. */
export type PluginToolResult = {
  text: string;
  isError?: boolean;
  widget?: PluginWidgetInvocation;
};

/** Context supplied to every plugin tool invocation. */
export type PluginToolContext = {
  pluginId: string;
  signal: AbortSignal;
  session: PluginSession;
};

/**
 * Function implemented by a plugin tool.
 *
 * The handler may return plain text for simple tools or a structured result
 * when it needs to mark an error or request a declarative widget.
 */
export type PluginToolHandler = (
  arguments_: Record<string, unknown>,
  context: PluginToolContext,
) => PluginToolResult | string | Promise<PluginToolResult | string>;

/** Tool metadata and implementation registered by a plugin. */
export type PluginToolDefinition = {
  name: string;
  description: string;
  inputSchema: ToolInputSchema;
  handler: PluginToolHandler;
};

/** Complete in-process definition used to validate and run a plugin. */
export type PluginDefinition = {
  id: string;
  name: string;
  version: string;
  tools: PluginToolDefinition[];
  widgets?: PluginWidgetDefinition[];
};

/** Manifest metadata serialized for TurboCode discovery and activation. */
export type PluginManifest = {
  manifestVersion: 1;
  id: string;
  name: string;
  version: string;
  entrypoint: string;
  runtime: { kind: "node"; node: ">=24.0.0" };
  tools: Array<{
    name: string;
    description: string;
    inputSchema: ToolInputSchema;
  }>;
  widgets: PluginWidgetDefinition[];
};

/**
 * Validates and returns a declarative widget definition.
 *
 * @param definition Widget metadata to validate.
 * @returns The same definition after validation.
 * @throws If the widget is missing an id, title, or entrypoint.
 */
export function defineWidget(
  definition: PluginWidgetDefinition,
): PluginWidgetDefinition {
  if (!definition.id || !definition.title || !definition.entrypoint) {
    throw new Error("A plugin widget needs an id, title, and entrypoint.");
  }
  return definition;
}

/** JSON-RPC request identifier accepted by the host protocol. */
type JSONRPCID = number | string;

/** Internal JSON-RPC request received from TurboCode. */
type JSONRPCRequest = {
  jsonrpc: "2.0";
  id: JSONRPCID;
  method: string;
  params?: Record<string, JSONValue>;
};

/** Internal JSON-RPC response sent to TurboCode. */
type JSONRPCResponse = {
  jsonrpc: "2.0";
  id: JSONRPCID | null;
  result?: JSONValue;
  error?: { code: number; message: string };
};

/**
 * Validates and returns a plugin tool definition.
 *
 * @param definition Tool metadata and handler to validate.
 * @returns The same definition after validation.
 * @throws If required metadata or the cross-provider input schema contract is
 * missing.
 */
export function defineTool(
  definition: PluginToolDefinition,
): PluginToolDefinition {
  if (!definition.name || !definition.description) {
    throw new Error("A plugin tool needs a name and description.");
  }
  if (definition.inputSchema.type !== "object") {
    throw new Error("Plugin tool schemas must be JSON objects.");
  }
  const properties = definition.inputSchema.properties;
  const required = definition.inputSchema.required;
  if (
    properties === null
    || Array.isArray(properties)
    || typeof properties !== "object"
    || !Array.isArray(required)
    || !required.every((name) => typeof name === "string")
  ) {
    throw new Error(
      "Plugin tool schemas need object properties and a required string array.",
    );
  }
  const propertyNames = new Set(Object.keys(properties));
  if (
    required.length !== propertyNames.size
    || required.some((name) => !propertyNames.has(name))
  ) {
    throw new Error(
      "Plugin tool schemas must list every property in required.",
    );
  }
  return definition;
}

/**
 * Validates a complete plugin definition, including unique tool and widget ids.
 *
 * @param definition Plugin metadata, tools, and optional widgets to validate.
 * @returns The same definition after validation.
 * @throws If required metadata is missing, no tools are registered, or an id is duplicated.
 */
export function definePlugin(
  definition: PluginDefinition,
): PluginDefinition {
  if (!definition.id || !definition.name || !definition.version) {
    throw new Error("A plugin needs an id, name, and version.");
  }
  if (definition.tools.length === 0) {
    throw new Error("A plugin needs at least one tool.");
  }
  const names = new Set<string>();
  for (const tool of definition.tools) {
    defineTool(tool);
    if (names.has(tool.name)) {
      throw new Error(`Duplicate plugin tool: ${tool.name}`);
    }
    names.add(tool.name);
  }
  const widgetIDs = new Set<string>();
  for (const widget of definition.widgets ?? []) {
    defineWidget(widget);
    if (widgetIDs.has(widget.id)) {
      throw new Error(`Duplicate plugin widget: ${widget.id}`);
    }
    widgetIDs.add(widget.id);
  }
  return definition;
}

/**
 * Builds the host-discoverable manifest for a validated plugin.
 *
 * Runtime handlers are intentionally omitted: the manifest contains only the
 * metadata TurboCode needs before starting the plugin process.
 *
 * @param plugin Plugin definition to validate and describe.
 * @param entrypoint Path to the compiled plugin entrypoint.
 * @returns A JSON-serializable manifest for TurboCode discovery.
 * @throws If the plugin definition is invalid.
 */
export function manifestFor(
  plugin: PluginDefinition,
  entrypoint: string,
): PluginManifest {
  const validated = definePlugin(plugin);
  return {
    manifestVersion: 1,
    id: validated.id,
    name: validated.name,
    version: validated.version,
    entrypoint,
    runtime: { kind: "node", node: ">=24.0.0" },
    tools: validated.tools.map(({ name, description, inputSchema }) => ({
      name,
      description,
      inputSchema,
    })),
    widgets: (validated.widgets ?? []).map((widget) => ({ ...widget })),
  };
}

/**
 * Runs one plugin over TurboCode's stdio JSON-RPC protocol.
 *
 * This is a normal Node process: filesystem, network, subprocesses, and npm
 * dependencies are available. TurboCode-specific state is requested through
 * explicit value-based APIs so the process remains decoupled from Swift
 * objects. The function resolves when the host closes stdin.
 *
 * @param plugin Plugin definition to validate and serve.
 * @returns A promise that resolves after the host closes the plugin input.
 * @throws If plugin startup or message output fails.
 */
export async function runPlugin(plugin: PluginDefinition): Promise<void> {
  const validated = definePlugin(plugin);
  const abortControllers = new Map<JSONRPCID, AbortController>();
  const pending = new Map<
    string,
    { resolve: (value: JSONValue) => void; reject: (error: Error) => void }
  >();
  let nextSessionRequestID = 1;
  let finishInput!: () => void;
  const inputClosed = new Promise<void>((resolve) => {
    finishInput = resolve;
  });
  const input = readline.createInterface({
    input: process.stdin,
    crlfDelay: Infinity,
  });

  const session: PluginSession = {
    transcript: () => {
      const id = `session-${nextSessionRequestID++}`;
      return new Promise<SessionTranscript | null>((resolve, reject) => {
        const key = idKey(id);
        pending.set(key, {
          resolve: (value) => {
            try {
              resolve(value === null ? null : decodeTranscript(value));
            } catch (error) {
              reject(error instanceof Error ? error : new Error(String(error)));
            }
          },
          reject,
        });
        try {
          writeMessage({ jsonrpc: "2.0", id, method: "session/readTranscript" });
        } catch (error) {
          pending.delete(key);
          reject(error instanceof Error ? error : new Error(String(error)));
        }
      });
    },
  };

  input.on("line", (line) => {
    if (line.trim()) void handleMessage(line);
  });
  input.on("close", () => {
    const error = new Error("TurboCode closed the plugin input.");
    for (const request of pending.values()) request.reject(error);
    pending.clear();
    finishInput();
  });

  await inputClosed;

  /** Parses and dispatches one line received from the TurboCode host. */
  async function handleMessage(line: string): Promise<void> {
    let message: JSONRPCRequest | JSONRPCResponse;
    try {
      message = JSON.parse(line) as JSONRPCRequest | JSONRPCResponse;
    } catch {
      writeError(null, -32700, "Malformed JSON-RPC request.");
      return;
    }

    if ("method" in message) {
      await handleHostRequest(message);
      return;
    }
    if (message.id === null || message.id === undefined) return;
    const request = pending.get(idKey(message.id));
    if (!request) return;
    pending.delete(idKey(message.id));
    if (message.error) {
      request.reject(new Error(message.error.message));
    } else {
      request.resolve(message.result ?? null);
    }
  }

  /** Handles one host request and converts failures into JSON-RPC errors. */
  async function handleHostRequest(request: JSONRPCRequest): Promise<void> {
    try {
      if (request.method === "initialize") {
        writeResult(request.id, {
          protocolVersion: PROTOCOL_VERSION,
          pluginID: validated.id,
          nodeVersion: process.version,
          tools: validated.tools.map((tool) => tool.name),
        });
        return;
      }

      if (request.method === "tools/call") {
        const name = request.params?.name;
        const tool = validated.tools.find((candidate) => candidate.name === name);
        if (!tool) {
          writeError(request.id, -32601, `Unknown plugin tool: ${String(name)}.`);
          return;
        }
        const controller = new AbortController();
        abortControllers.set(request.id, controller);
        try {
          const arguments_ = request.params?.arguments;
          const result = await tool.handler(
            isRecord(arguments_) ? arguments_ : {},
            { pluginId: validated.id, signal: controller.signal, session },
          );
          const normalized = typeof result === "string" ? { text: result } : result;
          writeResult(request.id, normalized);
        } finally {
          abortControllers.delete(request.id);
        }
        return;
      }

      if (request.method === "$/cancelRequest") {
        const requestID = request.params?.requestId;
        if (typeof requestID === "string" || typeof requestID === "number") {
          abortControllers.get(requestID)?.abort();
        }
        return;
      }

      writeError(request.id, -32601, `Unsupported method: ${request.method}.`);
    } catch (error) {
      writeError(request.id, -32000, error instanceof Error ? error.message : String(error));
    }
  }
}

/** Validates the shape of a transcript returned by the host. */
function decodeTranscript(value: JSONValue): SessionTranscript {
  if (!isRecord(value) || !Array.isArray(value.entries)) {
    throw new Error("TurboCode returned an invalid session transcript.");
  }
  return value as unknown as SessionTranscript;
}

/** Narrows an unknown JSON value to a non-array object record. */
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Produces a collision-safe map key for a JSON-RPC request identifier. */
function idKey(id: JSONRPCID): string {
  return `${typeof id}:${String(id)}`;
}

/** Writes a successful JSON-RPC response to stdout. */
function writeResult(id: JSONRPCID, result: JSONValue): void {
  writeMessage({ jsonrpc: "2.0", id, result });
}

/** Writes a JSON-RPC error response when the request has an identifier. */
function writeError(id: JSONRPCID | null, code: number, message: string): void {
  if (id === null) return;
  writeMessage({ jsonrpc: "2.0", id, error: { code, message } });
}

/** Serializes one JSON-RPC message as a single stdout line. */
function writeMessage(message: JSONRPCRequest | JSONRPCResponse): void {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}
