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
        slowSyncThreshold: Duration = .seconds(30),
        maxImportWait: Duration = .seconds(60),
        hasDataAlready: Bool,
        onImportFinished: @escaping () -> Void
    ) -> FirstImportTracker {
        let tracker = FirstImportTracker(
            userDefaults: userDefaults,
            firstImportCompleteKey: firstImportCompleteKey,
            slowSyncThreshold: slowSyncThreshold,
            maxImportWait: maxImportWait,
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

        CKContainer(identifier: containerIdentifier).accountStatus { status, error in
            print("CloudKitSync: account status \(status.rawValue) (0 unknown, 1 available, 2 restricted, 3 noAccount, 4 temporarilyUnavailable), error: \(String(describing: error))")
            guard status == .noAccount || status == .restricted else { return }
            Task { @MainActor in
                tracker.reportNoCloudAccount()
            }
        }

        probeReachability(containerIdentifier: containerIdentifier)

        return tracker
    }

    // TEMPORARY: diagnoses a stalled `setup` event by talking to CloudKit directly, bypassing
    // Core Data's mirroring. Remove once the stall is understood.
    private static func probeReachability(containerIdentifier: String) {
        let started = Date()
        let finished = ProbeFlag()

        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        database.fetchAllRecordZones { zones, error in
            finished.set()
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
            if let error {
                let nsError = error as NSError
                print("CloudKitSync: probe failed after \(elapsed)s (\(nsError.domain) \(nsError.code)): \(nsError.localizedDescription) \(nsError.userInfo)")
            } else {
                let names = (zones ?? []).map(\.zoneID.zoneName)
                print("CloudKitSync: probe OK after \(elapsed)s, zones: \(names)")
            }
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            if !finished.isSet {
                print("CloudKitSync: probe got no response after 20s")
            }
        }
    }
}

private final class ProbeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
