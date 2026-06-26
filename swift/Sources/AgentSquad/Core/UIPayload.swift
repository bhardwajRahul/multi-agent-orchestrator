import Foundation

/// UI advertised by an MCP tool (the `io.modelcontextprotocol/ui` extension, "MCP Apps").
///
/// `structuredContent`/`meta` are render-only: never added to the model's context, so it can't hallucinate from them. Lives in Core for `ContentPart`/`AgentEvent`; renderer is under `MCP/UI`.
public struct UIPayload: Sendable, Codable, Hashable {
    /// e.g. `ui://sport/matches`.
    public let resourceURI: String
    /// e.g. `text/html;profile=mcp-app`, `text/uri-list`, `application/vnd.mcp-ui.remote-dom`.
    public let mimeType: String
    /// Resource content, fetched lazily via `resources/read`; `nil` until then.
    public let template: UITemplate?
    /// Data the component hydrates from. Always present (possibly empty `{}`).
    public let structuredContent: JSONValue
    /// Widget-only metadata; absent when the tool advertises none.
    public let meta: JSONValue?
    /// CSP / permissions / domain from the resource's `_meta.ui`.
    public let security: UISecurity?

    public init(
        resourceURI: String,
        mimeType: String,
        template: UITemplate? = nil,
        structuredContent: JSONValue = .object([:]),
        meta: JSONValue? = nil,
        security: UISecurity? = nil
    ) {
        self.resourceURI = resourceURI
        self.mimeType = mimeType
        self.template = template
        self.structuredContent = structuredContent
        self.meta = meta
        self.security = security
    }
}

public enum UITemplate: Sendable, Codable, Hashable {
    case html(String)        // text/html;profile=mcp-app
    case url(URL)            // text/uri-list
    case remoteDOM(String)   // application/vnd.mcp-ui.remote-dom
}

/// Security the host enforces when rendering a component. CSP is built from the declared domains; undeclared ones are blocked.
public struct UISecurity: Sendable, Codable, Hashable {
    public let connectDomains: [String]
    public let resourceDomains: [String]
    public let frameDomains: [String]
    public let permissions: [String]      // e.g. "camera", "microphone", "geolocation"
    public let domain: String?            // dedicated sandbox origin
    public let prefersBorder: Bool

    public init(
        connectDomains: [String] = [],
        resourceDomains: [String] = [],
        frameDomains: [String] = [],
        permissions: [String] = [],
        domain: String? = nil,
        prefersBorder: Bool = false
    ) {
        self.connectDomains = connectDomains
        self.resourceDomains = resourceDomains
        self.frameDomains = frameDomains
        self.permissions = permissions
        self.domain = domain
        self.prefersBorder = prefersBorder
    }
}
