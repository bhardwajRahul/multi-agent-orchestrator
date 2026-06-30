import Foundation
import Testing

@testable import AgentSquad

@Suite struct AggregateToolProviderTests {
    @Test func mergesToolsFromAllProviders() async throws {
        let a = StubToolProvider(tool: AgentTool(name: "a", description: ""), result: ToolResult())
        let b = StubToolProvider(tool: AgentTool(name: "b", description: ""), result: ToolResult())
        let names = try await AggregateToolProvider([a, b]).listTools().map(\.name).sorted()
        #expect(names == ["a", "b"])
    }

    @Test func duplicateNamesFirstProviderWins() async throws {
        let first = StubToolProvider(tool: AgentTool(name: "dup", description: "first"), result: ToolResult(structuredContent: ["p": "first"]))
        let second = StubToolProvider(tool: AgentTool(name: "dup", description: "second"), result: ToolResult(structuredContent: ["p": "second"]))
        let aggregate = AggregateToolProvider([first, second])

        let listed = try await aggregate.listTools()
        #expect(listed.count == 1)
        #expect(listed.first?.description == "first")

        let result = try await aggregate.call("dup", arguments: .object([:]))
        #expect(result.structuredContent == ["p": "first"])
        #expect(second.callCount == 0)               // routed to the first provider only
    }

    @Test func routesCallToOwningProvider() async throws {
        let a = StubToolProvider(tool: AgentTool(name: "a", description: ""), result: ToolResult(structuredContent: ["from": "a"]))
        let b = StubToolProvider(tool: AgentTool(name: "b", description: ""), result: ToolResult(structuredContent: ["from": "b"]))
        let aggregate = AggregateToolProvider([a, b])

        let result = try await aggregate.call("b", arguments: .object([:]))
        #expect(result.structuredContent == ["from": "b"])
        #expect(a.callCount == 0)
        #expect(b.callCount == 1)
    }

    @Test func unknownToolReturnsFailure() async throws {
        let a = StubToolProvider(tool: AgentTool(name: "a", description: ""), result: ToolResult())
        let result = try await AggregateToolProvider([a]).call("missing", arguments: .object([:]))
        #expect(result.isError)
    }

    @Test func callBuildsRoutingWithoutExplicitListTools() async throws {
        // call() before listTools() should still route (it lazily lists).
        let a = StubToolProvider(tool: AgentTool(name: "solo", description: ""), result: ToolResult(structuredContent: ["ok": true]))
        let result = try await AggregateToolProvider([a]).call("solo", arguments: .object([:]))
        #expect(result.structuredContent == ["ok": true])
    }

    @Test func appOnlyToolIsCallableThroughAggregate() async throws {
        // An app-only tool is excluded from listTools() but must still be callable via call().
        let kit = ToolKit([
            .local(name: "visible", description: "") { _ in ToolResult() },
            .local(name: "app_only", description: "", visibility: .app) { _ in
                ToolResult(structuredContent: ["ran": true])
            },
        ])
        let aggregate = AggregateToolProvider([kit])

        // listTools() must not advertise the app-only tool to the model.
        let listed = try await aggregate.listTools().map(\.name)
        #expect(listed == ["visible"])

        // call() must still reach the app-only tool.
        let result = try await aggregate.call("app_only", arguments: .object([:]))
        #expect(result.isError == false)
        #expect(result.structuredContent == ["ran": true])
    }

    @Test func emptyProvidersHasStableRoutingState() async throws {
        // An aggregate over zero-tool providers must not re-call listTools() on every call().
        let empty = StubToolProvider(tools: [], results: [:])
        let aggregate = AggregateToolProvider([empty])
        _ = try await aggregate.listTools()
        // Calling an unknown tool after listTools() must return failure without re-listing.
        let result = try await aggregate.call("ghost", arguments: .object([:]))
        #expect(result.isError)
    }
}
