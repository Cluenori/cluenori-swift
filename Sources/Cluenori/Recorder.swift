import CluenoriIngest
import Foundation
import os

/// What a signal recorded in a session is stamped with, in the order calls were made: its ID and
/// time, its session, the person signed in then, and the feature in effect at the call.
package struct SignalStamp: Sendable {
    package let id: String
    package let at: Date
    package let session: String
    package let user: String?
    package let feature: String?
    /// The screen shown when it was recorded, as the app names it.
    package let screen: String?
}

/// Makes a signal of a session from its stamp.
package typealias SignalBuilder = @Sendable (SignalStamp) -> AppSignal

/// One thing the app did that the SDK records or remembers, taken in the order the app did it.
enum Command: Sendable {
    /// A signal of the session open now, recorded at `at` in `feature`.
    case record(at: Date, feature: String?, screen: String?, build: SignalBuilder)
    /// A signal of no session, such as MetricKit's report.
    case recordUnscoped(at: Date, build: @Sendable (_ id: String, _ at: Date) -> AppSignal)
    /// A signal of the session open now, recorded only when it ends; `key`'s last one replaces those
    /// before it.
    case hold(key: String, at: Date, feature: String?, screen: String?, build: SignalBuilder)
    case lifecycle(SessionEvent)
    case identify(String)
    case reset(at: Date)
    case consent(AnalyticsConsent, at: Date)
    case closePrompt(ClosedPrompt)
    case keyRejected
    /// Resumes once every command before it is done.
    case barrier(CheckedContinuation<Void, Never>)
}

