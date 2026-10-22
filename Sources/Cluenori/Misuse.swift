import Foundation
import os

/// Reports a mistake in how the app calls the SDK, such as a feature key that isn't one: it stops a
/// debug build at the call, so the developer sees it at once, and in a release build it is logged and
/// the call does nothing, since a typo in analytics must never crash someone's app.
package struct Misuse: Sendable {
    let report: @Sendable (String) -> Void

    package init(report: @escaping @Sendable (String) -> Void) {
        self.report = report
    }

    // The message can hold what the app passed, such as an email given as a user ID, so the log
    // keeps it private; the debugger shows it.
    package static let live = Misuse { message in
        Logger(subsystem: "com.cluenori.sdk", category: "misuse").fault("\(message, privacy: .private)")
        assertionFailure("Cluenori: \(message)")
    }

    package func callAsFunction(_ message: String) {
        report(message)
    }
}
