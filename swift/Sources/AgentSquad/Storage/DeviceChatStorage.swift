import Foundation
import SwiftData

/// On-device, restart-surviving chat history backed by SwiftData. The SQLite store lives under
/// `Library/Caches`: never backed up, reclaimable by the OS under disk pressure (the history is
/// temporary). Bound to a single `userId` at init; the per-call `userId` is ignored (an `assert`
/// guards a caller passing a different one). The bundled on-device store on iOS 17+ / macOS 14+;
/// iOS 16 consumers use `FileChatStorage`, a custom `ChatStorage`, or `store: nil`.
@available(iOS 17, macOS 14, *)
public actor DeviceChatStorage: ChatStorage, ModelActor {
    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor

    private let boundUserId: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameters:
    ///   - userId: the bound scope (logged-in id, or a stable persisted local id).
    ///   - baseURL: directory for the SQLite store; defaults to `Library/Caches/AgentSquad`.
    ///   - inMemory: use an ephemeral store (tests).
    public init(userId: String, baseURL: URL? = nil, inMemory: Bool = false) throws {
        self.boundUserId = userId

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.encoder = encoder
        self.decoder = decoder

        let container: ModelContainer
        if inMemory {
            container = try ModelContainer(
                for: StoredMessage.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        } else {
            let directory = baseURL ?? Self.defaultBaseURL()
            container = try Self.makeDiskContainer(in: directory)
        }
        self.modelContainer = container
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: ModelContext(container))
    }

    private static func defaultBaseURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentSquad", isDirectory: true)
    }

    /// Open the on-disk store, self-healing a purged/corrupt Caches store: a partial WAL/SHM purge
    /// makes `ModelContainer` throw forever, so delete and retry once (losing the temporary history).
    private static func makeDiskContainer(in directory: URL) throws -> ModelContainer {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("chat.store")
        do {
            return try ModelContainer(for: StoredMessage.self, configurations: ModelConfiguration(url: url))
        } catch {
            try? manager.removeItem(at: directory)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            return try ModelContainer(for: StoredMessage.self, configurations: ModelConfiguration(url: url))
        }
    }

    // MARK: - ChatStorage  (the per-call userId is ignored — scope is the bound id)

    public func fetch(
        userId: String, sessionId: String, agentId: String, maxMessages: Int?
    ) async throws -> [ConversationMessage] {
        assertBoundUser(userId)
        // Re-trim for a caller asking a tighter window than `save` stored.
        let messages = try scopedRows(sessionId: sessionId, agentId: agentId).map { try decode($0.payload) }
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
        assertBoundUser(userId)
        var lastRole = try lastRole(sessionId: sessionId, agentId: agentId)
        var seq = try nextSequence()
        for message in messages {
            let role = message.role.rawValue
            guard role != lastRole else { continue }   // drop consecutive same-role
            modelContext.insert(StoredMessage(
                userId: boundUserId,
                sessionId: sessionId,
                agentId: agentId,
                role: role,
                timestamp: message.timestamp,
                seq: seq,
                payload: try encoder.encode(message)
            ))
            lastRole = role
            seq += 1
        }
        try modelContext.save()
        try enforceCap(sessionId: sessionId, agentId: agentId, maxMessages: maxMessages)
    }

    public func fetchAllChats(userId: String, sessionId: String) async throws -> [ConversationMessage] {
        assertBoundUser(userId)
        let boundUserId = self.boundUserId
        // Ordered by timestamp, ties broken by `seq` (insertion order) — deterministic across runs.
        let descriptor = FetchDescriptor<StoredMessage>(
            predicate: #Predicate { $0.userId == boundUserId && $0.sessionId == sessionId },
            sortBy: [SortDescriptor(\.timestamp), SortDescriptor(\.seq)]
        )
        return try modelContext.fetch(descriptor).map { row in
            try decode(row.payload).attributed(agentId: row.agentId)
        }
    }

    /// Delete all history for the bound user — call on logout / account switch so the next user
    /// can't read the previous one's conversations.
    public func clear() throws {
        let boundUserId = self.boundUserId
        try modelContext.delete(model: StoredMessage.self, where: #Predicate { $0.userId == boundUserId })
        try modelContext.save()
    }

    // MARK: - Queries

    /// Scope rows for one agent, oldest→newest.
    private func scopedRows(sessionId: String, agentId: String) throws -> [StoredMessage] {
        let boundUserId = self.boundUserId
        let descriptor = FetchDescriptor<StoredMessage>(
            predicate: #Predicate { $0.userId == boundUserId && $0.sessionId == sessionId && $0.agentId == agentId },
            sortBy: [SortDescriptor(\.seq)]
        )
        return try modelContext.fetch(descriptor)
    }

    /// The role of the most recent message in scope, read via a one-row query (no full scan).
    private func lastRole(sessionId: String, agentId: String) throws -> String? {
        let boundUserId = self.boundUserId
        var descriptor = FetchDescriptor<StoredMessage>(
            predicate: #Predicate { $0.userId == boundUserId && $0.sessionId == sessionId && $0.agentId == agentId },
            sortBy: [SortDescriptor(\.seq, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.role
    }

    /// Next global monotonic sequence number.
    private func nextSequence() throws -> Int {
        var descriptor = FetchDescriptor<StoredMessage>(sortBy: [SortDescriptor(\.seq, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try modelContext.fetch(descriptor).first?.seq ?? 0) + 1
    }

    /// Keep at most an even `maxMessages` for the scope (so a user/assistant pair is never split);
    /// delete the oldest overflow. `nil` = unbounded.
    private func enforceCap(sessionId: String, agentId: String, maxMessages: Int?) throws {
        guard let maxMessages else { return }
        let cap = max(0, maxMessages.isMultiple(of: 2) ? maxMessages : maxMessages - 1)
        let scope = try scopedRows(sessionId: sessionId, agentId: agentId)
        guard scope.count > cap else { return }
        for row in scope.prefix(scope.count - cap) { modelContext.delete(row) }
        try modelContext.save()
    }

    // MARK: - Helpers

    private func assertBoundUser(_ userId: String, function: StaticString = #function) {
        assert(
            userId.isEmpty || userId == boundUserId,
            "DeviceChatStorage is bound to '\(boundUserId)'; per-call userId '\(userId)' in \(function) is ignored"
        )
    }

    private func decode(_ data: Data) throws -> ConversationMessage {
        try decoder.decode(ConversationMessage.self, from: data)
    }
}

/// SwiftData row for one persisted message. Scalar columns are what we query/sort/scope on; the
/// message body is stored as the pinned `Codable` `ConversationMessage` blob so we never re-model
/// our value types. Internal — an implementation detail of `DeviceChatStorage`.
@available(iOS 17, macOS 14, *)   // SwiftData floor; the package targets iOS 16, so this is gated.
@Model
final class StoredMessage {
    var userId: String
    var sessionId: String
    var agentId: String
    var role: String          // ConversationMessage.role.rawValue — same-role check without decoding
    var timestamp: Date
    var seq: Int              // global monotonic insertion order — stable tiebreaker for equal timestamps
    var payload: Data         // encoded ConversationMessage

    init(
        userId: String,
        sessionId: String,
        agentId: String,
        role: String,
        timestamp: Date,
        seq: Int,
        payload: Data
    ) {
        self.userId = userId
        self.sessionId = sessionId
        self.agentId = agentId
        self.role = role
        self.timestamp = timestamp
        self.seq = seq
        self.payload = payload
    }
}
