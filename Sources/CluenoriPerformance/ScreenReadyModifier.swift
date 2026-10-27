import Cluenori
import SwiftUI

extension View {
    /// Says this screen has its first content of this kind once `condition` is true, as
    /// `Cluenori.screenReady(_:)` does: `.kept` when it draws what the device kept, `.fresh` when the
    /// network brought it up to date.
    @MainActor
    public func cluenoriScreenReady(_ readiness: ScreenReadiness, when condition: Bool) -> some View {
        onChange(of: condition, initial: true) {
            if condition { Cluenori.screenReady(readiness) }
        }
    }
}