/// Owns everything the SDK records and remembers: the installation, the person, consent, the session
/// and the queue it fills. It takes commands one at a time, in the order the app made them, so a
/// signal is stamped with the session and person of its moment; its files are read and written
/// here, off the main thread.
actor Recorder {
    /// What the last process left, as this one starts.
    struct Boot: Sendable {
        let installation: String
        let rejected: Bool
        let closedPrompts: [ClosedPrompt]
    }

    static let stateFile = "state.json"
    static let installationFile = "installation"

    private let folder: Folder
    private let queue: SignalQueue
    private let ids: IDMaker
    private let key: String
    private let release: String
    private let environment: String
    private let logger = Logger(subsystem: "com.cluenori.sdk", category: "recorder")

    private var state = KeptState()
    private var installation = ""
    private var inForeground = false
    /// Signals recorded since the last nudge to send.
    private var unsent = 0

    init(folder: Folder, queue: SignalQueue, ids: IDMaker, key: String, release: String, environment: String) {
        self.folder = folder
        self.queue = queue
        self.ids = ids
        self.key = key
        self.release = release
        self.environment = environment
    }

    /// Reads what the last process left, and ends its session: a new process means the app was
    /// terminated. Nil, changing nothing, while its files are there but can't be read, as before the
    /// first unlock after a restart: starting from nothing then would forget the person's consent.
    func boot(at now: Date) async -> Boot? {
        guard let kept = readState(), let installation = readInstallation(at: now) else { return nil }
        self.installation = installation
        state = kept
        let rejection = KeptState.Rejection(key: key, release: release)
        let rejected = state.rejected == rejection
        if state.rejected != nil && !rejected {
            // A new release, or a new key, tries again.
            state.rejected = nil
        }
        state.closedPrompts.removeAll { $0.until <= now }
        await emit(apply(.launch(now)))
        if !collecting { await queue.removeAll() }
        persist()
        return Boot(installation: installation, rejected: rejected, closedPrompts: state.closedPrompts)
    }

    /// Does `command`; true when enough was recorded that sending shouldn't wait.
    func handle(_ command: Command) async -> Bool {
        switch command {
        case .record(let at, let feature, let screen, let build):
            await endIfTimedOut(at: at)
            guard collecting, let session = state.session else {
                logger.debug("A signal recorded without a session, or without consent, is dropped.")
                return false
            }
            let stamp = SignalStamp(
                id: ids.make(at: at), at: at, session: session.id, user: state.user, feature: feature, screen: screen)
            await append(build(stamp), to: session.origin)
            state.session?.lastSeenAt = max(session.lastSeenAt, at)
        case .recordUnscoped(let at, let build):
            guard collecting else { return false }
            await append(build(ids.make(at: at), at), to: origin)
        case .hold(let key, let at, let feature, let screen, let build):
            await endIfTimedOut(at: at)
            guard collecting, let session = state.session else { return false }
            let stamp = SignalStamp(
                id: ids.make(at: at), at: at, session: session.id, user: state.user, feature: feature, screen: screen)
            state.session?.held[key] = build(stamp)
            persist()
        case .lifecycle(let event):
            switch event {
            case .foreground: inForeground = true
            case .background: inForeground = false
            case .tick, .launch, .end: break
            }
            guard collecting else { return false }
            await emit(apply(event))
            persist()
        case .identify(let user):
            guard state.user != user else { return false }
            state.user = user
            persist()
        case .reset(let at):
            if collecting {
                await emit(apply(.end(at)))
            }
            state.user = nil
            if collecting && inForeground {
                await emit(apply(.foreground(at)))
            }
            persist()
        case .consent(let consent, let at):
            guard state.consent != consent else { return false }
            state.consent = consent
            switch consent {
            case .none:
                state.session = nil
                await queue.removeAll()
            case .full:
                if collecting && inForeground {
                    await emit(apply(.foreground(at)))
                }
            }
            persist()
        case .closePrompt(let prompt):
            state.closedPrompts.removeAll { $0.version == prompt.version }
            state.closedPrompts.append(prompt)
            persist()
        case .keyRejected:
            state.rejected = KeptState.Rejection(key: key, release: release)
            state.session = nil
            await queue.removeAll()
            persist()
        case .barrier(let continuation):
            continuation.resume()
        }
        if unsent >= 50 {
            unsent = 0
            return true
        }
        return false
    }

    /// Whether signals are recorded: the person allows it, and the deployment took the key.
    private var origin: SessionOrigin { SessionOrigin(release: release, environment: environment) }

    private var collecting: Bool {
        state.consent == .full && state.rejected == nil
    }

    /// Ends a session 30 s in the background before a signal joins it, for an app that resumed in
    /// the background before its tick came.
    private func endIfTimedOut(at moment: Date) async {
        guard collecting, state.session?.backgroundSince != nil else { return }
        let change = apply(.tick(moment))
        guard change.ended != nil else { return }
        await emit(change)
        persist()
    }

    private func apply(_ event: SessionEvent) -> SessionChange {
        var session = state.session
        let change = SessionRules.apply(event, to: &session, origin: origin) { ids.make(at: $0) }
        state.session = session
        return change
    }

    /// Records what a session change means: the end of one, with what it held, and the start of the
    /// next.
    private func emit(_ change: SessionChange) async {
        guard collecting else { return }
        if let ended = change.ended {
            for key in ended.session.held.keys.sorted() {
                if let held = ended.session.held[key] { await append(held, to: ended.session.origin) }
            }
            await append(
                .sessionEnded(
                    SessionEnded(
                        id: ids.make(at: ended.at), at: ended.at, session: ended.session.id, user: state.user,
                        foregroundMs: (ended.foregroundSeconds * 1000).rounded())), to: ended.session.origin)
        }
        if let started = change.started {
            await append(
                .sessionStarted(
                    SessionStarted(
                        id: ids.make(at: started.startedAt), at: started.startedAt, session: started.id,
                        user: state.user)),
                to: started.origin)
        }
    }

    private func append(_ signal: AppSignal, to origin: SessionOrigin) async {
        await queue.append(signal, release: origin.release, environment: origin.environment)
        unsent += 1
    }

    private func persist() {
        do {
            try folder.write(state, Self.stateFile)
        } catch {
            logger.error("Cluenori's state couldn't be kept: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// What the last process kept: nothing on a first launch, or when the file is damaged; nil when
    /// the file is there but can't be read now.
    private func readState() -> KeptState? {
        let file = folder.file(Self.stateFile)
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return KeptState() }
        guard let data = try? Data(contentsOf: file) else { return nil }
        guard let kept = try? Coding.decoder().decode(KeptState.self, from: data) else {
            // Not handled: a damaged state file, which atomic writes rule out short of a disk
            // failure; it starts over, as a first launch does.
            logger.error("Cluenori's state couldn't be read, and starts over.")
            return KeptState()
        }
        return kept
    }

    /// The installation's ID, made on its first launch and kept in its file from then on; nil when
    /// the file is there but can't be read now.
    private func readInstallation(at now: Date) -> String? {
        do {
            try folder.make()
        } catch {
            logger.error("Cluenori's folder couldn't be made: \(error.localizedDescription, privacy: .public)")
        }
        let file = folder.file(Self.installationFile)
        if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            guard let data = try? Data(contentsOf: file) else { return nil }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if IDMaker.isUUIDv7(text) { return text }
        }
        let made = ids.make(at: now)
        do {
            try Data(made.utf8).write(to: file, options: .atomic)
        } catch {
            // Not kept, the next launch makes another: this process still sends as one installation.
            logger.error("The installation's ID couldn't be kept: \(error.localizedDescription, privacy: .public)")
        }
        return made
    }
}
