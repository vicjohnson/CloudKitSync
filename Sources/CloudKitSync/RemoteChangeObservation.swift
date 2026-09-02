//
//  RemoteChangeObservation.swift
//  CloudKitSync
//

import Foundation
import CoreData

/// Notification wrappers for `NSPersistentCloudKitContainer` events. Free functions rather than
/// container-owned methods, since neither depends on anything but the container passed in.
public enum RemoteChangeObservation {
    /// Calls `handler` on the main actor whenever CloudKit merges changes into the store,
    /// so callers can reload without knowing about Core Data. Retain the returned token for
    /// as long as the observation should live.
    public static func observeRemoteChanges(
        container: NSPersistentCloudKitContainer,
        _ handler: @escaping @MainActor () -> Void
    ) -> NSObjectProtocol {
        return NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                // A potential optimization is to only handle if changes originated from elsewhere:
                // https://developer.apple.com/documentation/coredata/consuming-relevant-store-changes
                handler()
            }
        }
    }

    /// Calls `handler` on the main actor as CloudKit import activity starts and stops, passing
    /// `true` once an import has finished. A fresh install can spend a couple of minutes on its
    /// first import, so callers use this to tell "still arriving" apart from "there's nothing".
    /// Retain the returned token for as long as the observation should live.
    public static func observeImportEvents(
        container: NSPersistentCloudKitContainer,
        _ handler: @escaping @MainActor (_ didFinish: Bool, _ failed: Bool) -> Void
    ) -> NSObjectProtocol {
        return NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: .main
        ) { notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else {
                return
            }

            // Any failed event — including a `.setup` failure from a restricted or unavailable
            // container — means the data isn't coming. Report it as finished so callers stop
            // waiting on an import that will never arrive.
            if event.error != nil {
                MainActor.assumeIsolated {
                    handler(true, true)
                }
                return
            }

            guard event.type == .import else {
                return
            }

            // A nil endDate means the import is still in flight.
            let didFinish = event.endDate != nil

            MainActor.assumeIsolated {
                handler(didFinish, false)
            }
        }
    }
}
