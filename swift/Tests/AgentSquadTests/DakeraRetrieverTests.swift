import Foundation
import Testing

@testable import AgentSquad

/// Captures the request it's handed and returns a canned response (mirrors HTTPToolTests).
private final class MockInvoker: HTTPInvoker, @unchecked Sendable {
    let response: HTTPToolResponse
    private let lock = NSLock()
    private var _request: URLRequest?
    var request: URLRequest? { lock.withLock { _request } }

    init(status: Int = 200, body: String = "", headers: [String: String] = [:]) {
        self.response = HTTPToolResponse(status: status, data: Data(body.utf8), headers: headers)
    }

    func send(_ request: URLRequest) async throws -> HTTPToolResponse {
        lock.withLock { _request = request }
        return response
    }
}

/// A `TextQueryResponse` body with two hits — the shape `/query-text` returns.
private let twoResults = """
{
  "results": [
    { "id": "m1", "score": 0.92, "text": "User prefers concise answers", "metadata": { "topic": "prefs" } },
    { "id": "m2", "score": 0.81, "text": "User is based in Berlin" }
  ],
  "model": "minilm",
  "embedding_time_ms": 3,
  "search_time_ms": 1
}
"""

@Suite struct DakeraRetrieverTests {
    private func retriever(_ invoker: MockInvoker, topK: Int = 10, filter: JSONValue? = nil) -> DakeraRetriever {
        DakeraRetriever(
            DakeraRetrieverOptions(
                namespace: "agent-mem", apiKey: "dk-test", url: "http://localhost:3000", topK: topK, filter: filter
            ),
            invoker: invoker
        )
    }

    // MARK: - Request building

    @Test func retrievePostsToQueryTextEndpointWithKeyHeader() async throws {
        let invoker = MockInvoker(body: twoResults)
        _ = try await retriever(invoker).retrieve("what does the user prefer?")

        let request = invoker.request
        #expect(request?.httpMethod == "POST")
        #expect(request?.url?.absoluteString == "http://localhost:3000/v1/namespaces/agent-mem/query-text")
        #expect(request?.value(forHTTPHeaderField: "X-API-Key") == "dk-test")
        #expect(request?.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func requestBodyCarriesTextTopKAndFilter() async throws {
        let invoker = MockInvoker(body: twoResults)
        let filter: JSONValue = ["topic": "prefs"]
        _ = try await retriever(invoker, topK: 3, filter: filter).retrieve("prefs?")

        let body = try #require(invoker.request?.httpBody)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: body)
        #expect(decoded["text"]?.stringValue == "prefs?")
        #expect(decoded["top_k"]?.intValue == 3)
        #expect(decoded["include_text"]?.boolValue == true)
        #expect(decoded["filter"] == filter)
    }

    @Test func trailingSlashInURLIsNormalized() async throws {
        let invoker = MockInvoker(body: twoResults)
        let retriever = DakeraRetriever(
            DakeraRetrieverOptions(namespace: "ns", apiKey: "dk", url: "http://host:3000/"), invoker: invoker
        )
        _ = try await retriever.retrieve("q")
        #expect(invoker.request?.url?.absoluteString == "http://host:3000/v1/namespaces/ns/query-text")
    }

    // MARK: - Response parsing

    @Test func retrieveParsesResultsInOrder() async throws {
        let documents = try await retriever(MockInvoker(body: twoResults)).retrieve("q")
        #expect(documents.count == 2)
        #expect(documents[0].id == "m1")
        #expect(documents[0].content == "User prefers concise answers")
        #expect(documents[0].score == 0.92)
        #expect(documents[0].metadata["topic"]?.stringValue == "prefs")
        #expect(documents[1].id == "m2")
        #expect(documents[1].content == "User is based in Berlin")
    }

