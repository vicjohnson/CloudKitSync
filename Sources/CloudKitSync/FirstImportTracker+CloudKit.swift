//
//  FirstImportTracker+CloudKit.swift
//  CloudKitSync
//

import Foundation
import CoreData

extension FirstImportTracker {
    /// Builds a tracker wired to a container's own import notifications.
    @MainActor
    public static func make(
        container: NSPersistentCloudKitContainer,
        userDefaults: UserDefaults?,
        firstImportCompleteKey: String,
        hasDataAlready: Bool,
        onImportFinished: @escaping () -> Void
    ) -> FirstImportTracker {
        FirstImportTracker(
            userDefaults: userDefaults,
            firstImportCompleteKey: firstImportCompleteKey,
            hasDataAlready: hasDataAlready,
            // Signed out, CloudKit posts no import events at all, so anything waiting on one
            // would wait forever.
            isSignedIntoCloud: FileManager.default.ubiquityIdentityToken != nil,
            observeImportEvents: { handler in
                RemoteChangeObservation.observeImportEvents(container: container, handler)
            },
            onImportFinished: onImportFinished
        )
    }
}
