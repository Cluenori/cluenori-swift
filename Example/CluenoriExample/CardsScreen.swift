import Cluenori
import CluenoriAnalytics
import CluenoriPerformance
import Foundation
import SwiftUI

/// The app's one screen: cards to flip. Flipping is the feature `cards.flip`; each flip is an
/// event; and Sync sends a request to the app's own API with Cluenori's headers.
struct CardsScreen: View {
    @State private var flipped: Set<Int> = []
    @State private var headers: [String: String] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Card.all) { card in
                        CardRow(card: card, isFlipped: flipped.contains(card.id)) {
                            flip(card)
                        }
                    }
                }
                if !headers.isEmpty {
                    Section {
                        ForEach(headers.keys.sorted(), id: \.self) { name in
                            LabeledContent {
                                Text(verbatim: headers[name] ?? "").font(.caption.monospaced())
                            } label: {
                                Text(verbatim: name)
                            }
                        }
                    } header: {
                        Text("Headers of the last request")
                    }
                }
            }
            .navigationTitle(Text("Cards"))
            .toolbar {
                Button {
                    sync()
                } label: {
                    Label {
                        Text("Sync")
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
            }
        }
        .cluenoriFeature("cards")
        .cluenoriScreen("cards")
        // The cards are the app's own, so they show at once: the screen is ready from what it keeps.
        .cluenoriScreenReady(.kept, when: true)
    }

    private func flip(_ card: Card) {
        Cluenori.feature("cards.flip") {
            withAnimation(.snappy) {
                if flipped.remove(card.id) == nil { flipped.insert(card.id) }
            }
            Cluenori.track(
                "card.flipped",
                properties: ["card_id": .string("c\(card.id)"), "face_up": .bool(flipped.contains(card.id))])
        }
    }

    /// What the app's own API would get: a request carries the release, a new trace, and the
    /// feature it was made in.
    private func sync() {
        var request = URLRequest(url: URL(string: "https://api.example.com/cards")!)
        Cluenori.feature("cards.sync") {
            request.addCluenoriHeaders()
        }
        headers = request.allHTTPHeaderFields ?? [:]
    }
}

private struct Card: Identifiable {
    let id: Int
    let front: String
    let back: String

    static let all = [
        Card(id: 1, front: "🌍", back: "Earth"),
        Card(id: 2, front: "🪐", back: "Saturn"),
        Card(id: 3, front: "🌕", back: "Moon"),
    ]
}

private struct CardRow: View {
    let card: Card
    let isFlipped: Bool
    let flip: () -> Void

    var body: some View {
        Button(action: flip) {
            HStack {
                Text(verbatim: isFlipped ? card.back : card.front)
                    .font(isFlipped ? .title3.weight(.semibold) : .largeTitle)
                    .contentTransition(.opacity)
                Spacer()
                Image(systemName: "hand.tap")
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 56)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: isFlipped ? card.back : card.front))
        .accessibilityHint(Text("Flips the card"))
    }
}
