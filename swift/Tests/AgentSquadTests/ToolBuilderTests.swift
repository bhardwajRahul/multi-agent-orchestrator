import Foundation
import Testing

@testable import AgentSquad

/// Records the request and returns a canned response (local to this file).
private final class RecordingInvoker: HTTPInvoker, @unchecked Sendable {
    let response: HTTPToolResponse
    private let lock = NSLock()
    private var _request: URLRequest?
    var request: URLRequest? { lock.withLock { _request } }

    init(status: Int = 200, body: String = "{}") {
        self.response = HTTPToolResponse(status: status, data: Data(body.utf8))
    }

    func send(_ request: URLRequest) async throws -> HTTPToolResponse {
        lock.withLock { _request = request }
        return response
    }
}

private func queryValue(_ request: URLRequest?, _ name: String) -> String? {
    guard let url = request?.url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else { return nil }
    return items.first { $0.name == name }?.value
}

@Suite struct ToolBuilderTests {
    // MARK: - Parameter DSL

    @Test func objectSchemaBuildsPropertiesAndRequired() {
        let schema = [
            ToolParameter.string("city", "City name", required: true),
            ToolParameter.integer("limit"),
            ToolParameter.string("mode", required: false, values: ["fast", "full"]),
        ].objectSchema()

        #expect(schema["type"] == "object")
        #expect(schema["properties"]?["city"] == ["type": "string", "description": "City name"])
        #expect(schema["properties"]?["limit"] == ["type": "integer"])
        #expect(schema["properties"]?["mode"] == ["type": "string", "enum": ["fast", "full"]])
        #expect(schema["required"] == ["city"])               // only the required ones
    }

    @Test func emptyParametersYieldBareObject() {
        #expect([ToolParameter]().objectSchema() == ["type": "object"])
    }

    // MARK: - Method factories

    @Test func getFactoryBuildsSchemaAndMapsQuery() async throws {
        let invoker = RecordingInvoker(status: 200, body: #"{"ok":true}"#)
        let tool = Tool.get(
            "search", "https://api.test/search", "Search.",
            .string("q", required: true),
            invoker: invoker
        )
        // Schema came from the parameter DSL.
        #expect(tool.definition.inputSchema["required"] == ["q"])

        let result = try await tool.run(["q": "swift"])
        #expect(queryValue(invoker.request, "q") == "swift")
        #expect(result.structuredContent == ["ok": true])
    }

    // MARK: - HTTPToolGroup

    @Test func groupMergesBaseURLHeadersAndHostArgs() async throws {
        let invoker = RecordingInvoker(status: 200, body: "{}")
        let api = HTTPToolGroup(
            baseURL: "https://api.test",
            headers: ["X-Match-Id": "42"],
            hostArguments: ["session_id": "s-1"],
            invoker: invoker
        )
        let tool = api.get("lineup", "/odds/{matchId}", "Odds.", .string("matchId", required: true))

        // session_id is hidden from the advertised schema (host argument)…
        #expect(tool.definition.inputSchema["properties"]?["session_id"] == nil)

        _ = try await tool.run(["matchId": "777"])
        #expect(invoker.request?.url?.absoluteString.contains("https://api.test/odds/777") == true)
        #expect(invoker.request?.value(forHTTPHeaderField: "X-Match-Id") == "42")  // shared header
        #expect(queryValue(invoker.request, "session_id") == "s-1")                // injected host arg
    }

    @Test func groupResponseOverridePerEndpoint() async throws {
        // Group default would treat the body as success; the per-call override flags it as an error.
        let invoker = RecordingInvoker(status: 200, body: #"{"error_code":"NOPE","error":"bad"}"#)
        let api = HTTPToolGroup(baseURL: "https://api.test", invoker: invoker)
        let tool = api.get("x", "/x", "X.", response: .jsonEnvelopeError)
        let result = try await tool.run(.object([:]))
        #expect(result.isError)
        if case .text(let message)? = result.content?.first { #expect(message.contains("NOPE")) }
    }

    // MARK: - jsonEnvelope mapping

    @Test func jsonEnvelopeSucceedsWhenNoErrorCode() throws {
        let response = HTTPToolResponse(status: 200, data: Data(#"{"value":7}"#.utf8))
        let result = try ResponseMapping.jsonEnvelopeError.map(response)
        #expect(result.isError == false)
        #expect(result.structuredContent == ["value": 7])
    }

    // MARK: - Output schema

    @Test func outputSchemaIsCarriedButNotInInput() {
        let out: JSONValue = ["type": "object", "properties": ["sum": ["type": "integer"]]]
        let tool = Tool.get("add", "https://api.test/add", "Add.", .integer("a", required: true), outputSchema: out)
        #expect(tool.definition.outputSchema == out)
        #expect(tool.definition.inputSchema["properties"]?["sum"] == nil)   // output isn't mixed into input
    }
}
