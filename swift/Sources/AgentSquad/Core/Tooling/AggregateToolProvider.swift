import Foundation

/// Composes several ``ToolProvider``s (local, HTTP, MCP) behind one. `listTools` fans out in parallel
/// and merges first-wins by name; `call` routes to the owning provider.
public actor AggregateToolProvider: ToolProvider {
    private let providers: [any ToolProvider]
    private var routing: [String: Int] = [:]   // tool name → index into `providers`

    public init(_ providers: [any ToolProvider]) {
        self.providers = providers
    }

    /// Variadic convenience: `AggregateToolProvider(toolKit, mcpServer)`.
    public init(_ providers: any ToolProvider...) { self.init(providers) }

    public func listTools() async throws -> [AgentTool] {
        // One provider throwing fails the whole list — we don't silently drop a provider's tools.
        let byIndex = try await withThrowingTaskGroup(of: (Int, [AgentTool]).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask { (index, try await provider.listTools()) }
            }
            var collected: [Int: [AgentTool]] = [:]
            for try await (index, tools) in group { collected[index] = tools }
            return collected
        }

        // Merge in provider order so first-wins is deterministic; rebuild routing.
        var seen = Set<String>()
        var merged: [AgentTool] = []
        var routing: [String: Int] = [:]
        for index in providers.indices {
            for tool in byIndex[index] ?? [] where !seen.contains(tool.name) {
                seen.insert(tool.name)
                merged.append(tool)
                routing[tool.name] = index
            }
        }
        self.routing = routing
        return merged
    }

    public func call(_ name: String, arguments: JSONValue) async throws -> ToolResult {
        // Build the routing map on first use (an agent normally calls listTools first anyway).
        if routing.isEmpty { _ = try await listTools() }
        guard let index = routing[name] else { return .failure("Tool not found: \(name)") }
        return try await providers[index].call(name, arguments: arguments)
    }
}
