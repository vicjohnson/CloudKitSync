//
//  SyncCoordinator.swift
//  CloudKitSync
//

import Foundation
import CoreData

/// Turns CloudKit merges (and, by convention, an app's own local writes) into per-entity change
/// callbacks via each `SyncedEntity`'s `ChangeBroadcaster`, reading persistent history rather than
/// refetching and diffing the whole store — so cost tracks what changed, not how much data exists.
///
/// One coordinator per `NSPersistentCloudKitContainer`. Only the write-capable target(s) of an app
/// should call `startProcessingRemoteChanges()` — a read-only extension can react to a timeline
/// reload instead of driving history processing itself.
@MainActor
public final class SyncCoordinator {
    private let container: NSPersistentCloudKitContainer
    private let entities: [SyncedEntity]
    private let historyTokenDefaults: UserDefaults?
    private let historyTokenKey: String
    private let transactionAuthor: String
    private let historyRetention: DateComponents

    private var remoteChangeObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - container: The store to observe. Its `viewContext.transactionAuthor` should already be
    ///     set to `transactionAuthor` — that's what lets `processRemoteChanges()` skip re-emitting
    ///     this process's own writes, which already emitted synchronously from the mutation code.
    ///   - entities: One entry per Core Data entity to track.
    ///   - historyTokenDefaults: Where the last-processed history token is persisted. Use an App
    ///     Group suite if multiple targets share this store — each needs `historyTokenKey` scoped
    ///     per-author (see `transactionAuthor`) so they don't consume each other's position.
    ///   - historyTokenKey: Storage key for the token. Should already be unique per author.
    ///   - transactionAuthor: This process's `NSManagedObjectContext.transactionAuthor`. Must match
    ///     what the container's context is configured with.
    ///   - historyRetention: How far back to keep persistent history before pruning it. Should be
    ///     comfortably longer than this app's realistic max time-between-launches — a token older
    ///     than the retention window can no longer be resumed from, and `processRemoteChanges()`
    ///     falls back to a silent re-baseline when that happens (consumers should re-fetch in full
    ///     on init/foreground to cover that gap; see `FirstImportTracker` for one specific case).
    public init(
        container: NSPersistentCloudKitContainer,
        entities: [SyncedEntity],
        historyTokenDefaults: UserDefaults?,
        historyTokenKey: String,
        transactionAuthor: String,
        historyRetention: DateComponents = DateComponents(day: -7)
    ) {
        self.container = container
        self.entities = entities
        self.historyTokenDefaults = historyTokenDefaults
        self.historyTokenKey = historyTokenKey
        self.transactionAuthor = transactionAuthor
        self.historyRetention = historyRetention
    }

    // MARK: - Remote change processing

    /// Starts turning CloudKit merges into change callbacks.
    public func startProcessingRemoteChanges() {
        guard remoteChangeObserver == nil else {
            return
        }

        purgeExpiredHistory()

        // Establish the baseline now rather than on the first notification. Deferring it means
        // the first merge after a fresh install arrives with no token, and re-baselining at that
        // point adopts a position that already includes the change — swallowing it.
        if loadHistoryToken() == nil {
            adoptCurrentHistoryToken()
        }

        remoteChangeObserver = RemoteChangeObservation.observeRemoteChanges(container: container) { [weak self] in
            self?.processRemoteChanges()
        }
    }

