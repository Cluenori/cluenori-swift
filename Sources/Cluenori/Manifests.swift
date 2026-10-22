import CluenoriIngest
import Foundation
import os

/// The manifest: asked for at launch and on resume, kept on disk, and handed to the update gate.
/// It fails open: while the deployment can't be asked, the last manifest of this release is used, and
/// with none the app is never blocked. A kept manifest is used for its own release and environment
/// alone, so an update never inherits the block of the release before it.
actor Manifests {
    private struct Kept: Codable {
        let release: String
        let environment: String
        let locale: String
        let receivedAt: Date
        let manifest: AppManifest
    }

    static let fileName = "manifest.json"

    private let folder: Folder
    private let client: CluenoriIngestAPI
    private let release: String
    private let environment: String
    private let locale: String
    private let now: @Sendable () -> Date
    private let show: @Sendable (AppManifest?) async -> Void
    private let logger = Logger(subsystem: "com.cluenori.sdk", category: "manifest")

    private var kept: Kept?
    private var stopped = false
    private var inFlight: Task<Void, Never>?

    init(
        folder: Folder, client: CluenoriIngestAPI, release: String, environment: String, locale: String,
        now: @escaping @Sendable () -> Date, show: @escaping @Sendable (AppManifest?) async -> Void
    ) {
        self.folder = folder
        self.client = client
        self.release = release
        self.environment = environment
        self.locale = locale
        self.now = now
        self.show = show
    }

    /// Shows the manifest kept from before, if it is this release's.
    func showKept() async {
        if let found = folder.read(Kept.self, Self.fileName), found.release == release, found.environment == environment
        {
            kept = found
        }
        await show(kept?.manifest)
    }

    /// Starts asking for the manifest, unless the one kept is younger than its `maxAgeSeconds` and
    /// in the same language, or a question is under way. Returns at once; a failure keeps what is
    /// shown.
    func beginRefresh() {
        guard inFlight == nil, !stopped else { return }
        if let kept, kept.locale == locale,
            now().timeIntervalSince(kept.receivedAt) < TimeInterval(kept.manifest.maxAgeSeconds)
        {
            return
        }
        inFlight = Task {
            await ask()
            inFlight = nil
        }
    }

    /// Waits for the question under way, if any.
    func idle() async {
        await inFlight?.value
    }

    /// Stops asking, as when the deployment refused the key: what is shown stays.
    func stop() {
        stopped = true
    }

    private func ask() async {
        do {
            let manifest = try await client.manifest(environment: environment, release: release, locale: locale)
            let received = Kept(
                release: release, environment: environment, locale: locale, receivedAt: now(), manifest: manifest)
            kept = received
            do {
                try folder.write(received, Self.fileName)
            } catch {
                logger.error("The manifest couldn't be kept: \(error.localizedDescription, privacy: .public)")
            }
            await show(manifest)
        } catch .sdkKeyRejected {
            logger.error("The deployment refused the SDK key; the last manifest stays.")
            stopped = true
        } catch {
            logger.notice("The manifest couldn't be asked for: \(String(describing: error), privacy: .public)")
        }
    }
}