    @Test func numericIdIsCoercedToString() throws {
        let body = #"{ "results": [ { "id": 42, "score": 0.5, "text": "x" } ] }"#
        let documents = try DakeraRetriever.parse(Data(body.utf8))
        #expect(documents.first?.id == "42")
    }

    @Test func retrieveAndCombineJoinsTextDroppingEmpties() async throws {
        let body = #"{ "results": [ { "id": "a", "score": 1, "text": "one" }, { "id": "b", "score": 1 }, { "id": "c", "score": 1, "text": "two" } ] }"#
        let combined = try await retriever(MockInvoker(body: body)).retrieveAndCombineResults("q")
        #expect(combined == "one\ntwo")
    }

    // MARK: - Validation & errors

    @Test func blankQueryReturnsEmptyWithoutCallingServer() async throws {
        let invoker = MockInvoker(body: twoResults)
        let documents = try await retriever(invoker).retrieve("   ")
        #expect(documents.isEmpty)
        #expect(invoker.request == nil)
    }

    @Test func missingAPIKeyThrows() async {
        let retriever = DakeraRetriever(
            DakeraRetrieverOptions(namespace: "ns", apiKey: "", url: "http://localhost:3000"),
            invoker: MockInvoker(body: twoResults)
        )
        await #expect(throws: DakeraRetrieverError.missingAPIKey) { try await retriever.retrieve("q") }
    }

    @Test func emptyNamespaceThrows() async {
        let retriever = DakeraRetriever(
            DakeraRetrieverOptions(namespace: "", apiKey: "dk", url: "http://localhost:3000"),
            invoker: MockInvoker(body: twoResults)
        )
        await #expect(throws: DakeraRetrieverError.missingNamespace) { try await retriever.retrieve("q") }
    }

    @Test func serverErrorStatusThrows() async {
        let retriever = retriever(MockInvoker(status: 401, body: "unauthorized"))
        await #expect(throws: DakeraRetrieverError.self) { try await retriever.retrieve("q") }
    }

    // MARK: - ToolProvider

    @Test func listToolsAdvertisesSearchMemory() async throws {
        let tools = try await retriever(MockInvoker(body: twoResults)).listTools()
        #expect(tools.count == 1)
        #expect(tools.first?.name == "search_memory")
        // Schema requires a `query` string.
        #expect(tools.first?.inputSchema["properties"]?["query"]?["type"]?.stringValue == "string")
        #expect(tools.first?.inputSchema["required"]?[0]?.stringValue == "query")
    }

    @Test func callReturnsCombinedTextAndStructuredResults() async throws {
        let result = try await retriever(MockInvoker(body: twoResults)).call("search_memory", arguments: ["query": "prefs"])
        #expect(result.isError == false)
        #expect(result.content == [.text("User prefers concise answers\nUser is based in Berlin")])
        // Structured content preserves per-result data for curators / UIs.
        #expect(result.structuredContent["results"]?[0]?["id"]?.stringValue == "m1")
        #expect(result.structuredContent["results"]?[0]?["score"]?.doubleValue == 0.92)
    }

    @Test func callWithNoHitsReturnsFriendlyMessage() async throws {
        let result = try await retriever(MockInvoker(body: #"{ "results": [] }"#)).call("search_memory", arguments: ["query": "x"])
        #expect(result.isError == false)
        #expect(result.content == [.text("No relevant documents found.")])
    }

    @Test func callWithMissingQueryIsToolError() async throws {
        let result = try await retriever(MockInvoker(body: twoResults)).call("search_memory", arguments: ["query": ""])
        #expect(result.isError == true)
    }

    @Test func callUnknownToolIsError() async throws {
        let result = try await retriever(MockInvoker(body: twoResults)).call("nope", arguments: ["query": "x"])
        #expect(result.isError == true)
    }

    @Test func retrievalFailureBecomesToolError() async throws {
        let result = try await retriever(MockInvoker(status: 500, body: "boom")).call("search_memory", arguments: ["query": "x"])
        #expect(result.isError == true)
    }
}
