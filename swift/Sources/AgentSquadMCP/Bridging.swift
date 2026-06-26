import Foundation

import AgentSquad
import MCP

/// Pure conversions between the MCP SDK's `Value`/metadata and our core `JSONValue`/types. Kept
/// as static functions over plain dictionaries (not the SDK's `Metadata`) so they unit-test
/// without constructing SDK wrapper types.
enum Bridging {
    /// SDK `Value` → our `JSONValue`. `Value.data` has no `JSONValue` counterpart, so it is encoded
    /// as a base64 string (rare in tool arguments / `structuredContent`).
    static func toJSON(_ value: Value) -> JSONValue {
        switch value {
        case .null: return .null
        case .bool(let bool): return .bool(bool)
        case .int(let int): return .int(int)
        case .double(let double): return .double(double)
        case .string(let string): return .string(string)
        case .data(_, let data): return .string(data.base64EncodedString())
        case .array(let array): return .array(array.map(toJSON))
        case .object(let object): return .object(object.mapValues(toJSON))
        }
    }

    /// Our `JSONValue` → SDK `Value`. Int stays int, double stays double (no silent coercion).
    static func toValue(_ json: JSONValue) -> Value {
        switch json {
        case .null: return .null
        case .bool(let bool): return .bool(bool)
        case .int(let int): return .int(int)
        case .double(let double): return .double(double)
        case .string(let string): return .string(string)
        case .array(let array): return .array(array.map(toValue))
        case .object(let object): return .object(object.mapValues(toValue))
        }
    }

    /// Tool-call arguments as the SDK expects them. A non-object argument yields an empty map.
    static func arguments(_ json: JSONValue) -> [String: Value] {
        guard case .object(let object) = json else { return [:] }
        return object.mapValues(toValue)
    }

    /// SDK content blocks → `ContentPart`s. Non-text blocks aren't dropped silently — they become
    /// a visible placeholder so an image/audio-only result isn't an empty-looking success.
    static func content(_ blocks: [Tool.Content]) -> [ContentPart]? {
        guard !blocks.isEmpty else { return nil }
        return blocks.map { block in
            if case .text(let text, _, _) = block { return .text(text) }
            if case .image = block { return .text("[image]") }
            if case .audio = block { return .text("[audio]") }
            return .text("[unsupported content]")
        }
    }

    /// `_meta` fields → `JSONValue` (object), for passthrough to the UI (never the model).
    static func metaToJSON(_ fields: [String: Value]?) -> JSONValue? {
        guard let fields else { return nil }
        return .object(fields.mapValues(toJSON))
    }

    /// The advertised UI template uri: `_meta.ui.resourceUri`, or the OpenAI `openai/outputTemplate`
    /// alias. Tolerant of absent/wrong-typed fields (→ `nil`).
    static func uiResourceURI(_ fields: [String: Value]?) -> String? {
        guard let fields else { return nil }
        if case .object(let ui)? = fields["ui"], case .string(let uri)? = ui["resourceUri"] {
            return uri
        }
        if case .string(let uri)? = fields["openai/outputTemplate"] {
            return uri
        }
        return nil
    }

    /// `_meta.ui.visibility` → `ToolVisibility`. Absent → `.all` (the MCP default, both audiences);
    /// a present array is parsed exactly (an empty array means neither). Wrong types → `.all`.
    static func visibility(_ fields: [String: Value]?) -> ToolVisibility {
        guard let fields, case .object(let ui)? = fields["ui"], case .array(let entries)? = ui["visibility"] else {
            return .all
        }
        var visibility: ToolVisibility = []
        for case .string(let entry) in entries {
            switch entry {
            case "model": visibility.insert(.model)
            case "app": visibility.insert(.app)
            default: break
            }
        }
        return visibility
    }
}
