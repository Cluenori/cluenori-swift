import Foundation

/// Cluenori in an app: start it once at launch, and it records sessions, keeps the manifest that
/// drives the update gate, and sends what it recorded to your deployment, in batches, when it can.
///
/// ```swift
/// @main struct NotesApp: App {
///     init() {
///         Cluenori.start(key: "<SDK key>", environment: "production", deployment: URL(string: "https://cluenori.example.com")!)
///     }
///     var body: some Scene {
///         WindowGroup { ContentView().cluenoriUpdateGate() }
///     }
/// }
///
/// Cluenori.identify(userID: user.id)        // after sign-in: the app's opaque ID, never an email
/// CardView().cluenoriFeature("cards.flip")  // signals and API calls from this screen belong to it
/// request.addCluenoriHeaders()              // the release, a trace and the feature, to your own API
/// Cluenori.reset()                          // after sign-out
/// ```
///
/// Every call returns at once and never throws: files are read and the network is used off the main
/// thread, and when Cluenori can't be reached the app carries on, with the signals kept to send later
/// within a budget. A mistake in a call, such as a feature key that isn't one, stops a debug build
/// with what is wrong, and is logged and ignored in a release build.
public enum Cluenori {
    /// Starts the SDK: call it once, as the app launches, before anything else here.
    ///
    /// - Parameters:
    ///   - key: the component's SDK key, from Cluenori.
    ///   - environment: where this build runs, `production` or `staging`: its signals and its
    ///     manifest are that environment's.
    ///   - deployment: your Cluenori's address, `https://cluenori.example.com`; http only on this Mac
    ///     or its local network, for `./run`.
    ///
    /// The release is the app's own, `<CFBundleShortVersionString>+<CFBundleVersion>`. The
    /// installation's ID is made on the first launch and kept in the app's container, so a new
    /// install is a new installation.
    @MainActor
    public static func start(key: String, environment: String, deployment: URL) {
        let engine = Engine.shared
        engine.start(Configuration(key: key, environment: environment, deployment: deployment))
        AppLifecycle.observe(engine)
    }

    /// The person signed in, by the app's own ID for them: opaque, such as a UUID, never an email or
    /// a name. Kept between launches; signals recorded from now on carry it.
    public static func identify(userID: String) {
        Engine.shared.identify(userID)
    }

    /// The person signed out: the session ends, and the next one starts without them.
    public static func reset() {
        Engine.shared.reset()
    }

    /// What the person lets the app collect, kept between launches. `none` records nothing more and
    /// drops what wasn't sent; `full`, the default, records everything the app's modules do. The
    /// update gate works either way.
    public static func consent(analytics: AnalyticsConsent) {
        Engine.shared.consent(analytics)
    }

    /// Runs `operation` in feature `key`, such as `cards.flip`: signals recorded and requests prepared
    /// inside it belong to that feature.
    public static func feature<Result>(_ key: String, _ operation: () throws -> Result) rethrows -> Result {
        try Engine.shared.feature(key, operation)
    }

    /// Runs `operation` in feature `key`, across its awaits.
    public static func feature<Result>(_ key: String, _ operation: () async throws -> Result) async rethrows -> Result {
        try await Engine.shared.feature(key, operation)
    }

    /// Marks `key` the feature the person is in until the mark ends: what `cluenoriFeature(_:)` does
    /// for a SwiftUI view from appearing to disappearing, for a UIKit screen to do the same.
    ///
    /// ```swift
    /// override func viewDidAppear(_ animated: Bool) { mark = Cluenori.begin(feature: "cards.flip") }
    /// override func viewDidDisappear(_ animated: Bool) { mark?.end() }
    /// ```
    public static func begin(feature key: String) -> FeatureMark {
        Engine.shared.begin(feature: key)
    }

    /// The headers for one request to your own API: `Cluenori-Release`, a new `traceparent`, and
    /// `baggage` with the feature in effect and the app's release. `URLRequest.addCluenoriHeaders()`
    /// adds them to a request.
    public static func requestHeaders() -> [String: String] {
        Engine.shared.requestHeaders()
    }

    /// What the app should show about its version now, for an app that draws its own update gate;
    /// observable, so a SwiftUI view reading it follows each manifest. `CluenoriUpdateGate` draws it.
    @MainActor
    public static var updatePrompt: UpdatePrompt {
        Engine.shared.gate.prompt
    }

    /// Closes the recommendation or the notice shown, for a day for its version. A required update
    /// can't be closed.
    @MainActor
    public static func dismissUpdatePrompt() {
        Engine.shared.gate.dismiss()
    }
}
