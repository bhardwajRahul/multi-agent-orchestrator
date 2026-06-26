import Foundation

/// On-device chat history backed by plain JSON files — the iOS-16-compatible `ChatStorage`.
/// (The bundled `DeviceChatStorage` needs SwiftData, iOS 17 / macOS 14.)
///
/// One file per `(userId, sessionId, agentId)` scope, so histories never overlap. Path components
/// are percent-encoded for filesystem-safe, reversible ids. Survives app/device restarts. Suited to
/// small, capped histories (each call reads/writes a whole scope file). History is disposable — a
/// purged or corrupt file reads as empty rather than throwing.
public actor FileChatStorage: ChatStorage {

    private let baseURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameters:
    ///   - baseURL: directory for the JSON files; defaults to `Library/Caches/AgentSquadChats`.
    ///   - fileManager: injectable for tests; defaults to `.default`.
    public init(baseURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.baseURL = baseURL ?? Self.defaultBaseURL(fileManager)
        // `millisecondsSince1970` is sub-second precise so the merged `fetchAllChats` view orders
        // correctly; `.iso8601` is whole-second only and would misorder same-second timestamps.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.encoder = encoder
        self.decoder = decoder
    }

    private static func defaultBaseURL(_ fileManager: FileManager) -> URL {
        fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentSquadChats", isDirectory: true)
    }

    // MARK: - ChatStorage

    public func fetch(
        userId: String, sessionId: String, agentId: String, maxMessages: Int?
    ) async throws -> [ConversationMessage] {
        let messages = load(at: fileURL(userId: userId, sessionId: sessionId, agentId: agentId))
        return trimToEvenPairs(messages, maxMessages: maxMessages)
    }

    public func save(
        _ message: ConversationMessage,
        userId: String, sessionId: String, agentId: String, maxMessages: Int?
    ) async throws {
        try await saveMessages([message], userId: userId, sessionId: sessionId, agentId: agentId, maxMessages: maxMessages)
    }

    public func saveMessages(
        _ messages: [ConversationMessage],
        userId: String, sessionId: String, agentId: String, maxMessages: Int?
    ) async throws {
        let url = fileURL(userId: userId, sessionId: sessionId, agentId: agentId)
        var combined = load(at: url)
        for message in messages where !isConsecutiveSameRole(combined, message) {
            combined.append(message)
        }
        combined = trimToEvenPairs(combined, maxMessages: maxMessages)
        try write(combined, to: url)
    }

    public func fetchAllChats(userId: String, sessionId: String) async throws -> [ConversationMessage] {
        let sessionDir = baseURL
            .appendingPathComponent(encode(userId), isDirectory: true)
            .appendingPathComponent(encode(sessionId), isDirectory: true)
        let files = ((try? fileManager.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // Deterministic merge: sort by (timestamp, read order).
        var tagged: [(message: ConversationMessage, agentId: String, order: Int)] = []
        for file in files {
            let agentId = decode(file.deletingPathExtension().lastPathComponent)
            for message in load(at: file) {
                tagged.append((message, agentId, tagged.count))
            }
        }
        return tagged
            .sorted { ($0.message.timestamp, $0.order) < ($1.message.timestamp, $1.order) }
            .map { $0.message.attributed(agentId: $0.agentId) }
    }

    // MARK: - File IO

    private func fileURL(userId: String, sessionId: String, agentId: String) -> URL {
        baseURL
            .appendingPathComponent(encode(userId), isDirectory: true)
            .appendingPathComponent(encode(sessionId), isDirectory: true)
            .appendingPathComponent(encode(agentId), isDirectory: false)
            .appendingPathExtension("json")
    }

    private func load(at url: URL) -> [ConversationMessage] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([ConversationMessage].self, from: data)) ?? []
    }

    private func write(_ messages: [ConversationMessage], to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(messages)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Helpers

    /// Percent-encode a scope id into a filesystem-safe, reversible path component (empty → `_`).
    private func encode(_ component: String) -> String {
        let encoded = component.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? component
        return encoded.isEmpty ? "_" : encoded
    }

    private func decode(_ component: String) -> String {
        if component == "_" { return "" }   // reverse the empty-id sentinel from `encode`
        return component.removingPercentEncoding ?? component
    }
}
