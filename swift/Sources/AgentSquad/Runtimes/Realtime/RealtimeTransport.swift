import Foundation

/// The bidirectional frame channel `OpenAIGroundedVoiceAssistant` runs over — a seam so the session's
/// control logic (turn handling, grounding, barge-in) is unit-testable without a real WebSocket.
/// Frames are JSON strings (`RealtimeWire` does the encode/decode); the real transport is
/// `URLSessionWebSocketTransport`.
public protocol RealtimeTransport: Sendable {
    /// Open the connection. A live socket connects asynchronously: a failed handshake (bad auth,
    /// rejected upgrade) surfaces as `events` finishing or the next `send` throwing, not necessarily
    /// from `connect()` itself.
    func connect() async throws
    /// Send one JSON frame to the server.
    func send(_ json: String) async throws
    /// Inbound JSON frames from the server. Finishes when the connection closes.
    var events: AsyncStream<String> { get }
    /// Close the connection and finish `events`.
    func close() async
}

public enum RealtimeTransportError: Error, Equatable {
    case notConnected
    case alreadyConnected
}
