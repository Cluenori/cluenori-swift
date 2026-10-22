import Cluenori
import Foundation
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

extension View {
    /// Shows the update gate over this view, the app's root, as the manifest decides at launch and
    /// on resume:
    /// - a required update replaces the app with "Update to continue", which can't be dismissed;
    /// - a recommended update shows a sheet the person can close, which then stays closed for a day;
    /// - a device too old for a required update is never blocked: it sees a notice it can close.
    ///
    /// Until a manifest arrives, and whenever none can be had, it shows the app as it is.
    public func cluenoriUpdateGate() -> some View {
        modifier(UpdateGateModifier())
    }
}

private struct UpdateGateModifier: ViewModifier {
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        let prompt = Cluenori.updatePrompt
        Group {
            if case .required(let offer) = prompt {
                UpdateRequiredView(offer: offer, appName: ThisApp.name, appIcon: ThisApp.icon) {
                    openURL(offer.storeURL)
                }
                .transition(.opacity)
            } else {
                content
                    .sheet(item: softPrompt) { soft in
                        switch soft {
                        case .recommended(let offer):
                            UpdateRecommendedView(
                                offer: offer, appName: ThisApp.name, appIcon: ThisApp.icon,
                                onUpdate: { openURL(offer.storeURL) },
                                onDismiss: { Cluenori.dismissUpdatePrompt() })
                        case .deviceUnsupported(let offer):
                            DeviceUnsupportedView(
                                offer: offer, appName: ThisApp.name, systemName: ThisApp.systemName,
                                onDismiss: { Cluenori.dismissUpdatePrompt() })
                        }
                    }
            }
        }
        .animation(.smooth, value: prompt.isRequired)
    }

    /// The soft prompt to show in a sheet; closing the sheet closes the prompt.
    private var softPrompt: Binding<SoftPrompt?> {
        Binding {
            SoftPrompt(Cluenori.updatePrompt)
        } set: { shown in
            if shown == nil { Cluenori.dismissUpdatePrompt() }
        }
    }
}

/// A prompt shown in a sheet, by the update it offers.
private enum SoftPrompt: Identifiable {
    case recommended(UpdateOffer)
    case deviceUnsupported(UpdateOffer)

    init?(_ prompt: UpdatePrompt) {
        switch prompt {
        case .recommended(let offer): self = .recommended(offer)
        case .deviceUnsupported(let offer): self = .deviceUnsupported(offer)
        case .none, .required: return nil
        }
    }

    var id: String {
        switch self {
        case .recommended(let offer): "recommended \(offer.version)"
        case .deviceUnsupported(let offer): "unsupported \(offer.version)"
        }
    }
}

extension UpdatePrompt {
    fileprivate var isRequired: Bool {
        if case .required = self { true } else { false }
    }
}

/// What the gate says about the app it is in.
enum ThisApp {
    static var name: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? ""
    }

    /// The app's icon, when its bundle has one UIKit can load.
    static var icon: Image? {
        #if canImport(UIKit)
            guard let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
                let primary = icons["CFBundlePrimaryIcon"] as? [String: Any]
            else {
                return nil
            }
            let names =
                [primary["CFBundleIconName"] as? String]
                + ((primary["CFBundleIconFiles"] as? [String]) ?? []).reversed()
            for case let name? in names {
                if let image = UIImage(named: name) { return Image(uiImage: image) }
            }
            return nil
        #else
            return nil
        #endif
    }

    /// The device's OS, `iOS` or `iPadOS`.
    static var systemName: String {
        #if canImport(UIKit)
            UIDevice.current.systemName
        #else
            "macOS"
        #endif
    }
}
