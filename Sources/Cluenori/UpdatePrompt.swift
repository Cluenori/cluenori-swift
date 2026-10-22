import CluenoriIngest
import Foundation

/// What the app should show about its version now, decided from the manifest and this device: the
/// headless form of the update gate, for apps that draw their own. `CluenoriUpdateGate` draws it
/// natively.
public enum UpdatePrompt: Equatable, Sendable {
    /// Nothing: the version is fine, the manifest says nothing, or none was ever received.
    case none
    /// A newer release is out: offer it in a sheet the person can close.
    case recommended(UpdateOffer)
    /// This release may no longer be used: show "Update to continue" until it is updated. It can't
    /// be dismissed.
    case required(UpdateOffer)
    /// The release is required, but this device's OS is older than the update needs, so it can't
    /// install it: it is never blocked, and sees a notice it can close instead.
    case deviceUnsupported(UpdateOffer)

    /// The offer of each prompt, nil for `none`.
    public var offer: UpdateOffer? {
        switch self {
        case .none: nil
        case .recommended(let offer), .required(let offer), .deviceUnsupported(let offer): offer
        }
    }
}

/// The release to update to, and the project's words for it when it wrote some, in the language
/// the app runs in. Without them, a view uses its own.
public struct UpdateOffer: Equatable, Sendable {
    /// The version as the store shows it: `0.4.0`.
    public let version: String
    /// The store's page for the app.
    public let storeURL: URL
    /// The oldest OS version the update runs on, `26.0`; nil when unknown.
    public let minimumOSVersion: String?
    /// The project's title and message, when it wrote them.
    public let title: String?
    public let message: String?

    public init(
        version: String, storeURL: URL, minimumOSVersion: String? = nil, title: String? = nil, message: String? = nil
    ) {
        self.version = version
        self.storeURL = storeURL
        self.minimumOSVersion = minimumOSVersion
        self.title = title
        self.message = message
    }
}

extension UpdatePrompt {
    /// The prompt a version policy calls for on a device with `osVersion`. Without a policy there is
    /// nothing to show: the SDK never blocks without one. A policy it can't act on, with a decision
    /// from a newer server or no store page to send the person to, shows nothing either.
    package static func decide(_ policy: VersionPolicy?, osVersion: OperatingSystemVersion) -> UpdatePrompt {
        guard let policy, policy.decision == .recommend || policy.decision == .require else { return .none }
        // Not handled: a recommend or require without a release to update to, which the deployment
        // never sends; there is nowhere to send the person, so nothing is shown.
        guard let update = policy.update, let storeURL = URL(string: update.storeUrl), storeURL.scheme == "https" else {
            return .none
        }
        let offer = UpdateOffer(
            version: update.version, storeURL: storeURL, minimumOSVersion: update.minimumOsVersion,
            title: policy.text?.title, message: policy.text?.message)
        let installable = update.minimumOsVersion.map { isAtLeast(osVersion, $0) } ?? true
        switch policy.decision {
        case .require: return installable ? .required(offer) : .deviceUnsupported(offer)
        // A recommendation this device can't follow is noise.
        default: return installable ? .recommended(offer) : .none
        }
    }

    /// Whether `version` is `minimum` or later, by number: 27.2 is later than 26.0 and than 27.
    package static func isAtLeast(_ version: OperatingSystemVersion, _ minimum: String) -> Bool {
        // Not handled: a minimum that isn't numbers joined by dots, which the contract rules out; the
        // device is taken to be able to install it.
        let parts = minimum.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return true }
        let wanted = parts.compactMap(\.self) + [0, 0, 0]
        let have = [version.majorVersion, version.minorVersion, version.patchVersion]
        for index in 0..<3 where have[index] != wanted[index] {
            return have[index] > wanted[index]
        }
        return true
    }
}
