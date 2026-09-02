//
//  Mergeable.swift
//  CloudKitSync
//

import Foundation

/// A model that can be matched by identity and take on a fresher copy's values in place, which is
/// all the `Array` extension below needs to keep a collection in step with the store.
public protocol Mergeable: AnyObject {
    var uuid: UUID { get }
    func update(from other: Self)
}

extension Array {
    /// Where `element` belongs in an already-sorted array. Change callbacks deliver one entity at
    /// a time, so a newly created one has to be placed rather than appended — otherwise the array
    /// drifts out of the order the original fetch returned it in.
    func insertionIndex(of element: Element, by areInIncreasingOrder: (Element, Element) -> Bool) -> Int {
        return firstIndex(where: { areInIncreasingOrder(element, $0) }) ?? count
    }
}

extension Array where Element: Mergeable {
    /// Folds a fresher copy into the array: a matching uuid is updated in place, anything else is
    /// inserted. Replacing the instance instead would detach whatever already holds a reference to
    /// it, and every later update would land on an object nobody is reading.
    ///
    /// - Parameter isBefore: the order the array is kept in, so an insertion lands where a full
    ///   fetch would have put it. `nil` appends, for collections with no meaningful order.
    public mutating func merge(_ fresh: Element, sortedBy isBefore: ((Element, Element) -> Bool)? = nil) {
        if let index = firstIndex(where: { $0.uuid == fresh.uuid }) {
            let existing = self[index]
            existing.update(from: fresh)

            // The update may have changed whatever `existing` is sorted by, so re-seat it rather
            // than leaving it in its old slot.
            if let isBefore {
                remove(at: index)
                insert(existing, at: insertionIndex(of: existing, by: isBefore))
            }
        } else if let isBefore {
            insert(fresh, at: insertionIndex(of: fresh, by: isBefore))
        } else {
            append(fresh)
        }
    }

    /// Applies one batch of changes, merging or removing each by uuid.
    ///
    /// - Parameter fetch: reads the current state of one uuid. A uuid that no longer resolves is
    ///   skipped: the deletion that explains it is either later in this batch or already applied.
    public mutating func apply(
        _ changes: [Change],
        sortedBy isBefore: ((Element, Element) -> Bool)? = nil,
        fetch: (UUID) -> Element?
    ) {
        for change in changes {
            switch change.kind {
            case .created, .updated:
                // `.updated` for something we've never seen arrived while we weren't listening.
                // `merge` inserts it rather than dropping it.
                guard let fresh = fetch(change.uuid) else { continue }
                merge(fresh, sortedBy: isBefore)
            case .deleted:
                removeAll(where: { $0.uuid == change.uuid })
            }
        }
    }

    /// Brings the array in line with a full fetch: everything fetched merged in, and anything the
    /// fetch didn't return dropped as deleted elsewhere.
    public mutating func reconcile(with fetched: [Element], sortedBy isBefore: ((Element, Element) -> Bool)? = nil) {
        for fresh in fetched {
            merge(fresh, sortedBy: isBefore)
        }

        let uuids = Set(fetched.map(\.uuid))
        removeAll(where: { !uuids.contains($0.uuid) })
    }
}
