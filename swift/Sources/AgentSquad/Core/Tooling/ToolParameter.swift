import Foundation

/// One tool argument, described without hand-writing JSON Schema. The `Tool`/`HTTPToolGroup` factories
/// take these directly; or assemble a list with ``Swift/Array/objectSchema()``. Use ``raw(_:_:required:)``
/// for shapes the factories don't cover (nested objects, `oneOf`, …).
public struct ToolParameter: Sendable {
    public let name: String
    public let required: Bool
    /// The JSON Schema fragment for this one property (e.g. `["type": "string"]`).
    public let schema: JSONValue

    public init(name: String, required: Bool = false, schema: JSONValue) {
        self.name = name
        self.required = required
        self.schema = schema
    }

    public static func string(_ name: String, _ description: String? = nil, required: Bool = false, values: [String]? = nil) -> ToolParameter {
        var schema: [String: JSONValue] = ["type": "string"]
        if let description { schema["description"] = .string(description) }
        if let values { schema["enum"] = .array(values.map(JSONValue.string)) }
        return ToolParameter(name: name, required: required, schema: .object(schema))
    }

    public static func integer(_ name: String, _ description: String? = nil, required: Bool = false) -> ToolParameter {
        scalar(name, type: "integer", description: description, required: required)
    }

    public static func number(_ name: String, _ description: String? = nil, required: Bool = false) -> ToolParameter {
        scalar(name, type: "number", description: description, required: required)
    }

    public static func boolean(_ name: String, _ description: String? = nil, required: Bool = false) -> ToolParameter {
        scalar(name, type: "boolean", description: description, required: required)
    }

    /// Escape hatch — supply the property's JSON Schema fragment directly (nested objects, arrays, etc.).
    public static func raw(_ name: String, _ schema: JSONValue, required: Bool = false) -> ToolParameter {
        ToolParameter(name: name, required: required, schema: schema)
    }

    private static func scalar(_ name: String, type: String, description: String?, required: Bool) -> ToolParameter {
        var schema: [String: JSONValue] = ["type": .string(type)]
        if let description { schema["description"] = .string(description) }
        return ToolParameter(name: name, required: required, schema: .object(schema))
    }
}

extension Array where Element == ToolParameter {
    /// Assemble these parameters into a JSON-Schema `object` (with `properties` and `required`).
    /// An empty list yields `{"type": "object"}`.
    public func objectSchema() -> JSONValue {
        guard !isEmpty else { return .object(["type": "object"]) }
        var properties: [String: JSONValue] = [:]
        var required: [JSONValue] = []
        for parameter in self {
            properties[parameter.name] = parameter.schema
            if parameter.required { required.append(.string(parameter.name)) }
        }
        var root: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { root["required"] = .array(required) }
        return .object(root)
    }
}
