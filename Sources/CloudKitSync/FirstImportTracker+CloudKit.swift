//
//  FirstImportTracker+CloudKit.swift
//  CloudKitSync
//

import CloudKit
import Foundation
import CoreData

extension FirstImportTracker {
    /// Builds a tracker wired to a container's own import notifications.
    ///
    /// Assumes signed-in optimistically rather than checking `FileManager.ubiquityIdentityToken`
    /// up front — that token has been observed to read nil for an already-signed-in watchOS
    /// account right at cold launch. Instead this confirms the account status asynchronously via
    /// `CKContainer`, and only corrects the tracker if it actually comes back as no-account.
    @MainActor
    public static func make(
        container: NSPersistentCloudKitContainer,
        userDefaults: UserDefaults?,
        firstImportCompleteKey: String,
        hasDataAlready: Bool,
        onImportFinished: @escaping () -> Void
    ) -> FirstImportTracker {
        let tracker = FirstImportTracker(
            userDefaults: userDefaults,
            firstImportCompleteKey: firstImportCompleteKey,
            hasDataAlready: hasDataAlready,
            observeImportEvents: { handler in
                RemoteChangeObservation.observeImportEvents(container: container, handler)
            },
            onImportFinished: onImportFinished
        )

        // The container the store actually mirrors to. `CKContainer.default()` is the one named
        // after the bundle ID, which a target sharing another app's container (a watch app, say)
        // isn't entitled to, so its status check just errors out.
        guard let containerIdentifier = container.persistentStoreDescriptions.first?.cloudKitContainerOptions?.containerIdentifier else {
            return tracker
        }

        CKContainer(identifier: containerIdentifier).accountStatus { status, _ in
            guard status == .noAccount || status == .restricted else { return }
            Task { @MainActor in
                tracker.reportNoCloudAccount()
            }
        }

        return tracker
    }
}
