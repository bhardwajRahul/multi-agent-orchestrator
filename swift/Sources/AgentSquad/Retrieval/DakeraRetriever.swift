import Foundation

// A `ToolProvider` backed by a self-hosted Dakera memory server. Unlike the Python/TypeScript
// `Retriever` base class, the Swift SDK grounds answers through tools (see `GroundedAgent`), so
// retrieval is exposed the native way: a `search_memory` tool the gatherer can call. The same type
// also offers a direct `retrieve(_:)` API for manual RAG. It talks to Dakera's REST API over
// `URLSession` (no third-party SDK dependency), so nothing new is pulled into the package.

/// One document returned by a Dakera text query (the server's `TextSearchResult`).
public struct DakeraDocument: Sendable, Equatable {
    /// The stored document's vector id.
    public let id: String
    /// The document text, or empty when the match had no stored text.
    public let content: String
    /// Similarity score; higher is more relevant.
    public let score: Double
    /// Any metadata the document was stored with.
    public let metadata: JSONValue

    public init(id: String, content: String, score: Double, metadata: JSONValue = .object([:])) {
        self.id = id
        self.content = content
        self.score = score
        self.metadata = metadata
    }
}

/// Configuration for ``DakeraRetriever``.
public struct DakeraRetrieverOptions: Sendable {
    /// The Dakera namespace to query.
    public var namespace: String
    /// API key (a `dk-...` token). Falls back to the `DAKERA_API_KEY` environment variable.
    public var apiKey: String?
    /// Base URL of the Dakera server. Falls back to `DAKERA_URL`, then `http://localhost:3000`
    /// (the `dakera-deploy` default).
    public var url: String
    /// Maximum number of results to return. Defaults to 10.
    public var topK: Int
    /// Optional Dakera metadata filter passed straight through to the query.
    public var filter: JSONValue?
    /// Request timeout, in seconds. Defaults to 30.
    public var timeout: TimeInterval
    /// The name the retrieval tool is advertised under to the model.
    public var toolName: String
    /// The description the retrieval tool is advertised with to the model.
    public var toolDescription: String

    public init(
        namespace: String,
        apiKey: String? = nil,
        url: String? = nil,
        topK: Int = 10,
        filter: JSONValue? = nil,
        timeout: TimeInterval = 30,
        toolName: String = "search_memory",
        toolDescription: String =
            "Search long-term memory for documents relevant to a natural-language query. "
            + "Returns the most relevant stored text; call it before answering questions that may "
            + "rely on remembered facts."
    ) {
        self.namespace = namespace
        self.apiKey = apiKey ?? ProcessInfo.processInfo.environment["DAKERA_API_KEY"]
        self.url = url ?? ProcessInfo.processInfo.environment["DAKERA_URL"] ?? "http://localhost:3000"
        self.topK = topK
        self.filter = filter
        self.timeout = timeout
        self.toolName = toolName
        self.toolDescription = toolDescription
    }
}

/// Failures raised by ``DakeraRetriever/retrieve(_:)``. In the tool path these are turned into a
/// tool-level `ToolResult` so the agent loop keeps going; direct callers get the typed error.
public enum DakeraRetrieverError: Error, Sendable, Equatable {
    /// `options.namespace` was empty.
    case missingNamespace
    /// No API key in `options.apiKey` or the `DAKERA_API_KEY` environment variable.
    case missingAPIKey
    /// `options.url` could not be turned into a request URL.
    case invalidURL(String)
    /// The server returned a non-2xx status.
    case server(status: Int, message: String)
    /// The response body was not the expected shape.
    case decoding(String)
}

/// Retriever backed by a self-hosted [Dakera](https://dakera.ai) memory server.
///
/// It uses Dakera's text-query endpoint (server-side embedding) to fetch the documents most
/// relevant to a query. Use it two ways:
///
/// - **As a tool provider** — hand it to an ``Agent`` or ``GroundedAgent`` and the model can call
///   `search_memory` to ground its answers on remembered facts.
/// - **Directly** — call ``retrieve(_:)`` / ``retrieveAndCombineResults(_:separator:)`` to fetch
///   context yourself and inject it however you like.
///
/// The transport is `URLSession` behind the ``HTTPInvoker`` seam, so tests inject a mock and no
/// third-party SDK is added to the package.
public struct DakeraRetriever: Sendable {
    public let options: DakeraRetrieverOptions
    private let invoker: any HTTPInvoker

    public init(_ options: DakeraRetrieverOptions, invoker: any HTTPInvoker = URLSessionInvoker()) {
        self.options = options
        self.invoker = invoker
    }

