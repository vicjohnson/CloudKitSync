# CloudKitSync

A small Swift package that turns `NSPersistentCloudKitContainer` merges into per-entity change
callbacks, and tracks whether a store's first CloudKit import has finished. It's built for apps
that keep an in-memory model (e.g. `@Observable` view models) in sync with a CloudKit-backed Core
Data store, without refetching and diffing the whole store on every merge.

- **`SyncCoordinator`** reads Core Data persistent history to figure out exactly what changed, and
  reports it per-entity via `ChangeBroadcaster`.
- **`FirstImportTracker`** tells "still syncing" apart from "genuinely empty" for a fresh install.
- **`Mergeable`** / `Array` helpers apply those changes to a collection in place, preserving object
  identity and existing sort order.

Supports iOS 17+, macOS 14+, watchOS 10+, tvOS 17+.

## Installation

Add it as a Swift Package Manager dependency:

```swift
.package(url: "<repository URL>", from: "1.0.0")
```

and add `"CloudKitSync"` to your target's dependencies.

## Requirements on your Core Data model

For each entity you want to track:

1. It must have a `uuid: UUID` attribute, used as its stable identity.
2. That attribute must be marked **"Preserve After Deletion"** in the model editor. A delete can
   only be reported by reading its tombstone from persistent history — by the time history is
   read, the row itself is gone, so without this the uuid can't be recovered.

Your `NSPersistentCloudKitContainer` must have:

- Persistent history tracking enabled (`NSPersistentHistoryTrackingKey`).
- Remote change notifications enabled (`NSPersistentStoreRemoteChangeNotificationPostOptionKey`).
- `viewContext.transactionAuthor` set to a string unique to this process/target — this is what
  lets `SyncCoordinator` tell "a CloudKit merge" apart from "this process's own write" and avoid
  re-emitting the latter as if it came from outside.

```swift
let description = container.persistentStoreDescriptions.first!
description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

container.viewContext.transactionAuthor = "com.example.app.main"
```

## Implementation guide

### 1. Wire up a `ChangeBroadcaster` per tracked entity

Each entity you want change notifications for gets one broadcaster. Somewhere your view model or
data layer already owns:

```swift
let childBroadcaster = ChangeBroadcaster()
let parentBroadcaster = ChangeBroadcaster()

childBroadcaster.subscribe { changes in
    // apply(changes) to an in-memory collection — see step 4
}
```

Subscriptions have no deregistration — a broadcaster's listeners live as long as the process, so
subscribe once at setup, not per-view.

### 2. Describe your entities to a `SyncCoordinator`

```swift
let entities: [SyncedEntity] = [
    SyncedEntity(name: "Child", broadcaster: childBroadcaster),
    SyncedEntity(
        name: "Parent",
        broadcaster: parentBroadcaster,
        // When a Parent changes, also report every Child that references it as changed — a
        // relationship edit can land as a write to only one side of the relationship.
        cascades: [CascadeRelationship(key: "children", targetBroadcaster: childBroadcaster)]
    ),
]

let syncCoordinator = SyncCoordinator(
    container: container,
    entities: entities,
    historyTokenDefaults: .standard,
    historyTokenKey: "com.example.app.main.historyToken",
    transactionAuthor: "com.example.app.main"
)

syncCoordinator.startProcessingRemoteChanges()
```

Notes:

- `historyTokenKey` (and `transactionAuthor`) must be unique per process/target. If more than one
  target shares the store (e.g. a widget extension, a watch app), use an App Group `UserDefaults`
  suite and scope the key per author so each target tracks its own position independently.
- Only the write-capable target(s) of your app should call `startProcessingRemoteChanges()`. A
  read-only extension can instead just reload from a remote-change or import notification without
  driving history processing itself.
- Call `startProcessingRemoteChanges()` once, early (e.g. app launch). It's a no-op if called
  again.
- `purgeExpiredHistory()` runs automatically when processing starts; nothing else prunes history,
  so without it the store grows unbounded. The default retention is 7 days — make sure it's
  comfortably longer than the app's realistic max time between launches, since a token older than
  the retention window forces a silent re-baseline (see below).

