import Foundation
import Synchronization

/// The feature the person is in now, by two marks: the screens shown, each from appearing to
/// disappearing (`cluenoriFeature(_:)`, `Cluenori.begin(feature:)`), and the work done for one,
/// inside `Cluenori.feature(_:_:)`. The work's feature wins, and of the screens, the one shown last.
/// Read wherever a signal is recorded or a request is sent, so it is a lock away, never a hop.
final class Features: Sendable {
    @TaskLocal static var working: String?

    private struct Marks {
        var next: UInt64 = 1
        var shown: [(mark: UInt64, key: String)] = []
    }

    private let marks = Mutex(Marks())

    /// The feature in effect where this is called.
    var current: String? {
        Self.working ?? marks.withLock { $0.shown.last?.key }
    }

    /// Marks `key` shown; it stays the screens' feature until `end(_:)`, or until a screen marked
    /// after it ends.
    func begin(_ key: String) -> UInt64 {
        marks.withLock { marks in
            let mark = marks.next
            marks.next += 1
            marks.shown.append((mark, key))
            return mark
        }
    }

    func end(_ mark: UInt64) {
        marks.withLock { marks in marks.shown.removeAll { $0.mark == mark } }
    }
}

/// A feature marked shown by `Cluenori.begin(feature:)`, until `end()`: what a screen does from
/// appearing to disappearing. Ending it twice does nothing.
public struct FeatureMark: Sendable {
    let features: Features?
    let mark: UInt64

    /// Ends the mark: the feature marked before it is the current one again.
    public func end() {
        features?.end(mark)
    }
}
