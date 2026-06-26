import Foundation

/// A source of tools an agent can call — MCP, native Swift, or several composed, behind one seam.
public protocol ToolProvider: Sendable {
    /// The tools this provider offers; names are unique within the returned list.
    func listTools() async throws -> [AgentTool]

    /// Run one tool. Tool-level failures come back as a `ToolResult` with `isError == true` (the
    /// agent feeds it to the model and keeps going); `throws` is reserved for infrastructure
    /// failures (transport / protocol) that abort the call.
    func call(_ name: String, arguments: JSONValue) async throws -> ToolResult
}

/// The result of calling a tool. `content` is the only part added to the model's context.
public struct ToolResult: Sendable, Equatable {
    /// Text representation added to the model's context.
    public let content: [ContentPart]?
    /// The tool's structured data — what a curator/presenter curates from and what a UI hydrates
    /// from; not added to the model context (mirrors MCP `structuredContent`). When `ui != nil`
    /// this is the source of truth; `ui.structuredContent` is a copy for the widget.
    public let structuredContent: JSONValue
    /// A self-contained widget package when the tool advertised a UI; `nil` otherwise.
    public let ui: UIPayload?
    /// True when the call failed at the tool level — surfaced to the model so the loop continues.
    public let isError: Bool

    public init(
        content: [ContentPart]? = nil,
        structuredContent: JSONValue = .object([:]),
        ui: UIPayload? = nil,
        isError: Bool = false
    ) {
        self.content = content
        self.structuredContent = structuredContent
        self.ui = ui
        self.isError = isError
    }

    /// A tool-level error result the agent can feed back to the model (e.g. "tool not found").
    public static func failure(_ message: String) -> ToolResult {
        ToolResult(
            content: [.text(message)],
            structuredContent: .object(["error": .string(message)]),
            isError: true
        )
    }
}