### 3. Emit changes from your own local writes too

`SyncCoordinator` only reports changes whose transaction author is *not* this process — your own
writes are assumed to already emit synchronously from the code that made them. That means your
mutation methods should call `broadcaster.record(uuid, kind)` (and `flush()`, or
`beginBatch()`/`endBatch()` around a batch of writes) themselves:

```swift
func addChild(_ child: Child) {
    // ... insert into Core Data, save ...
    childBroadcaster.record(child.uuid, .created)
    childBroadcaster.flush()
}
```

This is why `ChangeBroadcaster` is a plain, standalone class rather than something
`SyncCoordinator` owns privately — both local writes and remote merges feed the same broadcaster.

### 4. Apply changes to your in-memory model

Make your model type conform to `Mergeable`:

```swift
final class Child: Mergeable {
    let uuid: UUID
    var title: String
    // ...

    func update(from other: Child) {
        title = other.title
        // ... copy every other field ...
    }
}
```

Then, in each broadcaster subscription, apply the batch to your array:

```swift
childBroadcaster.subscribe { [weak self] changes in
    self?.children.apply(changes, sortedBy: { $0.sortOrder < $1.sortOrder }) { uuid in
        try? fetchChild(uuid: uuid) // read the current Core Data row and map to `Child`
    }
}
```

`apply(_:sortedBy:fetch:)`:

- Fetches and merges the current value for each created/updated uuid, updating an existing object
  **in place** (via `update(from:)`) rather than replacing it — so anything already holding a
  reference to it (e.g. SwiftUI state, a selection) keeps working.
- Re-inserts an updated object at the correct sorted position if the update changed its sort key.
- Removes deleted uuids.
- Skips a uuid that no longer resolves (its deletion is either later in the same batch, or already
  applied).

Pass `sortedBy: nil` for collections with no meaningful order (appends new items instead of
positioning them).

For a full re-fetch (e.g. at launch, or recovering from a re-baseline — see below), use
`reconcile(with:sortedBy:)` instead, which merges a freshly fetched array in and drops anything the
fetch no longer returns.

### 5. Track first-import state for your empty-state UI

A fresh install can spend a couple of minutes on its first CloudKit import, arriving in batches —
during that window a genuinely-empty store and a still-syncing store look identical unless you
track the import explicitly.

```swift
let firstImportTracker = FirstImportTracker.make(
    container: container,
    userDefaults: .standard,
    firstImportCompleteKey: "com.example.app.hasCompletedFirstImport",
    hasDataAlready: !children.isEmpty, // checked once at init
    onImportFinished: {
        // An import that brought nothing new down posts no remote-change notification, so this is
        // the only signal for that case — re-fetch/reconcile here if you need to.
    }
)
```

Drive your UI off its published state:

```swift
var loadState: FirstImportTracker.LoadState {
    if !firstImportTracker.hasCompletedFirstImport { return .syncing }
    return children.isEmpty ? .empty : .loaded
}
```

`firstImportTracker.syncIsSlow` flips to `true` after `slowSyncThreshold` (default 30s) if the
first import still hasn't finished — use it to show an explanatory message rather than a bare
spinner. `maxImportWait` (default 60s) is a backstop that gives up waiting even if the expected
CloudKit event never arrives, so the UI never gets stuck on "syncing" forever.

### 6. Observing without driving history (secondary targets)

A target that only reads (a widget, a watch complication provider) doesn't need its own
`SyncCoordinator`. It can observe remote changes or import completion directly and reload:

```swift
let token = RemoteChangeObservation.observeRemoteChanges(container: container) {
    // reload / re-fetch
}
```

Retain the returned `NSObjectProtocol` token for as long as the observation should live.

## Re-baselining

If `SyncCoordinator` finds no saved history token (fresh install, or a target running for the
first time), or the saved token is older than `historyRetention` and history can no longer explain
everything since, it silently adopts the current history position without emitting any changes.
Consumers are expected to do a full fetch on init and on foreground to cover that gap —
`reconcile(with:sortedBy:)` is the tool for folding that fetch into an existing in-memory
collection.

## Testing

```
swift test
```
