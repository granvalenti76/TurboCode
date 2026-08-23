import readline from "node:readline";
export const PROTOCOL_VERSION = 1;
export const NODE_ENGINE = ">=24.0.0";
export function defineWidget(definition) {
    if (!definition.id || !definition.title || !definition.entrypoint) {
        throw new Error("A plugin widget needs an id, title, and entrypoint.");
    }
    return definition;
}
export function defineTool(definition) {
    if (!definition.name || !definition.description) {
        throw new Error("A plugin tool needs a name and description.");
    }
    if (definition.inputSchema.type !== "object") {
        throw new Error("Plugin tool schemas must be JSON objects.");
    }
    return definition;
}
export function definePlugin(definition) {
    if (!definition.id || !definition.name || !definition.version) {
        throw new Error("A plugin needs an id, name, and version.");
    }
    if (definition.tools.length === 0) {
        throw new Error("A plugin needs at least one tool.");
    }
    const names = new Set();
    for (const tool of definition.tools) {
        defineTool(tool);
        if (names.has(tool.name)) {
            throw new Error(`Duplicate plugin tool: ${tool.name}`);
        }
        names.add(tool.name);
    }
    const widgetIDs = new Set();
    for (const widget of definition.widgets ?? []) {
        defineWidget(widget);
        if (widgetIDs.has(widget.id)) {
            throw new Error(`Duplicate plugin widget: ${widget.id}`);
        }
        widgetIDs.add(widget.id);
    }
    return definition;
}
export function manifestFor(plugin, entrypoint) {
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
 * Runs one plugin over TurboCode's stdio JSON-RPC protocol. This is a normal
 * Node process: filesystem, network, subprocesses and npm dependencies are
 * available. TurboCode-specific state is requested through explicit APIs so
 * the process remains decoupled from Swift objects.
 */
export async function runPlugin(plugin) {
    const validated = definePlugin(plugin);
    const abortControllers = new Map();
    const pending = new Map();
    let nextSessionRequestID = 1;
    let finishInput;
    const inputClosed = new Promise((resolve) => {
        finishInput = resolve;
    });
    const input = readline.createInterface({
        input: process.stdin,
        crlfDelay: Infinity,
    });
    const session = {
        transcript: () => {
            const id = `session-${nextSessionRequestID++}`;
            return new Promise((resolve, reject) => {
                const key = idKey(id);
                pending.set(key, {
                    resolve: (value) => {
                        try {
                            resolve(value === null ? null : decodeTranscript(value));
                        }
                        catch (error) {
                            reject(error instanceof Error ? error : new Error(String(error)));
                        }
                    },
                    reject,
                });
                try {
                    writeMessage({ jsonrpc: "2.0", id, method: "session/readTranscript" });
                }
                catch (error) {
                    pending.delete(key);
                    reject(error instanceof Error ? error : new Error(String(error)));
                }
            });
        },
    };
    input.on("line", (line) => {
        if (line.trim())
            void handleMessage(line);
    });
    input.on("close", () => {
        const error = new Error("TurboCode closed the plugin input.");
        for (const request of pending.values())
            request.reject(error);
        pending.clear();
        finishInput();
    });
    await inputClosed;
    async function handleMessage(line) {
        let message;
        try {
            message = JSON.parse(line);
        }
        catch {
            writeError(null, -32700, "Malformed JSON-RPC request.");
            return;
        }
        if ("method" in message) {
            await handleHostRequest(message);
            return;
        }
        if (message.id === null || message.id === undefined)
            return;
        const request = pending.get(idKey(message.id));
        if (!request)
            return;
        pending.delete(idKey(message.id));
        if (message.error) {
            request.reject(new Error(message.error.message));
        }
        else {
            request.resolve(message.result ?? null);
        }
    }
    async function handleHostRequest(request) {
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
                    const result = await tool.handler(isRecord(arguments_) ? arguments_ : {}, { pluginId: validated.id, signal: controller.signal, session });
                    const normalized = typeof result === "string" ? { text: result } : result;
                    writeResult(request.id, normalized);
                }
                finally {
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
        }
        catch (error) {
            writeError(request.id, -32000, error instanceof Error ? error.message : String(error));
        }
    }
}
function decodeTranscript(value) {
    if (!isRecord(value) || !Array.isArray(value.entries)) {
        throw new Error("TurboCode returned an invalid session transcript.");
    }
    return value;
}
function isRecord(value) {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}
function idKey(id) {
    return `${typeof id}:${String(id)}`;
}
function writeResult(id, result) {
    writeMessage({ jsonrpc: "2.0", id, result });
}
function writeError(id, code, message) {
    if (id === null)
        return;
    writeMessage({ jsonrpc: "2.0", id, error: { code, message } });
}
function writeMessage(message) {
    process.stdout.write(`${JSON.stringify(message)}\n`);
}
