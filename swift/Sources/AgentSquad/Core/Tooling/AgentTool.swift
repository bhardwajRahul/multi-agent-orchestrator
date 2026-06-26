import Foundation

/// Who may invoke a tool (MCP Apps `visibility`): a tool the model can't see is never offered to it.
public struct ToolVisibility: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let model = ToolVisibility(rawValue: 1 << 0)
    public static let app = ToolVisibility(rawValue: 1 << 1)
    /// The default — both the model and the component may call the tool.
    public static let all: ToolVisibility = [.model, .app]
}

/// A tool an agent can call. Provider-agnostic (MCP or native Swift); `Hashable` so merged tool
/// lists dedupe by identity.
public struct AgentTool: Sendable, Equatable, Hashable {
    public let name: String
    public let description: String
    /// JSON Schema for the arguments.
    public let inputSchema: JSONValue
    /// The `ui://` resource a tool advertises for its result (MCP Apps); `nil` if it has no UI.
    public let ui: String?
    public let visibility: ToolVisibility

    public init(
        name: String,
        description: String,
        inputSchema: JSONValue = .object(["type": "object"]),
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
