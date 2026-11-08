//
//  RoomLinkSheets.swift
//  Conduit
//
//  Linking with someone (designs/cross-owner-agents, C2b): the invite this
//  Hermes makes, with its QR code and a link to send, and the sheet for an
//  invite someone sent, opened from another app, tapped in a chat, scanned
//  or pasted, which says who it's from before linking. Only the plugin reads
//  an invite (RoomLinks.swift), and neither sheet logs one.
//

import CoreImage.CIFilterBuiltins
import OSLog
import SwiftUI
import UIKit

private let roomLinkLogger = Logger(subsystem: "com.milim.relay", category: "People")

/// What the Link sheets say, apart from their views.
enum RoomLinkSheetText {
    /// What the sheet says in place of Link. `existing` is this Hermes' Link
    /// with them, as the list shows it, when it was read.
    static func stop(_ stop: RoomLinkPreview.Stop, name: String, existing: RoomLink?) -> String {
        switch stop {
        case .own:
            return AppLocalization.string("This invite is from your own Hermes. Send it to the person you're linking with.")
        case .expired:
            return AppLocalization.string("This invite has run out. Ask \(name) for a new one.")
        case .linked:
            let linked = existing?.name ?? name
            return AppLocalization.string("Your Hermes is already linked with \(linked).")
        }
    }
}

/// An invite's QR code, black on white in either theme, so any camera reads
/// it.
enum RoomLinkQRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let scaled = code.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

private struct RoomLinkQRCodeView: View {
    let text: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: 280)
        .frame(maxWidth: .infinity)
        .accessibilityElement()
        .accessibilityLabel(Text(AppLocalization.string("The invite's QR code")))
        .task(id: text) { image = RoomLinkQRCode.image(for: text) }
    }
}

