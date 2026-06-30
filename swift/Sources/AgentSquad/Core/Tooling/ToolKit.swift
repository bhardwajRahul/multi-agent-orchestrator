import Foundation

/// A ``ToolProvider`` over a fixed set of ``Tool``s (local, HTTP, or a mix). Immutable and `Sendable`.
/// Duplicate names keep the first (first-wins). Compose with other providers via ``AggregateToolProvider``.
public struct ToolKit: ToolProvider {
    private let order: [String]                 // declaration order, for stable listTools output
    private let toolsByName: [String: Tool]

    public init(_ tools: [Tool]) {
        var byName: [String: Tool] = [:]
        var order: [String] = []
        for tool in tools where byName[tool.definition.name] == nil {   // first wins
            byName[tool.definition.name] = tool
            order.append(tool.definition.name)
        }
        self.toolsByName = byName
        self.order = order
    }

    /// Variadic convenience: `ToolKit(toolA, toolB, toolC)`.
    public init(_ tools: Tool...) { self.init(tools) }

    /// Model-visible tools only; app-only tools stay callable but unadvertised.
    public func listTools() async throws -> [AgentTool] {
        order.compactMap { toolsByName[$0]?.definition }
            .filter { $0.visibility.contains(.model) }
    }

    public func call(_ name: String, arguments: JSONValue) async throws -> ToolResult {
        guard let tool = toolsByName[name] else { return .failure("Tool not found: \(name)") }
        return try await tool.run(arguments)
    }
}
