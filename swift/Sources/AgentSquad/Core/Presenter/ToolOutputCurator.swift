import Foundation

/// One captured tool result, as the `ToolOutputCurator` sees it.
public struct CapturedTool: Sendable, Equatable {
    public let name: String
    public let ui: String?
    public let structuredContent: JSONValue
    public let content: [ContentPart]?

    public init(
        name: String,
        ui: String? = nil,
        structuredContent: JSONValue,
        content: [ContentPart]? = nil
    ) {
        self.name = name
        self.ui = ui
        self.structuredContent = structuredContent
        self.content = content
    }
}

/// Turns gathered tool results into the text the presenter is fed — `GroundedAgent`'s data
/// extension point; default is `.dataBlock`. Pure synchronous transform by contract, no I/O: a
/// curator needing external data pre-fetches it and is constructed with it.
public protocol ToolOutputCurator: Sendable {
    func curate(_ results: [CapturedTool]) -> String
}

/// The default `ToolOutputCurator`: a faithful `### <toolName>` section per tool — model-facing text,
/// or structured data pretty-printed when there is none — concatenated across every captured tool.
public struct DataBlockCurator: ToolOutputCurator {
    public init() {}

    public func curate(_ results: [CapturedTool]) -> String {
        results.map(Self.section).joined(separator: "\n\n")
    }

    /// One section. `public` so `PerToolCurator` can fall back to it.
    public static func section(_ tool: CapturedTool) -> String {
        let text = (tool.content ?? []).compactMap { part in
            if case .text(let value) = part { return value } else { return nil }
        }.joined(separator: "\n")
        let body = text.isEmpty ? prettyJSON(tool.structuredContent) : text
        return "### \(tool.name)\n\(body)"
    }

    private static func prettyJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension ToolOutputCurator where Self == DataBlockCurator {
    /// The default faithful per-tool curator. Lets `GroundedAgent(curator: .dataBlock)` read cleanly.
    public static var dataBlock: DataBlockCurator { DataBlockCurator() }
}

/// A `ToolOutputCurator` routing each captured tool to its own formatter, keyed by tool name (the
/// key `PresenterPrompt` uses), with a fallback for unmapped tools. Each formatter trims/compacts its
/// tool's section, so this is where you shrink an oversized payload before the presenter sees it.
public struct PerToolCurator: ToolOutputCurator {
    /// Formats one captured tool into its section of the feed.
    public typealias Formatter = @Sendable (CapturedTool) -> String

    private let formatters: [String: Formatter]
    private let fallback: Formatter

    public init(_ formatters: [String: Formatter], default fallback: @escaping Formatter) {
        self.formatters = formatters
        self.fallback = fallback
    }

    public func curate(_ results: [CapturedTool]) -> String {
        results.map { (formatters[$0.name] ?? fallback)($0) }.joined(separator: "\n\n")
    }
}

extension ToolOutputCurator where Self == PerToolCurator {
    /// Per-tool formatters keyed by tool name; unmapped tools fall back to the lossless `dataBlock`
    /// section. Lets `GroundedAgent(curator: .perTool([...], default: ...))` read cleanly.
    public static func perTool(
        _ formatters: [String: PerToolCurator.Formatter],
        default fallback: @escaping PerToolCurator.Formatter = { DataBlockCurator.section($0) }
    ) -> PerToolCurator {
        PerToolCurator(formatters, default: fallback)
    }
}
