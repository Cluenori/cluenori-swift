import Cluenori
import SwiftUI

extension View {
    /// Records that this screen was shown, by the name the app gives it, `card` or `profile.edit`,
    /// each time it appears.
    public func cluenoriScreen(_ name: String) -> some View {
        onAppear { Analytics.screen(name, on: .shared) }
    }
}
