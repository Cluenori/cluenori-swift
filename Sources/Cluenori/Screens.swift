import Foundation
import Synchronization

/// One time a screen showed: from appearing to the next screen shown. Its ID is that of the `screen`
/// signal recorded as it appeared, which its readiness and its visit refer to.
package struct ScreenVisit: Equatable, Sendable {
    package let id: String
    package let name: String
    package let appearedAt: Date

    package init(id: String, name: String, appearedAt: Date) {
        self.id = id
        self.name = name
        self.appearedAt = appearedAt
    }
}

/// The screen the person is on now, the one shown last, so every signal says where it happened;
/// and who wants to know when it changes, such as CluenoriPerformance, which measures each visit.
/// Read wherever a signal is recorded, so it is a lock away, never a hop. Screens may be shown on any
/// thread; observers hear each change on the thread that showed it, or one shown at the same time,
/// one at a time and in the order the screens were shown.
package final class Screens: Sendable {
    /// Must not show a screen: it is called while the screens' changes are told, one at a time.
    package typealias Observer = @Sendable (_ left: ScreenVisit?, _ shown: ScreenVisit) -> Void

    private struct State {
        var current: ScreenVisit?
        var observers: [Observer] = []
        /// The changes not told yet, oldest first.
        var untold: [(left: ScreenVisit?, shown: ScreenVisit)] = []
    }

    private let state = Mutex(State())
    /// Held while changes are told, so they are told one at a time, in order.
    private let telling = Mutex(())

    package init() {}

    /// The screen shown now; nil before the first.
    package var current: ScreenVisit? { state.withLock { $0.current } }

    /// Calls `observer` with each screen shown from now on, and the visit it ended.
    package func observe(_ observer: @escaping Observer) {
        state.withLock { $0.observers.append(observer) }
    }

    /// Makes `visit` the current one, then tells the observers each change not told yet, outside the
    /// state's lock: this one, and any another thread made meanwhile, in the order they were made.
    func show(_ visit: ScreenVisit) -> ScreenVisit {
        state.withLock { state in
            state.untold.append((state.current, visit))
            state.current = visit
        }
        telling.withLock { _ in
            while let (change, observers) = state.withLock({ state in
                state.untold.isEmpty ? nil : (state.untold.removeFirst(), state.observers)
            }) {
                for observer in observers { observer(change.left, change.shown) }
            }
        }
        return visit
    }
}
