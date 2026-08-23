export declare const PROTOCOL_VERSION: 1;
export declare const NODE_ENGINE: ">=24.0.0";
export type JSONValue = null | boolean | number | string | JSONValue[] | {
    [key: string]: JSONValue;
};
/** JSON Schema is passed through to the selected TurboCode provider. */
export type JSONSchema = {
    [key: string]: JSONValue;
};
export type ToolInputSchema = JSONSchema & {
    type: "object";
};
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
export type PluginWidgetDefinition = {
    id: string;
    title: string;
    entrypoint: string;
    description?: string;
};
export type PluginWidgetInvocation = {
    id: string;
    props?: JSONValue;
};
export type PluginToolResult = {
    text: string;
    isError?: boolean;
    widget?: PluginWidgetInvocation;
};
export type PluginToolContext = {
    pluginId: string;
    signal: AbortSignal;
    session: PluginSession;
};
export type PluginToolHandler = (arguments_: Record<string, unknown>, context: PluginToolContext) => PluginToolResult | string | Promise<PluginToolResult | string>;
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
    widgets?: PluginWidgetDefinition[];
};
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
export declare function defineWidget(definition: PluginWidgetDefinition): PluginWidgetDefinition;
export declare function defineTool(definition: PluginToolDefinition): PluginToolDefinition;
export declare function definePlugin(definition: PluginDefinition): PluginDefinition;
export declare function manifestFor(plugin: PluginDefinition, entrypoint: string): PluginManifest;
/**
 * Runs one plugin over TurboCode's stdio JSON-RPC protocol. This is a normal
 * Node process: filesystem, network, subprocesses and npm dependencies are
 * available. TurboCode-specific state is requested through explicit APIs so
 * the process remains decoupled from Swift objects.
 */
export declare function runPlugin(plugin: PluginDefinition): Promise<void>;
