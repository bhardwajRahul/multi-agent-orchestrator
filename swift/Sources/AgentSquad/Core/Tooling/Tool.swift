import Foundation

/// A tool's descriptor (``AgentTool``) paired with the code that runs it. Build with ``local(name:description:inputSchema:ui:visibility:outputSchema:_:)`` or ``http(name:description:inputSchema:ui:visibility:outputSchema:spec:)``; collect into a ``ToolKit``.
public struct Tool: Sendable {
    /// How this tool is advertised to the model.
    public let definition: AgentTool
    let run: @Sendable (_ arguments: JSONValue) async throws -> ToolResult

    public init(
        definition: AgentTool,
        run: @escaping @Sendable (_ arguments: JSONValue) async throws -> ToolResult
    ) {
        self.definition = definition
        self.run = run
    }

    /// A tool backed by a local Swift closure.
    public static func local(
        name: String,
        description: String,
        inputSchema: JSONValue = .object(["type": "object"]),
        ui: String? = nil,
        visibility: ToolVisibility = .all,
        outputSchema: JSONValue? = nil,
        _ handler: @escaping @Sendable (_ arguments: JSONValue) async throws -> ToolResult
    ) -> Tool {
        Tool(
            definition: AgentTool(
                name: name,
                description: description,
                inputSchema: inputSchema,
                ui: ui,
                visibility: visibility,
                outputSchema: outputSchema
            ),
            run: handler
        )
    }
}