/// The name the other person sees, kept on this device for the next invite
/// or accept.
private struct RoomLinkNameField: View {
    @Binding var name: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AppLocalization.string("Your name"))
                .scaledFont(.subheadline.weight(.semibold))
            TextField(AppLocalization.string("Your name"), text: $name)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .padding(10)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onChange(of: name) { _, typed in
                    if typed.count > RoomLinkName.maxLength { name = String(typed.prefix(RoomLinkName.maxLength)) }
                }
            Text(verbatim: caption)
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct RoomLinkWordsCard: View {
    let title: String
    let words: [String]
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title)
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
            Text(verbatim: PeopleSettingsText.words(words))
                .scaledFont(.title3.weight(.semibold))
                .textSelection(.enabled)
            Text(verbatim: caption)
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Link with someone: asks for the name the other person sees, makes the
/// invite, and shows its QR code, a link to send, this Hermes' four words and
/// until when it works. While it shows, it reads the Links now and then and
/// says when they've linked.
@MainActor
struct RoomLinkInviteSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage(RoomLinkName.storageKey) private var keptName = ""

    /// The invite, for the dashboard it was made on.
    private struct Made {
        let key: String
        let invite: RoomLinkInviteMade
        /// The Links before it, so the one that comes of it is theirs. Nil
        /// when they couldn't be read.
        let linksBefore: Set<String>?
    }

    @State private var name = ""
    @State private var made: Made?
    @State private var working = false
    @State private var error: String?
    @State private var linkedWith: RoomLink?

    private var key: String { appState.activeDashboardID?.uuidString ?? "" }
    private var shown: Made? { made?.key == key ? made : nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            // Settings' own pieces, as Bots Home's sheets are (Sheets in Settings' look).
            SettingsDetailContainer {
                if let shown {
                    invite(shown.invite)
                } else {
                    ask
                }
            }
            .navigationTitle(Text(AppLocalization.string("Link with someone")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(shown == nil ? AppLocalization.string("Cancel") : AppLocalization.string("Done")) { dismiss() }
                        .disabled(working)
                }
            }
        }
        .interactiveDismissDisabled(working)
        .onAppear { if name.isEmpty { name = keptName } }
        .task(id: shown?.invite.invite.id) { await followNewLink() }
    }

    private var ask: some View {
        ConduitSettingsSection(title: AppLocalization.string("Invite"), symbol: "link.badge.plus", tint: .conduitAccent) {
            Text(AppLocalization.string("Make an invite for the person you're linking with. They open it in Conduit to link your Hermes with theirs."))
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            RoomLinkNameField(name: $name, caption: AppLocalization.string("The invite says it's from this name."))
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(.footnote)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                if working {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(AppLocalization.string("Make invite")) { makeInvite() }
                    .buttonStyle(.settingsPrimary)
                    .disabled(working || trimmedName.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func invite(_ made: RoomLinkInviteMade) -> some View {
        if let linkedWith {
            Label(AppLocalization.string("Linked with \(linkedWith.name)"), systemImage: "checkmark.circle.fill")
                .scaledFont(.headline)
                .foregroundStyle(.green)
        }
        ConduitSettingsSection(title: AppLocalization.string("Invite"), symbol: "qrcode", tint: .conduitAccent) {
            RoomLinkQRCodeView(text: made.url.text)
            Text(AppLocalization.string("Ask them to scan this with their iPhone's camera, or send them the invite. It opens in Conduit."))
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = URL(string: made.url.text) {
                ShareLink(
                    item: url,
                    subject: Text(AppLocalization.string("Link with me in Conduit")),
                    message: Text(AppLocalization.string("Open this in Conduit to link your Hermes with mine."))
                ) {
                    Label(AppLocalization.string("Send the invite"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.settings)
            }
            Text(verbatim: until(made.invite))
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
        }
        ConduitSettingsSection(title: AppLocalization.string("Your Hermes' words"), symbol: "checkmark.shield", tint: .conduitAccent) {
            RoomLinkWordsCard(
                title: AppLocalization.string("Your Hermes' words"),
                words: made.words,
                caption: AppLocalization.string("When they open the invite, their Conduit shows these four words. Check together that the words match before they link.")
            )
        }
    }

    private func until(_ invite: RoomLinkInvite) -> String {
        let until = invite.expiresAt.formatted(
            .dateTime.weekday(.abbreviated).hour().minute().locale(AppLocalization.formattingLocale)
        )
        return AppLocalization.string("Works until \(until), for one person.")
    }

    private func makeInvite() {
        let name = trimmedName
        guard !name.isEmpty, !working else { return }
        let key = key
        working = true
        error = nil
        Task {
            defer { working = false }
            let client = appState.roomLinksClient
            let before = try? await client.list()
            do {
                let invite = try await client.invite(name: name)
                guard key == self.key else { return }
                Haptics.success()
                keptName = name
                linkedWith = nil
                made = Made(key: key, invite: invite, linksBefore: before.map { Set($0.links.map(\.id)) })
            } catch {
                guard !(error is CancellationError), key == self.key else { return }
                Haptics.error()
                roomLinkLogger.notice("Invite not made: \(LogRedaction.message(error), privacy: .public)")
                self.error = AppLocalization.string("Could not make the invite: \(RoomLinksClient.message(for: error))")
            }
        }
    }

    /// Every 3 s for up to 3 minutes while the invite shows: once their
    /// accept reaches this Hermes, it confirms it, and the Link is linked.
    private func followNewLink() async {
        guard let made = shown, let before = made.linksBefore, linkedWith == nil else { return }
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, made.key == key else { return }
            guard let list = try? await appState.roomLinksClient.list(), made.key == key else { continue }
            if let link = list.links.first(where: { !before.contains($0.id) && $0.status == "linked" }) {
                Haptics.success()
                linkedWith = link
                appState.followLinkedRoomInvites()
                return
            }
        }
    }
}

/// An invite someone sent: who it's from, their Hermes' four words and the
/// mailbox it names, and a button to link, with the name they'll see you
/// by. It stops before that when the invite ran out, is this Hermes' own, or
/// is from someone already linked. Once linked, it follows the Link until
/// their Hermes confirms it.
@MainActor
struct RoomLinkOpenedSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage(RoomLinkName.storageKey) private var keptName = ""
    let invite: RoomLinkURL

    /// What the plugin said about the invite, for the dashboard it was read
    /// on.
    private struct Read {
        let key: String
        let preview: RoomLinkPreview
        /// This Hermes' Link with them already, from the list.
        let existing: RoomLink?
    }

    @State private var read: Read?
    @State private var readError: String?
    @State private var name = ""
    @State private var working = false
    @State private var acceptError: String?
    /// The Link this sheet made, or one already waiting, as the list shows
    /// it now.
    @State private var link: RoomLink?
    /// The follow ran out with the Link still waiting.
    @State private var stillWaiting = false
    /// The Link went from the list while it was followed.
    @State private var gone = false

    private var key: String { appState.activeDashboardID?.uuidString ?? "" }
    private var shown: Read? { read?.key == key ? read : nil }
    /// Read again once the host's plugin says it keeps Links.
    private var readKey: String { "\(key)|\(appState.canLinkRooms)" }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Not connected yet, or the plugin hasn't said what it serves.
    private var waitsForHermes: Bool {
        if case .unknown = appState.notifierPlugin.state { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            SettingsDetailContainer {
                content
            }
            .navigationTitle(Text(AppLocalization.string("Link invite")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(link == nil ? AppLocalization.string("Cancel") : AppLocalization.string("Done")) { dismiss() }
                        .disabled(working)
                }
            }
        }
        .interactiveDismissDisabled(working)
        .onAppear { if name.isEmpty { name = keptName } }
        .task(id: readKey) { await load() }
        .task(id: link?.id) { await followLink() }
    }

    @ViewBuilder
    private var content: some View {
        if !appState.canLinkRooms {
            if waitsForHermes {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(AppLocalization.string("Conduit opens this invite once it's connected to your Hermes."))
                        .scaledFont(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label(AppLocalization.string("Update the Conduit plugin on your Hermes host to link with someone."), systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.orange)
            }
        } else if let shown {
            header(shown.preview)
            ConduitSettingsSection(title: AppLocalization.string("Their Hermes' words"), symbol: "checkmark.shield", tint: .conduitAccent) {
                RoomLinkWordsCard(
                    title: AppLocalization.string("\(shown.preview.name)'s Hermes"),
                    words: shown.preview.words,
                    caption: AppLocalization.string("Check that these are the four words \(shown.preview.name)'s Conduit shows for their Hermes. If they don't match, the invite isn't from them: don't link.")
                )
            }
            details(shown.preview)
            if let link {
                status(link)
            } else if let stop = shown.preview.stop {
                Label(RoomLinkSheetText.stop(stop, name: shown.preview.name, existing: shown.existing), systemImage: "info.circle")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                acceptForm(shown.preview)
            }
        } else if let readError {
            Label(readError, systemImage: "exclamationmark.triangle.fill")
                .scaledFont(.subheadline)
                .foregroundStyle(.orange)
            Button(AppLocalization.string("Try again")) { Task { await load() } }
                .buttonStyle(.settings)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
        }
    }

    private func header(_ preview: RoomLinkPreview) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.conduitAccent)
                .frame(width: 64, height: 64)
                .background(Color.conduitAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityHidden(true)
            Text(AppLocalization.string("Link with \(preview.name)?"))
                .scaledFont(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(AppLocalization.string("A Link lets you and someone else bring your agents into rooms together. It grants nothing by itself: in each room, you choose what your agents may do."))
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func details(_ preview: RoomLinkPreview) -> some View {
        let until = preview.expiresAt.formatted(
            .dateTime.weekday(.abbreviated).hour().minute().locale(AppLocalization.formattingLocale)
        )
        let registry = appState.savedDashboardRegistry
        return ConduitSettingsSection(title: AppLocalization.string("Invite"), symbol: "envelope", tint: .conduitAccent) {
            SettingsMetricRow(label: AppLocalization.string("From"), value: preview.name)
            SettingsMetricRow(label: AppLocalization.string("Mailbox"), value: preview.mailbox, lineLimit: 1)
            SettingsMetricRow(label: AppLocalization.string("Works until"), value: until)
            // Which Hermes links, when there's more than one.
            if registry.dashboards.count > 1, let label = registry.activeDashboardLabel {
                SettingsMetricRow(label: AppLocalization.string("Your Hermes"), value: label, lineLimit: 1)
            }
        }
    }

    private func acceptForm(_ preview: RoomLinkPreview) -> some View {
        SettingsCard {
            RoomLinkNameField(name: $name, caption: AppLocalization.string("\(preview.name) sees you by this name."))
            if let acceptError {
                Label(acceptError, systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(.footnote)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                if working {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(AppLocalization.string("Link with \(preview.name)")) { accept(preview) }
                    .buttonStyle(.settingsPrimary)
                    .disabled(working || trimmedName.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func status(_ link: RoomLink) -> some View {
        if let acceptError {
            Label(acceptError, systemImage: "exclamationmark.triangle.fill")
                .scaledFont(.footnote)
                .foregroundStyle(.orange)
        }
        if gone {
            Label(AppLocalization.string("This Link is gone from your Hermes. Ask \(link.name) for a new invite."), systemImage: "exclamationmark.triangle.fill")
                .scaledFont(.subheadline)
                .foregroundStyle(.orange)
        } else if link.status == "linked" {
            VStack(alignment: .leading, spacing: 6) {
                Label(AppLocalization.string("Linked with \(link.name)"), systemImage: "checkmark.circle.fill")
                    .scaledFont(.headline)
                    .foregroundStyle(.green)
                Text(AppLocalization.string("Your agents and theirs can now join rooms together. Settings › Multiplayer lists your Links."))
                    .scaledFont(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if stillWaiting {
            Text(AppLocalization.string("\(link.name)'s Hermes hasn't confirmed yet. It does once it reads its mailbox, and Settings › Multiplayer shows when it has."))
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if link.status == "waiting" {
            HStack(spacing: 10) {
                ProgressView()
                Text(AppLocalization.string("Waiting for \(link.name)'s Hermes to confirm"))
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else if let status = PeopleSettingsText.status(of: link) {
            Text(verbatim: status)
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Reads what the invite says, and this Hermes' Link with them, if any:
    /// one still waiting is followed as if this sheet made it.
    private func load() async {
        guard appState.canLinkRooms else { return }
        let key = key
        if read?.key != key {
            read = nil
            link = nil
            acceptError = nil
            stillWaiting = false
            gone = false
        }
        readError = nil
        let client = appState.roomLinksClient
        do {
            let preview = try await client.preview(invite)
            var existing: RoomLink?
            if let linkedAs = preview.linkedAs {
                existing = try? await client.list().links.first { $0.id == linkedAs }
            }
            guard key == self.key else { return }
            read = Read(key: key, preview: preview, existing: existing)
            if link == nil, let existing, existing.status == "waiting" {
                link = existing
            }
        } catch {
            guard !(error is CancellationError), !Task.isCancelled, key == self.key else { return }
            roomLinkLogger.notice("Invite not read: \(LogRedaction.message(error), privacy: .public)")
            readError = AppLocalization.string("Could not read this invite: \(RoomLinksClient.message(for: error))")
        }
    }

    private func accept(_ preview: RoomLinkPreview) {
        let name = trimmedName
        guard !name.isEmpty, !working else { return }
        let key = key
        working = true
        acceptError = nil
        Task {
            defer { working = false }
            let client = appState.roomLinksClient
            do {
                let made = try await client.accept(invite, name: name)
                guard key == self.key else { return }
                Haptics.success()
                keptName = name
                link = made
                if made.status == "linked" { appState.followLinkedRoomInvites() }
            } catch {
                guard !(error is CancellationError), key == self.key else { return }
                Haptics.error()
                roomLinkLogger.notice("Invite not accepted: \(LogRedaction.message(error), privacy: .public)")
                acceptError = AppLocalization.string("Could not link: \(RoomLinksClient.message(for: error))")
                // An accept the mailbox couldn't take yet keeps its Link,
                // waiting, and goes later while the invite lasts.
                let kept = try? await client.list().links.first { $0.words == preview.words && $0.status == "waiting" }
                if let kept, key == self.key {
                    keptName = name
                    link = kept
                }
            }
        }
    }

    /// Every 3 s for up to 90 s: their Hermes confirms within seconds while
    /// it runs.
    private func followLink() async {
        guard let first = link, first.status == "waiting" else { return }
        let key = key
        stillWaiting = false
        for _ in 0..<30 {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, key == self.key else { return }
            guard let list = try? await appState.roomLinksClient.list(), key == self.key else { continue }
            guard let now = list.links.first(where: { $0.id == first.id }) else {
                gone = true
                return
            }
            if now.status != "waiting" {
                if now.status == "linked" {
                    Haptics.success()
                    acceptError = nil
                    appState.followLinkedRoomInvites()
                }
                link = now
                return
            }
        }
        stillWaiting = true
    }
}
