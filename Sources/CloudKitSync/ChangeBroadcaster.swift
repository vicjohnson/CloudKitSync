//
//  ChangeBroadcaster.swift
//  CloudKitSync
//

import Foundation

public enum ChangeKind: Equatable {
    case created, updated, deleted
}

/// What changed, identified by uuid rather than by model object — the only honest payload for
/// `.deleted`, where there's no object left to hand out. Consumers that need the entity fetch it.
public struct Change {
    public let uuid: UUID
    public let kind: ChangeKind

    public init(uuid: UUID, kind: ChangeKind) {
        self.uuid = uuid
        self.kind = kind
    }
}

/// One entity type's change listeners, plus the batch currently being accumulated.
///
/// Delivery is per batch rather than per change, so a listener whose work is proportional to the
/// whole collection rather than to one entity does that work once per flush. An import that
/// touches hundreds of rows arrives as a single callback.
///
/// Subscriptions have no deregistration — every subscriber lives as long as the process. Add a
/// token if something short-lived ever needs to subscribe.
public final class ChangeBroadcaster {
    private var listeners: [([Change]) -> Void] = []
    private var pending: [Change] = []
    private var isBatching = false

    public init() {}

    public func subscribe(_ listener: @escaping ([Change]) -> Void) {
        listeners.append(listener)
    }

    public func record(_ uuid: UUID, _ kind: ChangeKind) {
        if let index = pending.firstIndex(where: { $0.uuid == uuid }) {
            pending[index] = Change(uuid: uuid, kind: Self.collapse(pending[index].kind, kind))
        } else {
            pending.append(Change(uuid: uuid, kind: kind))
        }
    }

    /// Holds delivery until `endBatch()`, for operations that mutate repeatedly and would
    /// otherwise flush after each one.
    public func beginBatch() {
        isBatching = true
    }

    public func endBatch() {
        isBatching = false
        flush()
    }

    public func flush() {
        guard !isBatching, !pending.isEmpty else {
            return
        }

        let batch = pending
        pending = []

        for listener in listeners {
            listener(batch)
        }
    }

    /// Collapses repeat changes to the same uuid within one batch, so a consumer sees each entity
    /// once. The newer kind wins, except where nothing outside has seen the older one yet: created
    /// then updated is still a creation, and deleted then re-created is a creation, not a delete.
    private static func collapse(_ old: ChangeKind, _ new: ChangeKind) -> ChangeKind {
        switch (old, new) {
        case (.created, .updated): return .created
        case (.deleted, .created): return .created
        default: return new
        }
    }
}
