import Foundation

import AgentSquad

/// A `ToolProvider` backed by an MCP server, via the `MCPClient` seam (so the SDK never leaks into
/// this layer). Surfaces **MCP Apps UI**: when a tool advertises a `ui://` template, it's fetched
/// lazily (and cached — templates are static) and assembled into a `UIPayload` on the result, with
/// `structuredContent`/`meta` kept out of the model path.
///
/// Connects lazily on first use and holds the connection for its lifetime. Connection lifecycle —
/// including the `disconnect()`+`connect()` re-auth path — is owned by the `MCPClient`.
///
/// Host arguments (context the model can't supply: `session_id`, tenant, …) — see `init(client:hostArguments:)`.
public actor MCPToolProvider: ToolProvider {
    private let client: any MCPClient
    private let hostArguments: [String: JSONValue]
    private var connected = false
    private var toolsByName: [String: MCPToolInfo] = [:]
    private var templateCache: [String: MCPResourceContents] = [:]   // resourceUri → template (static)

    /// - Parameter hostArguments: values the host supplies on every call, keyed by argument name (e.g.
    ///   `["session_id": .string(sessionId)]`). Hiding/injection inspects only the schema's **top-level**
    ///   `properties`/`required` — a key declared solely inside `oneOf`/`allOf`/`$ref`/`$defs` is neither
    ///   hidden nor injected (host arguments are conventionally flat top-level scalars). The value is a
    ///   fixed `JSONValue` for the provider's lifetime; per-turn credential rotation belongs in a
    ///   custom `MCPClient` implementation, not here.
    public init(client: any MCPClient, hostArguments: [String: JSONValue] = [:]) {
        self.client = client
        self.hostArguments = hostArguments
    }

    public func listTools() async throws -> [AgentTool] {
        let infos = try await refreshTools()
        let hidden = Set(hostArguments.keys)
        // Expose only model-visible tools to the agent; app-only tools stay callable for the UI.
        return infos
            .filter { $0.visibility.contains(.model) }
            .map { info in
                AgentTool(
                    name: info.name,
                    description: info.description,
                    // Host arguments are supplied per call, so hide them from the model's schema.
                    inputSchema: hidden.isEmpty ? info.inputSchema : Self.removingProperties(hidden, from: info.inputSchema),
                    ui: info.ui,
                    visibility: info.visibility
                )
            }
    }

    public func call(_ name: String, arguments: JSONValue) async throws -> ToolResult {
        try await ensureConnected()
        // Unknown tool name is a tool-level failure: feed it back to the model, don't throw.
        guard let info = try await toolInfo(name) else {
            return .failure("Tool not found: \(name)")
        }
        let result = try await client.callTool(name: name, arguments: injectingHostArguments(into: arguments, declaredBy: info))
        let structured = result.structuredContent ?? .object([:])

        var ui: UIPayload?
        if let resourceUri = info.ui {
            ui = try await assembleUI(resourceUri: resourceUri, structuredContent: structured, meta: result.meta)
        }
        return ToolResult(content: result.content, structuredContent: structured, ui: ui, isError: result.isError)
    }

    // MARK: - Host arguments

    /// Merge `hostArguments` into a call's arguments, but only the keys the tool's schema declares —
    /// injecting an undeclared field would be rejected by an `additionalProperties: false` schema.
    /// Host values win over any same-named value the model sent (it shouldn't — the key is hidden).
    private func injectingHostArguments(into arguments: JSONValue, declaredBy info: MCPToolInfo) -> JSONValue {
        guard !hostArguments.isEmpty else { return arguments }
        let declared = Self.propertyKeys(of: info.inputSchema)
        let injectable = hostArguments.filter { declared.contains($0.key) }
        guard !injectable.isEmpty else { return arguments }
        var object: [String: JSONValue] = { if case .object(let o) = arguments { return o } else { return [:] } }()
        for (key, value) in injectable { object[key] = value }
        return .object(object)
    }

    /// The property names declared by a JSON-Schema object (its `properties` keys), empty if absent.
    private static func propertyKeys(of schema: JSONValue) -> Set<String> {
        guard case .object(let root) = schema, case .object(let properties) = root["properties"] else { return [] }
        return Set(properties.keys)
    }

    /// Remove `keys` from a JSON-Schema object's `properties` and `required` — so a host-supplied
    /// argument isn't advertised to the model. Leaves the rest of the schema (incl.
    /// `additionalProperties: false`) intact.
    private static func removingProperties(_ keys: Set<String>, from schema: JSONValue) -> JSONValue {
        guard case .object(var root) = schema else { return schema }
        if case .object(var properties) = root["properties"] {
            for key in keys { properties.removeValue(forKey: key) }
            root["properties"] = .object(properties)
        }
        if case .array(let required) = root["required"] {
            root["required"] = .array(required.filter { if case .string(let s) = $0 { return !keys.contains(s) } else { return true } })
        }
        return .object(root)
    }

    // MARK: - Private

    private func ensureConnected() async throws {
        guard !connected else { return }
        try await client.connect()
        connected = true
    }

    /// Connect (if needed), list tools, and rebuild the name→info map.
    @discardableResult
    private func refreshTools() async throws -> [MCPToolInfo] {
        try await ensureConnected()
        let infos = try await client.listTools()
        // MCP tool names are unique per server by spec; a duplicate is a server bug — first wins.
        toolsByName = Dictionary(infos.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return infos
    }

    /// Tool info for `name`, lazily listing first so `call` works even before `listTools`.
    private func toolInfo(_ name: String) async throws -> MCPToolInfo? {
        if toolsByName.isEmpty { try await refreshTools() }
        return toolsByName[name]
    }

    private func assembleUI(
        resourceUri: String,
        structuredContent: JSONValue,
        meta: JSONValue?
    ) async throws -> UIPayload {
        let template = try await cachedTemplate(resourceUri)
        return UIPayload(
            resourceURI: resourceUri,
            mimeType: template.mimeType,
            template: uiTemplate(from: template),
            structuredContent: structuredContent,
            meta: meta,
            security: nil   // parsed by the UI host; nil = unparsed (see SDKMCPClient.readResource)
        )
    }

    private func cachedTemplate(_ uri: String) async throws -> MCPResourceContents {
        if let cached = templateCache[uri] { return cached }
        let contents = try await client.readResource(uri: uri)
        templateCache[uri] = contents
        return contents
    }

    private func uiTemplate(from contents: MCPResourceContents) -> UITemplate? {
        let mime = contents.mimeType.lowercased()
        // A resource may arrive as text or as a base64 blob; decode the blob as UTF-8 markup.
        let body = contents.text ?? contents.blob.flatMap { String(data: $0, encoding: .utf8) }
        guard let body else { return nil }

        if mime.contains("uri-list") {
            return URL(string: body.trimmingCharacters(in: .whitespacesAndNewlines)).map(UITemplate.url)
        }
        if mime.contains("remote-dom") {
            return .remoteDOM(body)
        }
        // text/html;profile=mcp-app, and best-effort fallback for any other text resource.
        return .html(body)
    }
}
