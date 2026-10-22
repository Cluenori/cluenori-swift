import CluenoriIngest
import Foundation

/// How long the app may stay in the background before its session ends. Coming back sooner continues
/// the session.
package let sessionTimeout: TimeInterval = 30

/// The session open now, as it is kept on disk between launches: so a session the system ended by
/// terminating the app in the background still ends, at the next launch, with its time in the
/// foreground.
struct OpenSession: Codable, Equatable, Sendable {
    let id: String
    /// The release and environment the session ran in: its signals are sent as theirs, even after
    /// the app was updated.
    let origin: SessionOrigin
    let startedAt: Date
    /// Since when the app is in the foreground; nil while it is in the background.
    var foregroundSince: Date?
    /// Since when the app is in the background; nil while it is in the foreground.
    var backgroundSince: Date?
    /// The foreground time of the intervals already over.
    var foregroundSeconds: TimeInterval
    /// The last moment the app was known to run: what ends a session whose app was terminated in the
    /// foreground, without a word.
    var lastSeenAt: Date
    /// Signals to record when the session ends, by who holds them, such as its memory at the end.
    var held: [String: AppSignal]
}

/// Where a session ran: its release and environment.
struct SessionOrigin: Codable, Equatable, Sendable {
    let release: String
    let environment: String
}

/// What happened to the app that matters to its session.
enum SessionEvent: Equatable, Sendable {
    /// The app came to the foreground.
    case foreground(Date)
    /// The app went to the background.
    case background(Date)
    /// Time passed: a session 30 s in the background ends; one in the foreground was seen.
    case tick(Date)
    /// A new process started: the session kept from the last one ends, as its app was terminated.
    case launch(Date)
    /// The session ends now, as when the person signs out.
    case end(Date)
}

/// A session that ended: when, and its time in the foreground.
struct EndedSession: Equatable, Sendable {
    let session: OpenSession
    let at: Date
    let foregroundSeconds: TimeInterval
}

/// What an event did: the session it ended, and the one it started, if any.
struct SessionChange: Equatable, Sendable {
    var ended: EndedSession?
    var started: OpenSession?
}

/// The session rules, apart from where their effects go: a session starts when the app comes to the
/// foreground, and ends 30 s after it goes to the background, or when its app is terminated. Pure, so
/// each rule is tested with the times given.
enum SessionRules {
    static func apply(
        _ event: SessionEvent, to session: inout OpenSession?, origin: SessionOrigin, newID: (Date) -> String
    ) -> SessionChange {
        var change = SessionChange()
        switch event {
        case .foreground(let at):
            if var open = session {
                if let since = open.backgroundSince {
                    if at.timeIntervalSince(since) >= sessionTimeout {
                        change.ended = end(open, at: since.addingTimeInterval(sessionTimeout))
                        session = nil
                    } else {
                        // What was held for an end that didn't come is let go: it is held again
                        // the next time the app leaves.
                        open.backgroundSince = nil
                        open.foregroundSince = at
                        open.lastSeenAt = at
                        open.held = [:]
                        session = open
                        return change
                    }
                } else {
                    // Already in the foreground: activating again, as after Control Center, changes nothing.
                    open.lastSeenAt = max(open.lastSeenAt, at)
                    session = open
                    return change
                }
            }
            let started = OpenSession(
                id: newID(at), origin: origin, startedAt: at, foregroundSince: at, backgroundSince: nil,
                foregroundSeconds: 0,
                lastSeenAt: at, held: [:])
            session = started
            change.started = started
        case .background(let at):
            guard var open = session, let since = open.foregroundSince else { return change }
            open.foregroundSeconds += elapsed(from: since, to: at)
            open.foregroundSince = nil
            open.backgroundSince = at
            open.lastSeenAt = max(open.lastSeenAt, at)
            session = open
        case .tick(let at):
            guard var open = session else { return change }
            if let since = open.backgroundSince {
                if at.timeIntervalSince(since) >= sessionTimeout {
                    change.ended = end(open, at: since.addingTimeInterval(sessionTimeout))
                    session = nil
                }
            } else {
                open.lastSeenAt = max(open.lastSeenAt, at)
                session = open
            }
        case .launch(let at):
            guard let open = session else { return change }
            if let since = open.backgroundSince {
                // Terminated in the background: at its 30 s, unless this launch came sooner.
                change.ended = end(open, at: min(since.addingTimeInterval(sessionTimeout), max(at, since)))
            } else {
                // Terminated in the foreground, such as by a crash: when it was last seen.
                change.ended = end(open, at: open.lastSeenAt)
            }
            session = nil
        case .end(let at):
            guard let open = session else { return change }
            change.ended = end(open, at: at)
            session = nil
        }
        return change
    }

    private static func end(_ session: OpenSession, at: Date) -> EndedSession {
        var foreground = session.foregroundSeconds
        if let since = session.foregroundSince {
            foreground += elapsed(from: since, to: at)
        }
        return EndedSession(session: session, at: at, foregroundSeconds: foreground)
    }

    // Not handled: a clock set back while the app runs; the interval counts as none rather than less.
    private static func elapsed(from start: Date, to end: Date) -> TimeInterval {
        max(0, end.timeIntervalSince(start))
    }
}
