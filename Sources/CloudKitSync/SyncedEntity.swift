//
//  SyncedEntity.swift
//  CloudKitSync
//

import Foundation

/// One Core Data entity `SyncCoordinator` should track changes for.
///
/// The entity's `uuid` attribute must be marked "Preserve After Deletion" in the model — a
/// deletion can only be reported by uuid via its tombstone, since the row itself is gone by the
/// time history is read.
public struct SyncedEntity {
    /// The `NSEntityDescription.name` this config applies to, e.g. `"Event"`.
    public let name: String
    public let broadcaster: ChangeBroadcaster
    /// Relationships whose *targets* should also be reported changed when this entity changes —
    /// Countdown's case is a `Group` or `WidgetConfig` update needing to touch every `Event` that
    /// references it, since a relationship edit can land as a write to only one side.
    public let cascades: [CascadeRelationship]

    public init(name: String, broadcaster: ChangeBroadcaster, cascades: [CascadeRelationship] = []) {
        self.name = name
        self.broadcaster = broadcaster
        self.cascades = cascades
    }
}

/// A to-many relationship on a `SyncedEntity` whose targets get reported changed alongside it.
public struct CascadeRelationship {
    /// The relationship's key, e.g. `"events"` on `Group`.
    public let key: String
    public let targetBroadcaster: ChangeBroadcaster

    public init(key: String, targetBroadcaster: ChangeBroadcaster) {
        self.key = key
        self.targetBroadcaster = targetBroadcaster
    }
}
