import Testing
@testable import CloudKitSync
import Foundation

@Suite struct ChangeBroadcasterTests {
    @Test func batchesUntilFlush() {
        let broadcaster = ChangeBroadcaster()
        var received: [[Change]] = []
        broadcaster.subscribe { received.append($0) }

        let uuid = UUID()
        broadcaster.record(uuid, .created)
        #expect(received.isEmpty)

        broadcaster.flush()
        #expect(received.count == 1)
        #expect(received[0].first?.kind == .created)
    }

    @Test func collapsesCreatedThenUpdatedToCreated() {
        let broadcaster = ChangeBroadcaster()
        var received: [Change] = []
        broadcaster.subscribe { received = $0 }

        let uuid = UUID()
        broadcaster.record(uuid, .created)
        broadcaster.record(uuid, .updated)
        broadcaster.flush()

        #expect(received.count == 1)
        #expect(received[0].kind == .created)
    }

    @Test func holdsDeliveryDuringBatch() {
        let broadcaster = ChangeBroadcaster()
        var callCount = 0
        broadcaster.subscribe { _ in callCount += 1 }

        broadcaster.beginBatch()
        broadcaster.record(UUID(), .created)
        broadcaster.record(UUID(), .created)
        broadcaster.flush()
        #expect(callCount == 0)

        broadcaster.endBatch()
        #expect(callCount == 1)
    }
}
