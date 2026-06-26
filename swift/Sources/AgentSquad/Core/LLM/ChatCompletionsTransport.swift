import Foundation

/// Streaming HTTP seam so the client's parsing/retry logic is testable without a network. Yields body lines; throws on non-2xx.
public protocol ChatCompletionsTransport: Sendable {
    func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<String, any Error>
}

/// `URLSession` byte stream split into lines. `timeout` is the idle timeout (max gap between bytes), not a total-duration cap that would kill long responses.
public struct URLSessionEventStream: ChatCompletionsTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 60) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: configuration)
    }

    public func stream(_ request: URLRequest) async throws -> AsyncThrowingStream<String, any Error> {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatCompletionsError.nonHTTPResponse }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let body = data.isEmpty ? nil : String(decoding: data.prefix(2048), as: UTF8.self)
            throw ChatCompletionsError.httpStatus(http.statusCode, body: body)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
