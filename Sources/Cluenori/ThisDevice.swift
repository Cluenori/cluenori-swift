import CluenoriIngest
import Darwin
import Foundation

/// What the SDK says about the app and the device it runs on, read without UIKit, so it is read on
/// any thread.
enum ThisDevice {
    /// The app's release as Cluenori names it: `<version>+<build>`, `0.3.0+20`, from its Info.plist;
    /// nil when either is missing or isn't one.
    static func release(of bundle: Bundle = .main) -> String? {
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        else {
            return nil
        }
        let release = "\(version)+\(build)"
        return TextRules.isReleaseVersion(release) ? release : nil
    }

    /// The app's name as the home screen shows it.
    static func appName(of bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? ""
    }

    /// The device, its OS and the language and time zone the app runs in, as of now.
    static func device() -> AppDevice {
        let model = hardwareModel()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var osVersion = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { osVersion += ".\(version.patchVersion)" }
        return AppDevice(
            model: TextRules.shortText(model), platform: platform(model: model), osVersion: osVersion,
            locale: TextRules.shortText(locale()), timeZone: TextRules.shortText(TimeZone.current.identifier))
    }

    /// The language and region the app runs in, as BCP 47 without its extensions: `uk-UA`, never
    /// `en-US-u-fw-mon-ms-metric`, which iOS adds for the person's settings and which the
    /// deployment, taking at most 35 characters, would refuse.
    static func locale(_ locale: Locale = .current) -> String {
        // Extensions start at a subtag of one letter: `-u-`, `-t-`, `-x-`.
        let subtags: [Substring] = locale.identifier(.bcp47).split(separator: "-")
        let language = subtags.prefix { $0.count > 1 }.joined(separator: "-")
        return language.isEmpty ? "und" : String(language.prefix(35))
    }

    /// The hardware identifier, `iPhone17,2`; in a simulator, the one it simulates.
    private static func hardwareModel() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func platform(model: String) -> AppPlatform {
        #if os(iOS)
            if ProcessInfo.processInfo.isiOSAppOnMac { return .macOS }
            return model.hasPrefix("iPad") ? .iPadOS : .iOS
        #elseif os(macOS)
            return .macOS
        #elseif os(visionOS)
            return .visionOS
        #elseif os(tvOS)
            return .tvOS
        #elseif os(watchOS)
            return .watchOS
        #else
            return .iOS
        #endif
    }
}
