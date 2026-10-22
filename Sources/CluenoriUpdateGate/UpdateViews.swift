import Cluenori
import Foundation
import SwiftUI

// The update gate's views: functions of plain values and closures, so an app can show them however
// it presents things, and previews show every state. `cluenoriUpdateGate()` presents them from the
// manifest. Words come from the project when its manifest has them, else from this package, in the
// app's language.

/// "Update to continue": the full screen a required update shows, which can't be dismissed. Its
/// one button opens the store.
public struct UpdateRequiredView: View {
    let offer: UpdateOffer
    let appName: String
    let appIcon: Image?
    let onUpdate: () -> Void

    /// - Parameters:
    ///   - offer: the release to update to, and the project's words for it.
    ///   - appName: the app's name as the home screen shows it.
    ///   - appIcon: the app's icon; a symbol shows without one.
    ///   - onUpdate: opens the store's page, `offer.storeURL`.
    public init(offer: UpdateOffer, appName: String, appIcon: Image? = nil, onUpdate: @escaping () -> Void) {
        self.offer = offer
        self.appName = appName
        self.appIcon = appIcon
        self.onUpdate = onUpdate
    }

    public var body: some View {
        // Centered while it fits, scrolling when the text is too large for the screen.
        ViewThatFits(in: .vertical) {
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                content
                Spacer(minLength: 24)
                Spacer(minLength: 0).frame(maxHeight: 48)
            }
            ScrollView {
                content.padding(.vertical, 48)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                Button(action: onUpdate) {
                    Text("Update", bundle: #bundle, comment: "The button that opens the App Store to update the app.")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                Text(
                    "Version \(offer.version) is on the App Store.", bundle: #bundle,
                    comment: "Below the update button. The variable is the version to update to."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: 560)
        }
        .background { GateBackground() }
    }

    private var content: some View {
        VStack(spacing: 28) {
            GateIcon(appIcon: appIcon, systemImage: "arrow.down.app.fill", size: 112)
            GateText(
                title: offer.title.map { Text($0) }
                    ?? Text(
                        "Update to continue", bundle: #bundle,
                        comment: "Title of the full screen shown when the app's version may no longer be used."),
                message: offer.message.map { Text($0) }
                    ?? Text(
                        "This version of \(appName) is no longer supported. Update to version \(offer.version) to keep using it.",
                        bundle: #bundle,
                        comment:
                            "Message of the full screen shown when the app's version may no longer be used. The first variable is the app's name, the second the version to update to."
                    ),
                titleFont: .largeTitle.bold())
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }
}

/// The sheet a recommended update shows: the new version, Update, and Not Now, which closes it.
public struct UpdateRecommendedView: View {
    let offer: UpdateOffer
    let appName: String
    let appIcon: Image?
    let onUpdate: () -> Void
    let onDismiss: () -> Void

    /// - Parameters:
    ///   - offer: the release to update to, and the project's words for it.
    ///   - appName: the app's name as the home screen shows it.
    ///   - appIcon: the app's icon; a symbol shows without one.
    ///   - onUpdate: opens the store's page, `offer.storeURL`.
    ///   - onDismiss: closes the sheet: `Cluenori.dismissUpdatePrompt()`.
    public init(
        offer: UpdateOffer, appName: String, appIcon: Image? = nil, onUpdate: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.offer = offer
        self.appName = appName
        self.appIcon = appIcon
        self.onUpdate = onUpdate
        self.onDismiss = onDismiss
    }

    public var body: some View {
        GateSheet {
            GateIcon(appIcon: appIcon, systemImage: "arrow.down.app.fill", size: 76)
            GateText(
                title: offer.title.map { Text($0) }
                    ?? Text(
                        "A new version is available", bundle: #bundle,
                        comment: "Title of the sheet that recommends updating the app."),
                message: offer.message.map { Text($0) }
                    ?? Text(
                        "Version \(offer.version) of \(appName) is ready on the App Store.", bundle: #bundle,
                        comment:
                            "Message of the sheet that recommends updating the app. The first variable is the version to update to, the second the app's name."
                    ),
                titleFont: .title2.bold())
        } actions: {
            Button(action: onUpdate) {
                Text("Update", bundle: #bundle, comment: "The button that opens the App Store to update the app.")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            Button(action: onDismiss) {
                Text("Not Now", bundle: #bundle, comment: "Closes the sheet that recommends updating the app.")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.extraLarge)
        }
    }
}

/// The notice a device sees when the release is required but the update needs a newer OS than
/// the device has: it can't install it, so it isn't blocked; it is told, and carries on.
public struct DeviceUnsupportedView: View {
    let offer: UpdateOffer
    let appName: String
    let systemName: String
    let onDismiss: () -> Void

    /// - Parameters:
    ///   - offer: the release the device can't install, with the OS version it needs.
    ///   - appName: the app's name as the home screen shows it.
    ///   - systemName: the device's OS, `iOS` or `iPadOS`.
    ///   - onDismiss: closes the notice: `Cluenori.dismissUpdatePrompt()`.
    public init(offer: UpdateOffer, appName: String, systemName: String, onDismiss: @escaping () -> Void) {
        self.offer = offer
        self.appName = appName
        self.systemName = systemName
        self.onDismiss = onDismiss
    }

    public var body: some View {
        // The project's words ask for an update this device can't install, so the notice says what
        // is true here instead.
        // The OS and its version kept on one line: "iOS 26.0".
        let system = [systemName, offer.minimumOSVersion].compactMap(\.self).joined(separator: "\u{00A0}")
        GateSheet {
            GateIcon(
                appIcon: nil,
                systemImage: systemName == "iPadOS"
                    ? "ipad.badge.exclamationmark" : "iphone.gen3.badge.exclamationmark",
                size: 76)
            GateText(
                title: Text(
                    "The update needs \(system)", bundle: #bundle,
                    comment:
                        "Title of the notice shown when the device's OS is too old for the app's update. The variable is the OS and its version, such as iOS 26.0."
                ),
                message: Text(
                    "You can keep using this version of \(appName). The latest version needs \(system) or later.",
                    bundle: #bundle,
                    comment:
                        "Message of the notice shown when the device's OS is too old for the app's update. The first variable is the app's name, the second the OS and its version, such as iOS 26.0."
                ),
                titleFont: .title2.bold())
        } actions: {
            Button(action: onDismiss) {
                Text(
                    "OK", bundle: #bundle, comment: "Closes the notice that the device's OS is too old for the update."
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
        }
    }
}

// MARK: - Parts

/// The icon atop each view: the app's own, or a symbol on glass.
private struct GateIcon: View {
    let appIcon: Image?
    let systemImage: String
    @ScaledMetric private var size: CGFloat

    init(appIcon: Image?, systemImage: String, size: CGFloat) {
        self.appIcon = appIcon
        self.systemImage = systemImage
        _size = ScaledMetric(wrappedValue: size, relativeTo: .largeTitle)
    }

    var body: some View {
        Group {
            if let appIcon {
                appIcon
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: size * 0.225, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: size, height: size)
                    .glassEffect(.regular.tint(.accentColor.opacity(0.18)), in: .circle)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A view's title and message, centered.
private struct GateText: View {
    let title: Text
    let message: Text
    let titleFont: Font

    var body: some View {
        VStack(spacing: 12) {
            title
                .font(titleFont)
                .accessibilityAddTraits(.isHeader)
            message
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A soft prompt's sheet: as tall as its content, scrolling when the text is too large for the
/// screen, with its buttons beneath.
private struct GateSheet<Content: View, Actions: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 20) { content }
                VStack(spacing: 10) { actions }
            }
            .padding(.horizontal, 28)
            .padding(.top, 36)
            .padding(.bottom, 12)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                contentHeight = $0
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents(contentHeight > 0 ? [.height(contentHeight)] : [.medium])
        .presentationDragIndicator(.hidden)
    }
}

/// The required screen's background: the app's tint, faint, from the top.
private struct GateBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0.0)],
            startPoint: .top, endPoint: .center
        )
        .background(.background)
        .ignoresSafeArea()
    }
}
