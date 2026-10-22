import CluenoriIngest
import Foundation
import Observation

/// How long a soft prompt the person closed stays closed, for the version it offered.
package let closedPromptQuietTime: TimeInterval = 24 * 60 * 60

/// The update gate's state on the main actor, where views read it: the version policy of the last
/// manifest, this device's OS, and the soft prompts the person closed. Observable, so a view reading
/// `prompt` follows each manifest.
@MainActor
@Observable
package final class UpdateGate {
    package private(set) var policy: VersionPolicy?
    private var closed: [ClosedPrompt] = []
    @ObservationIgnored private let osVersion: OperatingSystemVersion
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Keeps a closed prompt, so it stays closed after the next launch too.
    @ObservationIgnored package var keepClosed: @Sendable (ClosedPrompt) -> Void = { _ in }

    package nonisolated init(osVersion: OperatingSystemVersion, now: @escaping @Sendable () -> Date) {
        self.osVersion = osVersion
        self.now = now
    }

    /// Moved on each return to the foreground, so `prompt` is read again then, and a soft prompt
    /// whose day is over shows again without a relaunch.
    private var resumes = 0

    /// What to show now.
    package var prompt: UpdatePrompt {
        _ = resumes
        let decided = UpdatePrompt.decide(policy, osVersion: osVersion)
        switch decided {
        case .recommended(let offer), .deviceUnsupported(let offer):
            let moment = now()
            return closed.contains { $0.version == offer.version && $0.until > moment } ? .none : decided
        case .none, .required:
            return decided
        }
    }

    /// Closes a soft prompt for a day. A required update can't be closed.
    package func dismiss() {
        switch UpdatePrompt.decide(policy, osVersion: osVersion) {
        case .recommended(let offer), .deviceUnsupported(let offer):
            let prompt = ClosedPrompt(version: offer.version, until: now().addingTimeInterval(closedPromptQuietTime))
            closed.removeAll { $0.version == offer.version }
            closed.append(prompt)
            keepClosed(prompt)
        case .none, .required:
            break
        }
    }

    /// Shows the policy of a manifest the SDK received or kept.
    package func show(_ policy: VersionPolicy?) {
        if self.policy != policy { self.policy = policy }
    }

    /// The app came back to the foreground: what to show is decided again.
    package func resume() {
        resumes += 1
    }

    /// The prompts the person closed before this launch.
    package func restore(_ closed: [ClosedPrompt]) {
        self.closed = closed
    }
}
