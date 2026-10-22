import Cluenori
import CluenoriIngest
import Foundation

/// One value of an event's property: a string of at most 256 characters, a finite number, or a
/// boolean. IDs, counts and amounts, never text the person typed.
public enum EventValue: Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral
{
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension Cluenori {
    /// Records something the person did, in the app's own words, `autograph.requested`, with what
    /// it is about: at most 32 properties, each keyed by a snake_case word, `card_id`. It belongs to
    /// the session and the feature in effect.
    ///
    /// ```swift
    /// Cluenori.track("autograph.requested", properties: ["card_id": card.id, "photos": 2, "first": true])
    /// ```
    ///
    /// A property that breaks the rules is left out, and a name that isn't one records nothing; a
    /// debug build stops at either.
    public static func track(_ name: String, properties: [String: EventValue] = [:]) {
        Analytics.track(name, properties: properties, on: .shared)
    }

    /// Records that a screen was shown, by the name the app gives it, `card` or `profile.edit`: for
    /// a UIKit screen, what `cluenoriScreen(_:)` does for a SwiftUI view.
    public static func screen(_ name: String) {
        Analytics.screen(name, on: .shared)
    }
}

/// Analytics on an engine: the shared one in an app, a test's own in tests.
enum Analytics {
    static let propertiesPerEvent = 32

    static func track(_ name: String, properties: [String: EventValue], on engine: Engine) {
        guard TextRules.isName(name) else {
            engine.misuse("\"\(name)\" isn't an event's name: 1 to 256 characters, such as autograph.requested.")
            return
        }
        let (kept, problems) = checked(properties)
        for problem in problems { engine.misuse(problem) }
        engine.record { stamp in
            .event(
                EventTracked(
                    id: stamp.id, at: stamp.at, session: stamp.session, user: stamp.user, feature: stamp.feature,
                    name: name, properties: kept.isEmpty ? nil : kept))
        }
    }

    static func screen(_ name: String, on engine: Engine) {
        guard TextRules.isName(name) else {
            engine.misuse("\"\(name)\" isn't a screen's name: 1 to 256 characters, such as profile.edit.")
            return
        }
        engine.record { stamp in
            .screen(
                ScreenShown(
                    id: stamp.id, at: stamp.at, session: stamp.session, user: stamp.user, feature: stamp.feature,
                    screen: name))
        }
    }

    /// The properties the contract takes, and what is wrong with each it doesn't: a key that isn't
    /// snake_case, a string over 256 characters, a number that isn't finite, or one past the 32nd,
    /// by key order.
    static func checked(_ properties: [String: EventValue]) -> (kept: [String: JSONValue], problems: [String]) {
        var kept: [String: JSONValue] = [:]
        var problems: [String] = []
        for key in properties.keys.sorted() {
            guard let value = properties[key] else { continue }
            guard TextRules.isPropertyKey(key) else {
                problems.append("\"\(key)\" isn't a property's key: snake_case words joined by dots, such as card_id.")
                continue
            }
            guard kept.count < propertiesPerEvent else {
                problems.append("An event has at most \(propertiesPerEvent) properties; \"\(key)\" is left out.")
                continue
            }
            switch value {
            case .string(let text) where text.utf16.count > 256:
                problems.append("The property \"\(key)\" is over 256 characters, and is left out.")
            case .number(let number) where !number.isFinite:
                problems.append("The property \"\(key)\" isn't a finite number, and is left out.")
            case .string(let text): kept[key] = .string(text)
            case .number(let number): kept[key] = .number(number)
            case .bool(let flag): kept[key] = .bool(flag)
            }
        }
        return (kept, problems)
    }
}
