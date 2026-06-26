import Foundation

/// A `ToolProvider` decorator that records every tool result passing through, so `GroundedAgent` can
/// curate the presenter feed from `captured`. One per turn — the capture is per-turn state.
actor CapturingToolProvider: ToolProvider {
    private let wrapped: any ToolProvider
    private(set) var captured: [CapturedCall] = []

    init(_ wrapped: any ToolProvider) {
        self.wrapped = wrapped
    }

    func listTools() async throws -> [AgentTool] {
        try await wrapped.listTools()
    }

    func call(_ name: String, arguments: JSONValue) async throws -> ToolResult {
        let result = try await wrapped.call(name, arguments: arguments)
        captured.append(CapturedCall(name: name, result: result))
        return result
    }
}
