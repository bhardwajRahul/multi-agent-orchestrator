import Foundation
import Testing

@testable import AgentSquad

// MARK: - Stream collection

/// Drains an agent event stream into an array.
func collect(_ stream: AsyncThrowingStream<AgentEvent, any Error>) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

/// The text of the last `.final` message in a run, if any.
func finalText(_ events: [AgentEvent]) -> String? {
    for case .final(let message) in events.reversed() {
        return message.parts.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
    }
    return nil
}

/// A throwaway directory under the system temp, unique per call.
func tempDirectory(prefix: String = "agentsquad-tests") -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
}

// MARK: - Tool provider stub

/// Returns a fixed tool list and a scripted result per tool name, recording how many times it was
/// called. Unknown tools return an error result (not a throw), mirroring a real provider.
final class StubToolProvider: ToolProvider, @unchecked Sendable {
    let toolList: [AgentTool]
    let results: [String: ToolResult]
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.withLock { _callCount } }

    init(tools: [AgentTool], results: [String: ToolResult]) {
        self.toolList = tools
        self.results = results
    }

    /// Convenience for the single-tool, single-result case.
    convenience init(tool: AgentTool, result: ToolResult) {
        self.init(tools: [tool], results: [tool.name: result])
    }

    func listTools() async throws -> [AgentTool] { toolList }
    func call(_ name: String, arguments: JSONValue) async throws -> ToolResult {
        lock.withLock { _callCount += 1 }
        return results[name] ?? .failure("no tool \(name)")
    }
}

// MARK: - LLM client stub

/// An `LLMClient` that fails, to exercise the throwing path. Optionally emits a leading delta before
/// the failure (to exercise the fail-mid-stream case).
struct FailingLLMClient: LLMClient {
    struct Boom: Error {}
    let leadingDelta: String?
    init(leadingDelta: String? = nil) { self.leadingDelta = leadingDelta }
    func complete(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            if let leadingDelta { continuation.yield(.textDelta(leadingDelta)) }
            continuation.finish(throwing: Boom())
        }
    }
}

// MARK: - Event-kind predicates

extension AgentEvent {
    var isFinal: Bool { if case .final = self { return true } else { return false } }
    var isToolCall: Bool { if case .toolCall = self { return true } else { return false } }
    var isWidget: Bool { if case .widget = self { return true } else { return false } }
    var isError: Bool { if case .error = self { return true } else { return false } }
}

extension RealtimeEvent {
    var isAudio: Bool { if case .audio = self { return true } else { return false } }
}

extension Array where Element == AgentEvent {
    func count(ofKind predicate: (AgentEvent) -> Bool) -> Int { lazy.filter(predicate).count }
}
