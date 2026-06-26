import Foundation

import AgentSquad

/// Client-level seam the `MCPToolProvider` depends on — exactly the MCP operations it needs,
/// decoupled from the underlying SDK. `SDKMCPClient` wraps the official MCP Swift SDK; a mock backs
/// tests. The remote/local distinction (HTTP vs stdio transport) is a property of the concrete
/// client, so it never reaches the `ToolProvider` surface.
public protocol MCPClient: Sendable {
    /// Connect and perform the MCP `initialize` handshake.
    func connect() async throws
    func listTools() async throws -> [MCPToolInfo]
    func callTool(name: String, arguments: JSONValue) async throws -> MCPCallResult
    /// Read a `ui://` (or any) resource — used to fetch an advertised UI template.
    func readResource(uri: String) async throws -> MCPResourceContents
    func disconnect() async
}

/// A tool as advertised by an MCP server, with MCP Apps UI metadata surfaced.
public struct MCPToolInfo: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    /// `_meta.ui.resourceUri` (or the OpenAI `openai/outputTemplate` alias); `nil` if no UI.
    public let ui: String?
    public let visibility: ToolVisibility

    public init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        ui: String? = nil,
        visibility: ToolVisibility = .all
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.ui = ui
        self.visibility = visibility
    }
}

/// The result of an MCP `tools/call`, split per MCP semantics.
public struct MCPCallResult: Sendable {
    public let content: [ContentPart]?      // text representation → model context
    /// data → curator / UI hydration (not modelled). Optional: `nil` distinguishes "the tool
    /// returned no structured content" from an empty `{}`. The boundary defaults it to `{}`.
    public let structuredContent: JSONValue?
    public let meta: JSONValue?             // `_meta` → UI only, never modelled
    public let isError: Bool

    public init(
        content: [ContentPart]? = nil,
        structuredContent: JSONValue? = nil,
        meta: JSONValue? = nil,
        isError: Bool = false
    ) {
        self.content = content
        self.structuredContent = structuredContent
        self.meta = meta
        self.isError = isError
    }
}

/// The contents of an MCP resource (e.g. a `ui://` UI template).
public struct MCPResourceContents: Sendable {
    public let mimeType: String
    public let text: String?
    public let blob: Data?
    /// `_meta.ui` of the resource (csp / permissions / domain / prefersBorder).
    public let meta: JSONValue?

    public init(mimeType: String, text: String? = nil, blob: Data? = nil, meta: JSONValue? = nil) {
        self.mimeType = mimeType
        self.text = text
        self.blob = blob
        self.meta = meta
    }
}
