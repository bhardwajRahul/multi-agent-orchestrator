import Foundation
import Testing

@testable import AgentSquad

@Suite struct OSLogTracerTests {
    // Logging is a side effect we don't assert on; we verify the tree composes and ids are distinct.
    @Test func composesAndAssignsDistinctIds() {
        let tracer = OSLogTracer()
        let trace = tracer.startTrace(name: "chat.turn", userId: "u", sessionId: "s", metadata: nil)
        #expect(trace.id.isEmpty == false)

        let span = trace.span("tool.get_odds", input: ["match": "PSG"])
        #expect(span.id != trace.id)

        let generation = span.generation("llm", model: "gpt-realtime", input: nil)
        #expect(generation.id != span.id)

        // None of these should crash; they emit os_log lines.
        generation.usage(promptTokens: 10, completionTokens: 5)
        generation.end(output: "ok", error: nil)
        span.end(output: nil, error: nil)
        trace.end(output: nil, error: nil)
    }

    @Test func endWithErrorDoesNotCrash() {
        struct Boom: Error {}
        let trace = OSLogTracer().startTrace(name: "t", userId: nil, sessionId: nil, metadata: nil)
        trace.end(output: nil, error: Boom())
    }
}
