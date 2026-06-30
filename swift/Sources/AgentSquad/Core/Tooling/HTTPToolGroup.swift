import Foundation

// Terse declarative HTTP tools: `Tool.get(...)`/`.post(...)` build a `Tool.http` from a URL and a
// `ToolParameter` list. For many endpoints sharing a base URL/auth/response, use `HTTPToolGroup`.

extension Tool {
    /// A `GET` tool. Arguments map to query items; `{token}`s in `url` are filled from arguments.
    public static func get(
        _ name: String, _ url: String, _ description: String = "", _ arguments: ToolParameter...,
        outputSchema: JSONValue? = nil,
        headers: [String: String] = [:], secrets: [String: String] = [:], hostArguments: [String: JSONValue] = [:],
        response: ResponseMapping = .standard, visibility: ToolVisibility = .all, ui: String? = nil,
        timeout: TimeInterval = 30, invoker: any HTTPInvoker = URLSessionInvoker()
    ) -> Tool {
        http(name: name, description: description, inputSchema: arguments.objectSchema(), ui: ui, visibility: visibility, outputSchema: outputSchema,
             spec: HTTPToolSpec(method: .get, url: url, headers: headers, secrets: secrets, hostArguments: hostArguments, response: response, timeout: timeout, invoker: invoker))
    }

    /// A `POST` tool. Arguments become the JSON body; `{token}`s in `url` are filled from arguments.
    public static func post(
        _ name: String, _ url: String, _ description: String = "", _ arguments: ToolParameter...,
        outputSchema: JSONValue? = nil,
        headers: [String: String] = [:], secrets: [String: String] = [:], hostArguments: [String: JSONValue] = [:],
        body: HTTPBody = .auto, response: ResponseMapping = .standard, visibility: ToolVisibility = .all, ui: String? = nil,
        timeout: TimeInterval = 30, invoker: any HTTPInvoker = URLSessionInvoker()
    ) -> Tool {
        http(name: name, description: description, inputSchema: arguments.objectSchema(), ui: ui, visibility: visibility, outputSchema: outputSchema,
             spec: HTTPToolSpec(method: .post, url: url, headers: headers, secrets: secrets, hostArguments: hostArguments, body: body, response: response, timeout: timeout, invoker: invoker))
    }

    /// A `PUT` tool. Arguments become the JSON body.
    public static func put(
        _ name: String, _ url: String, _ description: String = "", _ arguments: ToolParameter...,
        outputSchema: JSONValue? = nil,
        headers: [String: String] = [:], secrets: [String: String] = [:], hostArguments: [String: JSONValue] = [:],
        body: HTTPBody = .auto, response: ResponseMapping = .standard, visibility: ToolVisibility = .all, ui: String? = nil,
        timeout: TimeInterval = 30, invoker: any HTTPInvoker = URLSessionInvoker()
    ) -> Tool {
        http(name: name, description: description, inputSchema: arguments.objectSchema(), ui: ui, visibility: visibility, outputSchema: outputSchema,
             spec: HTTPToolSpec(method: .put, url: url, headers: headers, secrets: secrets, hostArguments: hostArguments, body: body, response: response, timeout: timeout, invoker: invoker))
    }

    /// A `DELETE` tool. Arguments map to query items.
    public static func delete(
        _ name: String, _ url: String, _ description: String = "", _ arguments: ToolParameter...,
        outputSchema: JSONValue? = nil,
        headers: [String: String] = [:], secrets: [String: String] = [:], hostArguments: [String: JSONValue] = [:],
        response: ResponseMapping = .standard, visibility: ToolVisibility = .all, ui: String? = nil,
        timeout: TimeInterval = 30, invoker: any HTTPInvoker = URLSessionInvoker()
    ) -> Tool {
        http(name: name, description: description, inputSchema: arguments.objectSchema(), ui: ui, visibility: visibility, outputSchema: outputSchema,
             spec: HTTPToolSpec(method: .delete, url: url, headers: headers, secrets: secrets, hostArguments: hostArguments, response: response, timeout: timeout, invoker: invoker))
    }
}

