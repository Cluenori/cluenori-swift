import Cluenori
import Foundation
import SwiftUI

// Every state of the gate, as the person sees it: with the SDK's words and with a project's, in
// both appearances, at a large text size, and in Ukrainian.

private let offer = UpdateOffer(
    version: "0.4.0", storeURL: URL(string: "https://apps.apple.com/app/id123")!, minimumOSVersion: "26.0")

private let worded = UpdateOffer(
    version: "0.4.0", storeURL: URL(string: "https://apps.apple.com/app/id123")!, minimumOSVersion: "26.0",
    title: "Notes has a big update", message: "Sync is faster, and this version can no longer reach your notes.")

private let longWords = UpdateOffer(
    version: "12.40.1", storeURL: URL(string: "https://apps.apple.com/app/id123")!, minimumOSVersion: "99.0",
    title: "We rebuilt sync from the ground up, so every device stays current",
    message: String(
        repeating: "This version can no longer sync your notes, because the service it talks to has moved on. ",
        count: 5
    ).trimmingCharacters(in: .whitespaces))

/// An app's screen with a soft prompt over it, as the gate presents one.
private struct Host<Sheet: View>: View {
    @ViewBuilder let sheet: Sheet

    var body: some View {
        NavigationStack {
            List(1..<12) { Text(verbatim: "Note \($0)") }
                .navigationTitle(Text(verbatim: "Notes"))
        }
        .sheet(isPresented: .constant(true)) { sheet }
    }
}

#Preview("Required") {
    UpdateRequiredView(offer: offer, appName: "Notes") {}
}

#Preview("Required, the project's words, dark") {
    UpdateRequiredView(offer: worded, appName: "Notes") {}
        .preferredColorScheme(.dark)
}

#Preview("Required, long text") {
    UpdateRequiredView(offer: longWords, appName: "Notes for Teams and Families") {}
}

#Preview("Required, largest text") {
    UpdateRequiredView(offer: offer, appName: "Notes") {}
        .dynamicTypeSize(.accessibility3)
}

#Preview("Required, Ukrainian") {
    UpdateRequiredView(offer: offer, appName: "Notes") {}
        .environment(\.locale, Locale(identifier: "uk"))
}

#Preview("Recommended") {
    Host {
        UpdateRecommendedView(offer: offer, appName: "Notes", onUpdate: {}, onDismiss: {})
    }
}

#Preview("Recommended, dark, largest text") {
    Host {
        UpdateRecommendedView(offer: offer, appName: "Notes", onUpdate: {}, onDismiss: {})
    }
    .preferredColorScheme(.dark)
    .dynamicTypeSize(.accessibility3)
}

#Preview("Recommended, long text") {
    Host {
        UpdateRecommendedView(offer: longWords, appName: "Notes", onUpdate: {}, onDismiss: {})
    }
}

#Preview("Device unsupported") {
    Host {
        DeviceUnsupportedView(offer: offer, appName: "Notes", systemName: "iOS", onDismiss: {})
    }
}

#Preview("Device unsupported, dark, Russian") {
    Host {
        DeviceUnsupportedView(offer: offer, appName: "Notes", systemName: "iOS", onDismiss: {})
    }
    .preferredColorScheme(.dark)
    .environment(\.locale, Locale(identifier: "ru"))
}
