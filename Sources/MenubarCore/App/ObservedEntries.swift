import Foundation
import Observation

/// A store's entries by key, each observed on its own: a view that reads one entry is drawn again when that entry
/// changes, not when any other does. A store that kept its entries in one observed dictionary woke every view that
/// read any entry at each change, such as every detail of the window while one item loaded.
///
/// Reading a key that has no entry yet observes it too, so the reader learns when it comes.
@MainActor
public final class ObservedEntries<Key: Hashable, Value> {
    @Observable
    @MainActor
    final class Box {
        var value: Value?

        init() {}
    }

    @Observable
    @MainActor
    final class Revision {
        var count = 0

        init() {}
    }

    private var boxes: [Key: Box] = [:]
    private let revision = Revision()

    public init() {}

    /// the entry of a key; `nil` for none. Setting it wakes the readers of this key and of ``all``.
    public internal(set) subscript(key: Key) -> Value? {
        get {
            box(key).value
        }
        set {
            box(key).value = newValue
            revision.count += 1
        }
    }

    /// every entry; reading it wakes the reader at any change
    public var all: [Key: Value] {
        _ = revision.count
        return boxes.compactMapValues(\.value)
    }

    /// the keys that have an entry; reading them wakes the reader at any change
    public var keys: [Key] {
        Array(all.keys)
    }

    /// Removes every entry.
    func removeAll() {
        for box in boxes.values where box.value != nil {
            box.value = nil
        }
        revision.count += 1
    }

    private func box(_ key: Key) -> Box {
        if let box = boxes[key] {
            return box
        }
        let box = Box()
        boxes[key] = box
        return box
    }
}
