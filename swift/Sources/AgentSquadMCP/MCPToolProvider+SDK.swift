import Foundation

import AgentSquad

/// Friendly name for ``MCPToolProvider`` — reads as the MCP server you're connecting to:
/// `MCPServer(url: …)`. Same type; use whichever name fits.
public typealias MCPServer = MCPToolProvider

extension MCPToolProvider {
    /// Connect to an MCP server at the given URL string: `MCPServer(url: "https://…")`. An invalid
    /// URL traps (a static config mistake, caught on first run). Already hold a `URL`? Use that overload.
    public init(
        url urlString: String,
        hostArguments: [String: JSONValue] = [:],
        clientName: String = SDKMCPClient.defaultClientName,
        clientVersion: String = SDKMCPClient.defaultClientVersion,
        streaming: Bool = true,
        headers: [String: String] = [:]
    ) {
        guard let url = URL(string: urlString) else {
            preconditionFailure("MCPServer(url:): \"\(urlString)\" is not a valid URL")
        }
        self.init(
            url: url,
            hostArguments: hostArguments,
            clientName: clientName,
            clientVersion: clientVersion,
            streaming: streaming,
            headers: headers
        )
    }

    /// Connect to an MCP server at `url` using the bundled ``SDKMCPClient`` — the one-line path for
    /// the common case. For a non-default client (a different transport, or a mock in tests), use
    /// ``init(client:hostArguments:)`` and pass your own ``MCPClient``.
    ///
    /// - Parameters:
    ///   - url: the server's endpoint.
    ///   - hostArguments: values the host supplies on every call (e.g. `["session_id": .string(id)]`),
    ///     hidden from the model's schema and injected per call — see ``init(client:hostArguments:)``.
    ///   - clientName / clientVersion: identity sent on the MCP handshake.
    ///   - streaming: whether the transport uses HTTP streaming (default `true`).
    ///   - headers: HTTP headers forwarded unchanged on every request (e.g. `["Authorization": "Bearer \(token)", "X-Match-Id": id]`).
    ///     The MCP server is responsible for interpreting them.
    public init(
        url: URL,
        hostArguments: [String: JSONValue] = [:],
        clientName: String = SDKMCPClient.defaultClientName,
        clientVersion: String = SDKMCPClient.defaultClientVersion,
        streaming: Bool = true,
        headers: [String: String] = [:]
    ) {
        self.init(
            client: SDKMCPClient(
                endpoint: url,
                clientName: clientName,
                clientVersion: clientVersion,
                streaming: streaming,
                headers: headers
            ),
            hostArguments: hostArguments
        )
    }
}
