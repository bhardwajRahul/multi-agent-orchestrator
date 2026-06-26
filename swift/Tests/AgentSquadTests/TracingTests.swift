import Foundation
import Testing

@testable import AgentSquad

@Suite struct TracingTests {
    // No-op tracer/span confirms the consumer-facing tracing API composes (trace → span →
    // generation → end). A struct returning `self` is enough since there's no state.
    private struct NoopSpan: GenerationHandle {
        let id = "noop"
        func span(_ name: String, input: JSONValue?) -> any SpanHandle { self }
        func generation(_ name: String, model: String, input: JSONValue?) -> any GenerationHandle { self }
        func end(output: JSONValue?, error: (any Error)?) {}
        func usage(promptTokens: Int?, completionTokens: Int?) {}
    }

    private struct NoopTracer: Tracer {
        func startTrace(name: String, userId: String?, sessionId: String?, metadata: JSONValue?) -> any SpanHandle {
            NoopSpan()
        }
    }

    @Test func tracingAPIComposes() {
        let trace = NoopTracer().startTrace(name: "turn", userId: "u", sessionId: "s", metadata: nil)
        let span = trace.span("tool.get_odds", input: ["match": "PSG"])
        let gen = span.generation("llm", model: "gpt", input: nil)
        gen.usage(promptTokens: 10, completionTokens: 5)
        gen.end(output: "ok", error: nil)
        span.end(output: nil, error: nil)
        trace.end(output: nil, error: nil)
    }

    @Test func traceEventRoundTrips() throws {
        let event = TraceEvent(
            traceId: "t",
            id: "s1",
            parentId: "root",
            kind: .generation,
            name: "llm",
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            endedAt: Date(timeIntervalSinceReferenceDate: 1),
            input: ["q": "odds?"],
            output: "1.26",
            model: "gpt",
            promptTokens: 10,
            completionTokens: 5,
            userId: "u",
            sessionId: "s"
        )
        let data = try JSONEncoder().encode(event)
        #expect(try JSONDecoder().decode(TraceEvent.self, from: data) == event)
    }

    @Test func minimalSpanRoundTripsAndUsesPinnedKeys() throws {
        let event = TraceEvent(
            traceId: "t",
            id: "s1",
            kind: .span,
            name: "tool.get_odds",
            startedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let data = try JSONEncoder().encode(event)
        #expect(try JSONDecoder().decode(TraceEvent.self, from: data) == event)

        // The serialized form is the frozen contract — assert the pinned snake_case keys.
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"trace_id\""))
        #expect(json.contains("\"started_at\""))
        #expect(json.contains("\"status\":\"ok\""))
    }

    @Test func redactionDefaultsArePrivacySafe() {
        let redaction = Redaction.default
        #expect(redaction.hashUserIds)
        #expect(redaction.maxStringLength == 4096)
    }
}
