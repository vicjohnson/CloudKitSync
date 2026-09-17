//
//  FirstImportTracker.swift
//  CloudKitSync
//

import Foundation
import Observation

/// Tracks whether a CloudKit-backed store has finished its first import, so a UI can tell "still
/// syncing" apart from "genuinely empty," and warn when that first import is taking unusually long.
///
/// This deliberately knows nothing about *what* changed — a `ChangeBroadcaster` covers that. It
/// exists for the case that structurally can't report: a store that's still importing produces no
/// changes at all, so silence is ambiguous without a separate completion signal.
///
/// Depends only on the import-observation closure, not on Core Data or any app's models.
@MainActor
@Observable
public final class FirstImportTracker {
    // How much of the store has arrived from CloudKit, so the UI can show the right empty state.
    public enum LoadState {
        case syncing // Nothing yet, and the first import hasn't finished. More may be on its way.
        case empty // The first import finished and there genuinely is nothing.
        case loaded
    }

    // False until CloudKit has finished its first import on this device. A fresh install can
    // take a couple of minutes, and data trickles in a batch at a time, so this stays false
    // even after the first few records land.
    public private(set) var hasCompletedFirstImport: Bool

    // Set once the first import has been running long enough to be worth explaining.
    public private(set) var syncIsSlow = false

    private let userDefaults: UserDefaults?
    private let firstImportCompleteKey: String
    private let slowSyncThreshold: Duration
    private let maxImportWait: Duration
    private let onImportFinished: () -> Void

    private var importEventObserver: NSObjectProtocol?
    private var slowSyncTask: Task<Void, Never>?
    private var importSettleTask: Task<Void, Never>?
    private var maxWaitTask: Task<Void, Never>?

    /// - Parameters:
    ///   - userDefaults: Where `hasCompletedFirstImport` is persisted, so it survives relaunches. Pass
    ///     nil (e.g. in previews) to keep it in memory only.
    ///   - firstImportCompleteKey: The UserDefaults key to persist under. Scope this per-app/per-store
    ///     if more than one tracker shares the same suite.
    ///   - hasDataAlready: Checked once at init; a store restored from a backup already has its data,
    ///     so there's nothing to wait for.
    ///   - isSignedIntoCloud: Checked once at init. With no iCloud account there's no import coming
    ///     and no events will ever fire, so waiting for one would hang on "syncing" forever.
    ///   - observeImportEvents: Starts observing CloudKit import activity, passing `didFinish` once a
    ///     batch has finished and `failed` when the event carried an error. Retain nothing — the
    ///     tracker owns the returned token.
    ///   - onImportFinished: Called on the main actor when an import batch finishes. An import that
    ///     brought nothing down posts no remote-change notification, so this is the only signal for
    ///     that case.
    public init(
        userDefaults: UserDefaults?,
        firstImportCompleteKey: String,
        slowSyncThreshold: Duration = .seconds(30),
        maxImportWait: Duration = .seconds(60),
        hasDataAlready: Bool,
        isSignedIntoCloud: Bool = true,
        observeImportEvents: (@escaping @MainActor (_ didFinish: Bool, _ failed: Bool) -> Void) -> NSObjectProtocol,
        onImportFinished: @escaping () -> Void
    ) {
        self.userDefaults = userDefaults
        self.firstImportCompleteKey = firstImportCompleteKey
        self.slowSyncThreshold = slowSyncThreshold
        self.maxImportWait = maxImportWait
        self.onImportFinished = onImportFinished
        self.hasCompletedFirstImport = userDefaults?.bool(forKey: firstImportCompleteKey) ?? false

        // Nothing to wait for in either case: the store already has data, or there's no account
        // for it to arrive from. The second one matters most — signed out, no import event ever
        // fires, so anything waiting on one waits forever.
        if hasDataAlready {
            markFirstImportComplete()
        } else if !isSignedIntoCloud {
            // Not persisted: if they sign in later, a first import should still be able to show
            // its syncing state rather than having been permanently marked done.
            markFirstImportComplete(persist: false)
        }

        // Registering after `observeImportEvents` is called risks missing a "finished" event that
        // fires on the same runloop turn (the empty-import fast path), which would leave this stuck
        // on `.syncing` forever with nothing left to unstick it — so the max-wait fallback below
        // exists for exactly that case, and any other where the expected event just never arrives.
        importEventObserver = observeImportEvents { [weak self] didFinish, failed in
            self?.handleImportEvent(didFinish: didFinish, failed: failed)
        }

        startSlowSyncTimerIfNeeded()
        startMaxWaitTimerIfNeeded()
    }

    // MARK: - Private

    private func handleImportEvent(didFinish: Bool, failed: Bool) {
        // Any import activity means another batch is either starting or has just
        // finished, so don't settle on a completion we're about to supersede.
        importSettleTask?.cancel()

        // A failure means the data isn't coming, so stop waiting — but don't persist it, since
        // whatever went wrong may well be gone by the next launch.
        if failed {
            markFirstImportComplete(persist: false)
            return
        }

        guard didFinish else { return }

        onImportFinished()

        // The first import often arrives as several back-to-back batches — an empty
        // zone-setup batch followed by the real data — so wait a moment for another
        // batch to start before treating this as "sync done." Otherwise this can latch
        // onto the setup batch and leave a fresh install stuck on an empty state.
        importSettleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.markFirstImportComplete()
        }
    }

    /// Corrects an optimistic "signed in" assumption once the caller has confirmed — asynchronously,
    /// via CloudKit's own account status — that there's actually no account to import from. Safe to
    /// call even after a real import has already completed; `markFirstImportComplete` is a no-op then.
    ///
    /// This exists separately from the `isSignedIntoCloud` init parameter because the obvious
    /// synchronous check (`FileManager.ubiquityIdentityToken`) is not reliable: on watchOS it has
    /// been observed to read nil for a couple of seconds on an already-signed-in device, right at
    /// cold launch, while `CKContainer.accountStatus` correctly reports `.available` at the same
    /// moment. Trusting the token there flashed the empty state before events had a chance to load.
    public func reportNoCloudAccount() {
        markFirstImportComplete(persist: false)
    }

    /// - Parameter persist: Pass false when settling for a reason that might not hold next launch —
    ///   no iCloud account, or a failed CloudKit event. Persisting those would mean the syncing
    ///   state never appears again even once the condition clears.
    private func markFirstImportComplete(persist: Bool = true) {
        slowSyncTask?.cancel()
        slowSyncTask = nil
        maxWaitTask?.cancel()
        maxWaitTask = nil
        syncIsSlow = false

        guard !hasCompletedFirstImport else { return }

        hasCompletedFirstImport = true

        if persist {
            userDefaults?.set(true, forKey: firstImportCompleteKey)
        }
    }

    private func startSlowSyncTimerIfNeeded() {
        guard !hasCompletedFirstImport else { return }

        slowSyncTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.slowSyncThreshold)

            guard !Task.isCancelled else { return }

            self.syncIsSlow = true
        }
    }

    /// Backstop for the case `observeImportEvents` misses the finished event it was registered
    /// for (see the init comment) — without this, a missed event leaves `loadState` stuck on
    /// `.syncing` forever with no way to recover short of a relaunch.
    private func startMaxWaitTimerIfNeeded() {
        guard !hasCompletedFirstImport else { return }

        maxWaitTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.maxImportWait)

            guard !Task.isCancelled else { return }

            self.markFirstImportComplete()
        }
    }
}
