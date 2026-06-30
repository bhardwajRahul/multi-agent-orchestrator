import Foundation
import Testing

@testable import AgentSquad

/// Captures the request it's handed and returns a canned response.
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

private func queryValue(_ request: URLRequest?, _ name: String) -> String? {
    guard let url = request?.url,
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
    else { return nil }
    return items.first { $0.name == name }?.value
}

@Suite struct HTTPToolTests {
    // MARK: - Request building helpers

    @Test func templateKeysAreExtractedInOrder() {
        #expect(HTTPToolSpec.templateKeys(in: "https://api/{a}/x/{b}") == ["a", "b"])
        #expect(HTTPToolSpec.templateKeys(in: "https://api/none").isEmpty)
    }

    @Test func pathTemplatingFillsAndConsumesArgs() throws {
        let spec = HTTPToolSpec(method: .get, url: "https://api.test/odds/{matchId}")
        let request = try spec.makeRequest(arguments: ["matchId": "abc 1", "live": true])
        // matchId is consumed by the path (and percent-encoded); `live` becomes a query item.
        // (URL.path returns a decoded path, so assert on the encoded absolute string.)
        #expect(request.url?.absoluteString.contains("/odds/abc%201") == true)
        #expect(queryValue(request, "matchId") == nil)
        #expect(queryValue(request, "live") == "true")
    }

    @Test func pathPlaceholderEncodesSlash() throws {
        // A value containing '/' must not create extra path segments.
        let spec = HTTPToolSpec(method: .get, url: "https://api.test/users/{id}/profile")
        let request = try spec.makeRequest(arguments: ["id": "foo/bar"])
        #expect(request.url?.absoluteString.contains("/users/foo%2Fbar/profile") == true)
    }

    @Test func queryPlaceholderEncodesDelimiters() throws {
        // A value containing '&' or '=' must not create extra query parameters.
        let spec = HTTPToolSpec(method: .get, url: "https://api.test/search?q={query}")
        let request = try spec.makeRequest(arguments: ["query": "a&b=c"])
        let urlString = request.url?.absoluteString ?? ""
        // The '&' and '=' must be percent-encoded so they don't split the query string.
        #expect(urlString.contains("a%26b%3Dc") == true)
        // Only one query item: 'q'
        let components = URLComponents(string: urlString)
        #expect(components?.queryItems?.count == 1)
        #expect(components?.queryItems?.first?.name == "q")
        #expect(components?.queryItems?.first?.value == "a&b=c")
    }

    @Test func postSendsJSONBodyWithContentType() throws {
        let spec = HTTPToolSpec(method: .post, url: "https://api.test/bets")
        let request = try spec.makeRequest(arguments: ["stake": 10, "selection": "home"])
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let decoded = try JSONDecoder().decode(JSONValue.self, from: #require(request.httpBody))
        #expect(decoded == ["stake": 10, "selection": "home"])
    }

    @Test func staticHeadersAndSecretsAreSent() throws {
        let spec = HTTPToolSpec(
            method: .get,
            url: "https://api.test/x",
            headers: ["Accept": "application/json"],
            secrets: ["Authorization": "Bearer tok"]
        )
        let request = try spec.makeRequest(arguments: .object([:]))
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    // MARK: - HTTPToolGroup URL joining

    @Test func groupNormalizesDoubleSlash() async throws {
        // baseURL trailing '/' + path leading '/' must not produce a double slash.
        let invoker = MockInvoker(status: 200, body: "{}")
        let group = HTTPToolGroup(baseURL: "https://api.test/", invoker: invoker)
        let tool = group.get("users", "/users", "")
        _ = try await tool.run(.object([:]))
        #expect(invoker.request?.url?.absoluteString == "https://api.test/users")
    }

    @Test func groupAddsSlashWhenBothMissing() async throws {
        // Neither baseURL nor path has a separator — a '/' must be inserted.
        let invoker = MockInvoker(status: 200, body: "{}")
        let group = HTTPToolGroup(baseURL: "https://api.test", invoker: invoker)
        let tool = group.get("items", "items", "")
        _ = try await tool.run(.object([:]))
        #expect(invoker.request?.url?.absoluteString == "https://api.test/items")
    }

    // MARK: - Host arguments

    @Test func hostArgumentsAreHiddenFromSchemaAndInjected() async throws {
        let invoker = MockInvoker(status: 200, body: "{}")
        let tool = Tool.http(
            name: "get_odds",
            description: "",
            inputSchema: [
                "type": "object",
                "properties": ["matchId": ["type": "string"], "session_id": ["type": "string"]],
                "required": ["matchId", "session_id"],
            ],
            spec: HTTPToolSpec(
                method: .get,
                url: "https://api.test/odds/{matchId}",
                hostArguments: ["session_id": "s-1"],
                invoker: invoker
            )
        )

        // session_id is stripped from the advertised schema…
        guard case .object(let root) = tool.definition.inputSchema,
              case .object(let properties) = root["properties"],
              case .array(let required) = root["required"]
        else { Issue.record("unexpected schema shape"); return }
        #expect(properties["session_id"] == nil)
        #expect(properties["matchId"] != nil)
        #expect(required.contains("session_id") == false)

        // …and injected into the actual request (here, as a query item on a GET).
        _ = try await tool.run(["matchId": "42"])
        #expect(invoker.request?.url?.path == "/odds/42")
        #expect(queryValue(invoker.request, "session_id") == "s-1")
    }

    // MARK: - Response mapping

    @Test func standardMappingParsesJSONOn2xx() throws {
        let response = HTTPToolResponse(status: 200, data: Data(#"{"odds":1.5}"#.utf8))
        let result = try ResponseMapping.standard.map(response)
        #expect(result.isError == false)
        #expect(result.structuredContent == ["odds": 1.5])
    }

    @Test func standardMappingFailsOnNon2xx() throws {
        let response = HTTPToolResponse(status: 404, data: Data("nope".utf8))
        let result = try ResponseMapping.standard.map(response)
        #expect(result.isError)
        if case .text(let message)? = result.content?.first {
            #expect(message.contains("404"))
        } else {
            Issue.record("expected a text error message")
        }
    }

    @Test func endToEndCallMapsResponse() async throws {
        let invoker = MockInvoker(status: 200, body: #"{"tempC":21}"#)
        let tool = Tool.http(
            name: "weather",
            description: "",
            spec: HTTPToolSpec(method: .get, url: "https://api.test/weather", invoker: invoker)
        )
        let result = try await tool.run(["city": "Paris"])
        #expect(result.structuredContent == ["tempC": 21])
        #expect(queryValue(invoker.request, "city") == "Paris")
    }
}
