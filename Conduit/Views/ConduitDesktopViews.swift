//
//  ConduitDesktopViews.swift
//  Conduit
//
//  Conduit for desktop, offered from the phone (OtherAppOffer.swift):
//  Settings > About > Conduit for desktop, and the one-time card under the
//  last chat in Chats.
//

import SwiftUI

enum ConduitDesktopText {
    static var title: String { AppLocalization.string("Conduit for desktop", table: .settings) }
    static var platforms: String { AppLocalization.string("Windows, Mac and Linux", table: .settings) }
    static var shareLink: String { AppLocalization.string("Send the Link to Your Computer", table: .settings) }
}

/// Settings > About > Conduit for desktop: what it is, whether it has used
/// this Hermes, its download link to share, and Pair a Computer.
@MainActor
struct ConduitDesktopSettingsDetail: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @State private var clients: OtherAppOffer.HostClients?
    @State private var pairingComputer = false

    var body: some View {
        SettingsDetailContainer {
            ConduitSettingsSection(title: ConduitDesktopText.title, symbol: "desktopcomputer", tint: .conduitAccent) {
                Text(AppLocalization.string("The same chats, bots and calls on your Windows PC, Mac or Linux computer, with a coding workspace.", table: .settings))
                    .scaledFont(.footnote).foregroundStyle(.secondary)
                if let clients {
                    Label(
                        clients.desktopSeen
                            ? AppLocalization.string("Conduit for desktop has used this Hermes.", table: .settings)
                            : AppLocalization.string("Conduit for desktop hasn't used this Hermes yet.", table: .settings),
                        systemImage: clients.desktopSeen ? "checkmark.circle" : "circle.dashed"
                    )
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                }
                ShareLink(item: OtherAppOffer.desktopURL) {
                    Label(ConduitDesktopText.shareLink, systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.settings)
                .accessibilityIdentifier("settings.conduit-desktop.share")
                Link(destination: OtherAppOffer.desktopURL) {
                    HStack {
                        Image(systemName: "safari")
                        Text(verbatim: "hermesconduit.app/desktop")
                        Spacer()
                        Image(systemName: "arrow.up.right.square").scaledFont(.caption).foregroundStyle(.conduitTertiary)
                    }
                }
            }
            ConduitSettingsSection(title: PairComputerText.title, symbol: "qrcode.viewfinder", tint: .conduitAura) {
                Text(AppLocalization.string("Once it's installed, choose Pair with your iPhone on the computer and scan its code from here. It signs in with this phone's sign-ins.", table: .settings))
                    .scaledFont(.footnote).foregroundStyle(.secondary)
                Button(PairComputerText.title) { pairingComputer = true }
                    .buttonStyle(.settings)
                    .accessibilityIdentifier("settings.conduit-desktop.pair")
            }
        }
        .navigationTitle(ConduitDesktopText.title)
        // Again once the connection lands, for a page opened before it did.
        .task(id: "\(appState.activeDashboardID?.uuidString ?? "")|\(appState.isConnected)") {
            clients = await OtherAppOffer.readHostClients(appState.dashboardTicketBridge)
        }
        .sheet(isPresented: $pairingComputer) {
            PairComputerSheet()
                .environmentObject(appState)
        }
    }
}

/// Under the last chat, once: only where no Conduit for desktop has used
/// this host (OtherAppOffer.shouldOfferDesktop). Sharing its link or
/// closing it retires it for good.
@MainActor
struct ConduitDesktopCard: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(AppLocalization.string("Conduit is on your computer too", table: .settings))
                    .scaledFont(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button {
                    Haptics.selection()
                    OtherAppOffer.retire()
                    onDone()
                } label: {
                    Image(systemName: "xmark")
                        .scaledFont(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("Dismiss"))
                .accessibilityIdentifier("chats.conduit-desktop.dismiss")
            }
            Text(AppLocalization.string("The same chats and bots on Windows, Mac or Linux. Once it's installed, pair it from Settings in a few seconds.", table: .settings))
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // A button rather than a ShareLink, so the card retires in the
            // action itself (VoiceOver too) and leaves the list at once: the
            // share sheet anchors to the screen, not to the card.
            Button {
                OtherAppOffer.retire()
                MediaPreviewPresenter.shared.presentShare(link: OtherAppOffer.desktopURL)
                onDone()
            } label: {
                Label(ConduitDesktopText.shareLink, systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.settings)
            .accessibilityIdentifier("chats.conduit-desktop.share")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .settingsCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chats.conduit-desktop")
    }
}
