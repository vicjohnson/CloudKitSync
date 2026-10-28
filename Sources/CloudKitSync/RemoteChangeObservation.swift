//
//  RemoteChangeObservation.swift
//  CloudKitSync
//

import CloudKit
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
        print("CloudKitSync: observing import events")
        return NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: container,
            queue: .main
        ) { notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else {
                print("CloudKitSync: event notification without an event")
                return
            }
            print("CloudKitSync: \(event.type) event, finished: \(event.endDate != nil), succeeded: \(event.succeeded), error: \(String(describing: event.error))")

            // Only an error that won't clear on its own (no account, restricted, misconfigured
            // container) means the data isn't coming. Anything else — network, throttling, a
            // zone-setup hiccup — is retried by CloudKit with backoff, so keep waiting rather
            // than settling on an empty state while the real import is still ahead.
            if let error = event.error {
                let nsError = error as NSError
                print("CloudKitSync: \(event.type) event failed (\(nsError.domain) \(nsError.code), terminal: \(isTerminal(error))): \(nsError.localizedDescription) \(nsError.userInfo)")
                if isTerminal(error) {
                    MainActor.assumeIsolated {
                        handler(true, true)
                    }
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

    /// Whether a CloudKit event error will keep failing no matter how many times it's retried.
    private static func isTerminal(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .notAuthenticated, .permissionFailure, .managedAccountRestricted,
             .badContainer, .missingEntitlement:
            return true
        default:
            return false
        }
    }
}
