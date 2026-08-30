/** Version of the JSON-RPC contract understood by the TurboCode host. */
export declare const PROTOCOL_VERSION: 1;
/** Minimum Node.js engine required by the plugin runtime. */
export declare const NODE_ENGINE: ">=24.0.0";
/** Recursive set of values that can cross the JSON-RPC boundary. */
export type JSONValue = null | boolean | number | string | JSONValue[] | {
    [key: string]: JSONValue;
};
/** JSON Schema passed through to the selected TurboCode provider. */
export type JSONSchema = {
    [key: string]: JSONValue;
};
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
export type PluginToolHandler = (arguments_: Record<string, unknown>, context: PluginToolContext) => PluginToolResult | string | Promise<PluginToolResult | string>;
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
    runtime: {
        kind: "node";
        node: ">=24.0.0";
    };
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
export declare function defineWidget(definition: PluginWidgetDefinition): PluginWidgetDefinition;
/**
 * Validates and returns a plugin tool definition.
 *
 * @param definition Tool metadata and handler to validate.
 * @returns The same definition after validation.
 * @throws If required metadata or the cross-provider input schema contract is
 * missing.
 */
export declare function defineTool(definition: PluginToolDefinition): PluginToolDefinition;
/**
 * Validates a complete plugin definition, including unique tool and widget ids.
 *
 * @param definition Plugin metadata, tools, and optional widgets to validate.
 * @returns The same definition after validation.
 * @throws If required metadata is missing, no tools are registered, or an id is duplicated.
 */
export declare function definePlugin(definition: PluginDefinition): PluginDefinition;
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
export declare function manifestFor(plugin: PluginDefinition, entrypoint: string): PluginManifest;
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
export declare function runPlugin(plugin: PluginDefinition): Promise<void>;