    /// Emits for exactly what a merge touched. Safe to call redundantly — an import that brought
    /// nothing down finds no new transactions and emits nothing.
    public func processRemoteChanges() {
        guard let lastToken = loadHistoryToken() else {
            // No baseline yet, so there's no "since" to read from. Adopt the current position
            // and emit nothing; consumers fetch in full at init and on foreground anyway.
            adoptCurrentHistoryToken()
            return
        }

        let request = NSPersistentHistoryChangeRequest.fetchHistory(after: lastToken)

        guard let result = try? container.viewContext.execute(request) as? NSPersistentHistoryResult,
              let transactions = result.result as? [NSPersistentHistoryTransaction] else {
            // Usually means the token predates the purge horizon, so history can't tell the whole
            // story. Same handling as no token at all: re-baseline and let the next full fetch
            // sort it out, rather than emitting a partial picture.
            adoptCurrentHistoryToken()
            return
        }

        for transaction in transactions {
            // Reading history says *what* changed but does nothing to the objects the context is
            // already holding, so without this the context keeps serving stale copies until the
            // process restarts. Done for every transaction, including our own — re-merging one we
            // applied is a no-op, and skipping it would let the author filter below quietly
            // control context freshness as well as emission.
            container.viewContext.mergeChanges(fromContextDidSave: transaction.objectIDNotification())

            // Our own writes already emitted synchronously from the mutation methods.
            guard transaction.author != transactionAuthor else {
                continue
            }

            for change in transaction.changes ?? [] {
                record(change)
            }
        }

        for entity in entities {
            entity.broadcaster.flush()
        }

        if let newToken = transactions.last?.token {
            saveHistoryToken(newToken)
        }
    }

    private func record(_ change: NSPersistentHistoryChange) {
        let kind: ChangeKind

        switch change.changeType {
        case .insert: kind = .created
        case .update: kind = .updated
        case .delete: kind = .deleted
        @unknown default: return
        }

        guard let entity = entities.first(where: { $0.name == change.changedObjectID.entity.name }),
              let uuid = uuid(for: change) else {
            return
        }

        entity.broadcaster.record(uuid, kind)

        // Cascades mirror what local deletes/updates should already be doing on their own side —
        // this exists for the case a relationship change lands as a write to only one row, most
        // visibly when a new related entity and the object assigned to it arrive in separate
        // import batches. Without this, nothing says the *target* changed, so a cached copy keeps
        // stale relationship data until the next full fetch.
        //
        // Deletes are skipped: the object is gone, so its relationship's current members can't be
        // read from it. Core Data's own delete rule (e.g. Nullify) writes to those rows directly,
        // which arrives as its own change.
        guard kind != .deleted, !entity.cascades.isEmpty,
              let object = try? container.viewContext.existingObject(with: change.changedObjectID) else {
            return
        }

        for cascade in entity.cascades {
            let targets = object.value(forKey: cascade.key) as? NSSet ?? []

            for case let target as NSManagedObject in targets {
                guard let targetUUID = target.value(forKey: "uuid") as? UUID else { continue }
                cascade.targetBroadcaster.record(targetUUID, .updated)
            }
        }
    }

    private func uuid(for change: NSPersistentHistoryChange) -> UUID? {
        // A deleted row can't be fetched, so its uuid has to come from the tombstone — which is
        // populated only because `uuid` is marked "preserve after deletion" in the model.
        if change.changeType == .delete {
            return change.tombstone?["uuid"] as? UUID
        }

        let object = try? container.viewContext.existingObject(with: change.changedObjectID)

        return object?.value(forKey: "uuid") as? UUID
    }

    // MARK: - History token

    private func loadHistoryToken() -> NSPersistentHistoryToken? {
        guard let data = historyTokenDefaults?.data(forKey: historyTokenKey) else {
            return nil
        }

        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data)
    }

    private func saveHistoryToken(_ token: NSPersistentHistoryToken) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true) else {
            return
        }

        historyTokenDefaults?.set(data, forKey: historyTokenKey)
    }

    /// Treats wherever history currently sits as the new starting point, without emitting.
    private func adoptCurrentHistoryToken() {
        guard let token = container.persistentStoreCoordinator.currentPersistentHistoryToken(fromStores: nil) else {
            return
        }

        saveHistoryToken(token)
    }

    /// Nothing else prunes persistent history, so without this the store grows without bound.
    /// `historyRetention` should be long enough that any target launching even occasionally
    /// resumes from its own token; one that's been asleep longer re-baselines instead (see
    /// `processRemoteChanges`).
    public func purgeExpiredHistory() {
        let cutoff = Calendar.current.date(byAdding: historyRetention, to: .now) ?? .now
        let request = NSPersistentHistoryChangeRequest.deleteHistory(before: cutoff)

        do {
            try container.viewContext.execute(request)
        } catch {
            print("Failed to purge persistent history: \(error.localizedDescription)")
        }
    }
}
