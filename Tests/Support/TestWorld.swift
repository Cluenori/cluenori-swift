import Cluenori
import CluenoriIngest
import Foundation
import Synchronization

/// A clock the test moves.
package final class ManualClock: Sendable {
    private let moment: Mutex<Date>

    package init(_ start: Date = Date(timeIntervalSince1970: 1_792_000_000)) {
        moment = Mutex(start)
    }

    package var now: Date { moment.withLock { $0 } }

    package func advance(_ seconds: TimeInterval) {
        moment.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// The mistakes an engine reported, in place of stopping the test.
package final class MisuseLog: Sendable {
    private let messages = Mutex<[String]>([])

    package init() {}

    package var reported: [String] { messages.withLock { $0 } }

    package var misuse: Misuse {
        Misuse { [self] message in messages.withLock { $0.append(message) } }
    }
}

/// One installation of an app for a test: its folder, the deployment it sends to, its clock, and
/// the engines that run in it, one per launch.
package final class TestWorld: Sendable {
    package let deployment: FakeDeployment
    package let clock: ManualClock
    package let misuses = MisuseLog()
    package let folder: URL
    private let engines = Mutex<[Engine]>([])

    package init(deployment: FakeDeployment = FakeDeployment(), clock: ManualClock = ManualClock()) {
        self.deployment = deployment
        self.clock = clock
        folder = FileManager.default.temporaryDirectory.appending(
            path: "cluenori-tests/\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    deinit {
        engines.withLock { $0.forEach { $0.stop() } }
        try? FileManager.default.removeItem(at: folder)
    }

    /// A launch of the app: an engine on this installation's folder, started unless told not to.
    /// The engine of the launch before stops, as its process would have.
    package func launch(
        release: String? = "0.3.0+20", environment: String = "production",
        key: String = "cluenori.sdk.notes-ios.secret",
        osVersion: OperatingSystemVersion = OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0),
        locale: String = "uk-UA", start: Bool = true,
        wait: @escaping @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }
    ) -> Engine {
        let clock = self.clock
        let engine = Engine(
            dependencies: Dependencies(
                folder: Folder(url: folder), transport: deployment.transport, now: { clock.now },
                wait: wait, random: { 1 }, ids: IDMaker(),
                release: release,
                device: {
                    AppDevice(
                        model: "iPhone18,1", platform: .iOS, osVersion: "27.2", locale: "uk-UA", timeZone: "Europe/Kyiv"
                    )
                },
                locale: locale, osVersion: osVersion, schedules: false, misuse: misuses.misuse))
        engines.withLock { engines in
            engines.forEach { $0.stop() }
            engines.append(engine)
        }
        if start {
            engine.start(
                Configuration(
                    key: key, environment: environment, deployment: URL(string: "https://cluenori.example.com")!))
        }
        return engine
    }
}

extension AppSignal {
    /// The signal's kind, as the contract tags it: `session.started`, `event`.
    package var kind: String {
        switch self {
        case .sessionStarted: "session.started"
        case .sessionEnded: "session.ended"
        case .appLaunched: "app.launched"
        case .appMemory: "app.memory"
        case .screen: "screen"
        case .event: "event"
        case .metrickit: "metrickit"
        case .screenReady: "screen.ready"
        case .screenLeft: "screen.left"
        case .appHang: "app.hang"
        case .error: "error"
        case .timing: "timing"
        case .unknown(let kind): kind
        }
    }

    /// The signal's ID.
    package var id: String? {
        switch self {
        case .sessionStarted(let signal): signal.id
        case .sessionEnded(let signal): signal.id
        case .appLaunched(let signal): signal.id
        case .appMemory(let signal): signal.id
        case .screen(let signal): signal.id
        case .event(let signal): signal.id
        case .metrickit(let signal): signal.id
        case .screenReady(let signal): signal.id
        case .screenLeft(let signal): signal.id
        case .appHang(let signal): signal.id
        case .error(let signal): signal.id
        case .timing(let signal): signal.id
        case .unknown: nil
        }
    }

    /// The session it belongs to; nil for MetricKit's reports.
    package var session: String? {
        switch self {
        case .sessionStarted(let signal): signal.session
        case .sessionEnded(let signal): signal.session
        case .appLaunched(let signal): signal.session
        case .appMemory(let signal): signal.session
        case .screen(let signal): signal.session
        case .event(let signal): signal.session
        case .screenReady(let signal): signal.session
        case .screenLeft(let signal): signal.session
        case .appHang(let signal): signal.session
        case .error(let signal): signal.session
        case .timing(let signal): signal.session
        case .metrickit, .unknown: nil
        }
    }

    /// The person signed in when it was recorded.
    package var user: String? {
        switch self {
        case .sessionStarted(let signal): signal.user
        case .sessionEnded(let signal): signal.user
        case .appLaunched(let signal): signal.user
        case .appMemory(let signal): signal.user
        case .screen(let signal): signal.user
        case .event(let signal): signal.user
        case .screenReady(let signal): signal.user
        case .screenLeft(let signal): signal.user
        case .appHang(let signal): signal.user
        case .error(let signal): signal.user
        case .timing(let signal): signal.user
        case .metrickit, .unknown: nil
        }
    }

    /// The screen it was recorded on.
    package var screen: String? {
        switch self {
        case .sessionStarted(let signal): signal.screen
        case .sessionEnded(let signal): signal.screen
        case .appLaunched(let signal): signal.screen
        case .appMemory(let signal): signal.screen
        case .screen(let signal): signal.screen
        case .event(let signal): signal.screen
        case .screenReady(let signal): signal.screen
        case .screenLeft(let signal): signal.screen
        case .appHang(let signal): signal.screen
        case .error(let signal): signal.screen
        case .timing(let signal): signal.screen
        case .metrickit, .unknown: nil
        }
    }

    /// The feature it was recorded in.
    package var feature: String? {
        switch self {
        case .sessionStarted(let signal): signal.feature
        case .sessionEnded(let signal): signal.feature
        case .appLaunched(let signal): signal.feature
        case .appMemory(let signal): signal.feature
        case .screen(let signal): signal.feature
        case .event(let signal): signal.feature
        case .screenReady(let signal): signal.feature
        case .screenLeft(let signal): signal.feature
        case .appHang(let signal): signal.feature
        case .error(let signal): signal.feature
        case .timing(let signal): signal.feature
        case .metrickit, .unknown: nil
        }
    }
}

extension Engine {
    /// Records a screen, as the analytics module does: a signal for core tests to follow.
    package func recordScreen(_ name: String) {
        record { stamp in
            .screen(
                ScreenShown(
                    id: stamp.id, at: stamp.at, session: stamp.session, user: stamp.user, feature: stamp.feature,
                    screen: name))
        }
    }
}
