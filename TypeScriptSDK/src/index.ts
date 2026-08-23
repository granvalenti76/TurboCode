import readline from "node:readline";

export const PROTOCOL_VERSION = 1 as const;
export const NODE_ENGINE = ">=24.0.0" as const;

export type JSONValue =
  | null
  | boolean
  | number
  | string
  | JSONValue[]
  | { [key: string]: JSONValue };

/** JSON Schema is passed through to the selected TurboCode provider. */
export type JSONSchema = { [key: string]: JSONValue };
export type ToolInputSchema = JSONSchema & { type: "object" };

export type SessionTranscriptEntry = {
  id: string;
  kind: string;
  text: string;
  createdAt: string;
  model: string | null;
  providerID: string | null;
};

export type SessionTranscript = {
  sessionID: string | null;
  title: string | null;
  updatedAt: string;
  entries: SessionTranscriptEntry[];
};

export type PluginSession = {
  /** Returns a read-only snapshot, or null when no session is active. */
  transcript(): Promise<SessionTranscript | null>;
};

export type PluginToolResult = { text: string; isError?: boolean };

export type PluginToolContext = {
  pluginId: string;
  signal: AbortSignal;
  session: PluginSession;
};

export type PluginToolHandler = (
  arguments_: Record<string, unknown>,
  context: PluginToolContext,
) => PluginToolResult | string | Promise<PluginToolResult | string>;

export type PluginToolDefinition = {
  name: string;
  description: string;
  inputSchema: ToolInputSchema;
  handler: PluginToolHandler;
};

export type PluginDefinition = {
  id: string;
  name: string;
  version: string;
  tools: PluginToolDefinition[];
};

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
};

type JSONRPCID = number | string;
type JSONRPCRequest = {
  jsonrpc: "2.0";
  id: JSONRPCID;
  method: string;
  params?: Record<string, JSONValue>;
};
type JSONRPCResponse = {
  jsonrpc: "2.0";
  id: JSONRPCID | null;
  result?: JSONValue;
  error?: { code: number; message: string };
};

export function defineTool(
  definition: PluginToolDefinition,
): PluginToolDefinition {
  if (!definition.name || !definition.description) {
    throw new Error("A plugin tool needs a name and description.");
  }
  if (definition.inputSchema.type !== "object") {
    throw new Error("Plugin tool schemas must be JSON objects.");
  }
  return definition;
}

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
  return definition;
}

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
  };
}

/**
 * Runs one plugin over TurboCode's stdio JSON-RPC protocol. This is a normal
 * Node process: filesystem, network, subprocesses and npm dependencies are
 * available. TurboCode-specific state is requested through explicit APIs so
 * the process remains decoupled from Swift objects.
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

function decodeTranscript(value: JSONValue): SessionTranscript {
  if (!isRecord(value) || !Array.isArray(value.entries)) {
    throw new Error("TurboCode returned an invalid session transcript.");
  }
  return value as unknown as SessionTranscript;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function idKey(id: JSONRPCID): string {
  return `${typeof id}:${String(id)}`;
}

function writeResult(id: JSONRPCID, result: JSONValue): void {
  writeMessage({ jsonrpc: "2.0", id, result });
}

function writeError(id: JSONRPCID | null, code: number, message: string): void {
  if (id === null) return;
  writeMessage({ jsonrpc: "2.0", id, error: { code, message } });
}

function writeMessage(message: JSONRPCRequest | JSONRPCResponse): void {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}
