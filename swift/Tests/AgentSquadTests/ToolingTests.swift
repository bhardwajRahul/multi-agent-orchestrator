import Foundation
import Testing

@testable import AgentSquad

@Suite struct ToolingTests {
    /// A provider with one `known` tool returning data; anything else is a not-found error result.
    private func provider() -> StubToolProvider {
        StubToolProvider(tool: AgentTool(name: "known", description: ""), result: ToolResult(structuredContent: ["ok": true]))
    }

    @Test func visibilityGating() {
        #expect(ToolVisibility.all.contains(.model))
        #expect(ToolVisibility.all.contains(.app))
        #expect(ToolVisibility.app.contains(.model) == false)
    }

    @Test func toolDefaultsAreModelAndAppVisible() {
        let tool = AgentTool(name: "get_odds", description: "1X2 odds")
        #expect(tool.visibility == .all)
        #expect(tool.ui == nil)
    }

    @Test func appOnlyToolIsHiddenFromModel() {
        let refresh = AgentTool(name: "refresh", description: "", visibility: .app)
        #expect(refresh.visibility.contains(.model) == false)
        #expect(refresh.visibility.contains(.app))
    }

    // A tool visible to neither is representable; downstream registration is expected to filter it.
    @Test func emptyVisibilityIsRepresentable() {
        let orphan = AgentTool(name: "orphan", description: "", visibility: [])
        #expect(orphan.visibility.contains(.model) == false)
        #expect(orphan.visibility.contains(.app) == false)
    }

    @Test func resultCanCarryAUIPayloadAlongsideContent() {
        let payload = UIPayload(resourceURI: "ui://sport/matches", mimeType: "text/html;profile=mcp-app")
        let result = ToolResult(
            content: [.text("Matches ready.")],
            structuredContent: ["count": 3],
            ui: payload
        )
        #expect(result.ui == payload)
        #expect(result.content == [.text("Matches ready.")])
        #expect(result.structuredContent == ["count": 3])
        #expect(result.isError == false)
    }

    @Test func failureFactoryMarksError() {
        let result = ToolResult.failure("boom")
        #expect(result.isError)
        #expect(result.content == [.text("boom")])
    }

    @Test func unknownToolReturnsErrorResultNotThrow() async throws {
        let result = try await provider().call("missing", arguments: .object([:]))
        #expect(result.isError)
    }

    @Test func knownToolReturnsData() async throws {
        let result = try await provider().call("known", arguments: .object([:]))
        #expect(result.isError == false)
        #expect(result.structuredContent == ["ok": true])
    }
}