    /// Convenience initializer for the common case.
    public init(
        namespace: String,
        apiKey: String? = nil,
        url: String? = nil,
        topK: Int = 10,
        filter: JSONValue? = nil,
        invoker: any HTTPInvoker = URLSessionInvoker()
    ) {
        self.init(
            DakeraRetrieverOptions(namespace: namespace, apiKey: apiKey, url: url, topK: topK, filter: filter),
            invoker: invoker
        )
    }

    // MARK: - Direct retrieval

    /// Fetch the documents most relevant to `text`, most-relevant first.
    ///
    /// - Returns: The matching documents, or an empty array for a blank query.
    /// - Throws: ``DakeraRetrieverError`` on a misconfiguration or a server/transport failure.
    public func retrieve(_ text: String) async throws -> [DakeraDocument] {
        guard !options.namespace.isEmpty else { throw DakeraRetrieverError.missingNamespace }
        guard let apiKey = options.apiKey, !apiKey.isEmpty else { throw DakeraRetrieverError.missingAPIKey }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        let request = try makeRequest(query: query, apiKey: apiKey)
        let response = try await invoker.send(request)
        guard (200..<300).contains(response.status) else {
            let message = String(data: response.data, encoding: .utf8) ?? ""
            throw DakeraRetrieverError.server(status: response.status, message: message)
        }
        return try Self.parse(response.data)
    }

    /// Fetch results for `text` and join their text into one string (empty results dropped).
    public func retrieveAndCombineResults(_ text: String, separator: String = "\n") async throws -> String {
        try await retrieve(text).map(\.content).filter { !$0.isEmpty }.joined(separator: separator)
    }

    // MARK: - Request / response

    /// Build the `POST /v1/namespaces/{namespace}/query-text` request. The API key is set as the
    /// `X-API-Key` header and never modelled or traced as an argument.
    private func makeRequest(query: String, apiKey: String) throws -> URLRequest {
        let base = options.url.hasSuffix("/") ? String(options.url.dropLast()) : options.url
        let namespace =
            options.namespace.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? options.namespace
        guard let url = URL(string: "\(base)/v1/namespaces/\(namespace)/query-text") else {
            throw DakeraRetrieverError.invalidURL(options.url)
        }

        var body: [String: JSONValue] = [
            "text": .string(query),
            "top_k": .int(options.topK),
            "include_text": .bool(true),
        ]
        if let filter = options.filter { body["filter"] = filter }

        var request = URLRequest(url: url, timeoutInterval: options.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        return request
    }

    /// Decode a `TextQueryResponse` body into documents. Uses `JSONValue` so a numeric or string id
    /// (and any metadata shape) round-trips without a brittle typed model.
    static func parse(_ data: Data) throws -> [DakeraDocument] {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw DakeraRetrieverError.decoding("response was not valid JSON")
        }
        guard case .array(let results)? = root["results"] else {
            throw DakeraRetrieverError.decoding("response had no `results` array")
        }
        return results.map { result in
            DakeraDocument(
                id: idString(result["id"]),
                content: result["text"]?.stringValue ?? "",
                score: result["score"]?.doubleValue ?? 0,
                metadata: result["metadata"] ?? .object([:])
            )
        }
    }

    /// Coerce an id that may arrive as a string or a number into a `String`.
    private static func idString(_ value: JSONValue?) -> String {
        switch value {
        case .string(let string): return string
        case .int(let int): return String(int)
        case .double(let double): return String(double)
        default: return ""
        }
    }
}

// MARK: - ToolProvider

extension DakeraRetriever: ToolProvider {
    public func listTools() async throws -> [AgentTool] {
        let schema = [
            ToolParameter.string("query", "The natural-language query to search memory for.", required: true)
        ].objectSchema()
        return [AgentTool(name: options.toolName, description: options.toolDescription, inputSchema: schema)]
    }

    public func call(_ name: String, arguments: JSONValue) async throws -> ToolResult {
        guard name == options.toolName else { return .failure("Unknown tool: \(name)") }
        guard let query = arguments["query"]?.stringValue,
            !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .failure("The 'query' argument is required and must be a non-empty string.")
        }

        // A retrieval failure comes back as a tool-level error so the model can react and the agent
        // loop continues, matching how the HTTP tools surface failures.
        let documents: [DakeraDocument]
        do {
            documents = try await retrieve(query)
        } catch {
            return .failure("Dakera retrieval failed: \(error)")
        }

        let combined = documents.map(\.content).filter { !$0.isEmpty }.joined(separator: "\n")
        let structured = JSONValue.object([
            "results": .array(
                documents.map { document in
                    .object([
                        "id": .string(document.id),
                        "score": .double(document.score),
                        "text": .string(document.content),
                        "metadata": document.metadata,
                    ])
                })
        ])
        return ToolResult(
            content: [.text(combined.isEmpty ? "No relevant documents found." : combined)],
            structuredContent: structured
        )
    }
}