/// HTTP endpoints sharing a base URL, headers, credentials, host arguments, and response convention.
/// Declare it once, then one line per endpoint via ``get(_:_:_:outputSchema:response:visibility:ui:)`` etc.
public struct HTTPToolGroup: Sendable {
    public var baseURL: String
    public var headers: [String: String]
    public var secrets: [String: String]
    public var hostArguments: [String: JSONValue]
    public var response: ResponseMapping
    public var timeout: TimeInterval
    public var invoker: any HTTPInvoker

    public init(
        baseURL: String,
        headers: [String: String] = [:],
        secrets: [String: String] = [:],
        hostArguments: [String: JSONValue] = [:],
        response: ResponseMapping = .standard,
        timeout: TimeInterval = 30,
        invoker: any HTTPInvoker = URLSessionInvoker()
    ) {
        self.baseURL = baseURL
        self.headers = headers
        self.secrets = secrets
        self.hostArguments = hostArguments
        self.response = response
        self.timeout = timeout
        self.invoker = invoker
    }

    /// A `GET` endpoint at `baseURL + path`. `response` overrides the group default for this tool.
    public func get(
        _ name: String, _ path: String, _ description: String = "", _ arguments: ToolParameter...,
        outputSchema: JSONValue? = nil, response: ResponseMapping? = nil, visibility: ToolVisibility = .all, ui: String? = nil
    ) -> Tool {
        endpoint(method: .get, name: name, path: path, description: description, arguments: arguments,
                 body: .auto, outputSchema: outputSchema, response: response, visibility: visibility, ui: ui)
    }

    /// A `POST` endpoint at `baseURL + path`.
    public func post(
        _ name: String, _ path: String, _ description: String = "", _ arguments: ToolParameter...,
        body: HTTPBody = .auto, outputSchema: JSONValue? = nil, response: ResponseMapping? = nil, visibility: ToolVisibility = .all, ui: String? = nil
    ) -> Tool {
        endpoint(method: .post, name: name, path: path, description: description, arguments: arguments,
                 body: body, outputSchema: outputSchema, response: response, visibility: visibility, ui: ui)
    }

    /// A `PUT` endpoint at `baseURL + path`.
    public func put(
        _ name: String, _ path: String, _ description: String = "", _ arguments: ToolParameter...,
        body: HTTPBody = .auto, outputSchema: JSONValue? = nil, response: ResponseMapping? = nil, visibility: ToolVisibility = .all, ui: String? = nil
    ) -> Tool {
        endpoint(method: .put, name: name, path: path, description: description, arguments: arguments,
                 body: body, outputSchema: outputSchema, response: response, visibility: visibility, ui: ui)
    }

    /// A `DELETE` endpoint at `baseURL + path`.
    public func delete(
        _ name: String, _ path: String, _ description: String = "", _ arguments: ToolParameter...,
        outputSchema: JSONValue? = nil, response: ResponseMapping? = nil, visibility: ToolVisibility = .all, ui: String? = nil
    ) -> Tool {
        endpoint(method: .delete, name: name, path: path, description: description, arguments: arguments,
                 body: .auto, outputSchema: outputSchema, response: response, visibility: visibility, ui: ui)
    }

    private func endpoint(
        method: HTTPMethod, name: String, path: String, description: String,
        arguments: [ToolParameter], body: HTTPBody, outputSchema: JSONValue?,
        response: ResponseMapping?, visibility: ToolVisibility, ui: String?
    ) -> Tool {
        Tool.http(
            name: name, description: description, inputSchema: arguments.objectSchema(),
            ui: ui, visibility: visibility, outputSchema: outputSchema,
            spec: HTTPToolSpec(
                method: method, url: joinURL(path: path),
                headers: headers, secrets: secrets, hostArguments: hostArguments,
                body: body, response: response ?? self.response, timeout: timeout, invoker: invoker
            )
        )
    }

    /// Join `baseURL` and `path`, normalizing trailing/leading slashes so the result always has
    /// exactly one separator (e.g. avoids `"https://api.test//users"` or `"https://api.testusers"`).
    private func joinURL(path: String) -> String {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let sep = path.hasPrefix("/") ? "" : "/"
        return base + sep + path
    }
}
