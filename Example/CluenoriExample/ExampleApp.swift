import Cluenori
import CluenoriPerformance
import CluenoriUpdateGate
import Foundation
import SwiftUI

/// A tiny app that uses Cluenori as a founder's app would: it starts the SDK at launch, measures its
/// performance, marks its features and screens, tracks an event, sends its own API's requests with
/// Cluenori's headers, and shows the update gate over everything.
///
/// Launched with `-CluenoriDemoGate require` (or `recommend`, `unsupported`, `none`), it talks to a
/// demo deployment inside the app instead of a real one, whose manifest decides that: for trying the
/// gate, and for screenshots. Otherwise it sends to `-CluenoriDeployment <URL>` with `-CluenoriKey <key>`.
@main
struct ExampleApp: App {
    init() {
        let deployment =
            DemoDeployment.startIfAsked() ?? Launch.value(after: "-CluenoriDeployment").flatMap(URL.init(string:))
        Cluenori.start(
            key: Launch.value(after: "-CluenoriKey") ?? "cluenori.sdk.demo",
            environment: "production",
            deployment: deployment ?? URL(string: "https://cluenori.example.com")!)
        Cluenori.measurePerformance()
    }

    var body: some Scene {
        WindowGroup {
            CardsScreen()
                .cluenoriUpdateGate()
        }
    }
}

/// The app's launch arguments.
nonisolated enum Launch {
    static func value(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
