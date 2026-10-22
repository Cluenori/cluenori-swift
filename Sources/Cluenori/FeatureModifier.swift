import SwiftUI

extension View {
    /// Marks the feature the person is in while this view shows, `cards.flip`: signals recorded and
    /// requests prepared meanwhile belong to it. Of the views shown, the one that appeared last wins,
    /// so a sheet's feature is in effect over the screen beneath it.
    public func cluenoriFeature(_ key: String) -> some View {
        modifier(FeatureModifier(key: key))
    }
}

private struct FeatureModifier: ViewModifier {
    let key: String
    @State private var mark: FeatureMark?

    func body(content: Content) -> some View {
        content
            .onAppear {
                mark?.end()
                mark = Cluenori.begin(feature: key)
            }
            .onDisappear {
                mark?.end()
                mark = nil
            }
            .onChange(of: key) {
                guard mark != nil else { return }
                mark?.end()
                mark = Cluenori.begin(feature: key)
            }
    }
}
