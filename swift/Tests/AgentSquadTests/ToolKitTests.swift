import Foundation
import Testing

@testable import AgentSquad

@Suite struct ToolKitTests {
    @Test func localToolRuns() async throws {
        let kit = ToolKit([
            .local(name: "echo", description: "echoes") { args in
                ToolResult(content: [.text("got")], structuredContent: args)
            }
        ])
        let result = try await kit.call("echo", arguments: ["x": 1])
        #expect(result.isError == false)
        #expect(result.content == [.text("got")])
        #expect(result.structuredContent == ["x": 1])
    }

    @Test func listToolsHidesAppOnlyButKeepsItCallable() async throws {
        let kit = ToolKit([
            .local(name: "visible", description: "") { _ in ToolResult() },
            .local(name: "app_only", description: "", visibility: .app) { _ in
                ToolResult(structuredContent: ["ran": true])
            },
        ])
        let listed = try await kit.listTools().map(\.name)
        #expect(listed == ["visible"])                          // app-only not advertised to the model

        let result = try await kit.call("app_only", arguments: .object([:]))   // …but still callable
        #expect(result.structuredContent == ["ran": true])
    }

    @Test func unknownToolReturnsFailureNotThrow() async throws {
        let kit = ToolKit([.local(name: "a", description: "") { _ in ToolResult() }])
        let result = try await kit.call("missing", arguments: .object([:]))
        #expect(result.isError)
    }

    @Test func duplicateNamesFirstWins() async throws {
        let kit = ToolKit([
            .local(name: "dup", description: "first") { _ in ToolResult(structuredContent: ["which": "first"]) },
            .local(name: "dup", description: "second") { _ in ToolResult(structuredContent: ["which": "second"]) },
        ])
        #expect(try await kit.listTools().count == 1)
        let result = try await kit.call("dup", arguments: .object([:]))
        #expect(result.structuredContent == ["which": "first"])
    }
}
