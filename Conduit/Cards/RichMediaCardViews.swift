//
//  RichMediaCardViews.swift
//  Conduit
//
//  How media, contact and status cards look. Media plays in Conduit itself:
//  photos open full screen, video in the system player, audio in a row
//  with its own controls. A contact offers what its details allow (call,
//  message, email, the website, add to Contacts) and says when it's
//  someone the user shared with Hermes. A status shows where something
//  stands, and Hermes replaces it as it changes (its live name).
//

import AVKit
import Combine
import Contacts
import ContactsUI
import SwiftUI

/// Card pictures share the bounded download and decode used by Markdown.
struct RichCardImage<Content: View>: View {
    let url: URL
    var maxPixelSize: CGFloat = 2048
    @ViewBuilder let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty

    var body: some View {
        content(phase)
            .task(id: url) {
                if let cached = BoundedRemoteImage.cachedImage(url, maxPixelSize: maxPixelSize) {
                    phase = .success(Image(uiImage: cached))
                    return
                }
                phase = .empty
                let outcome = await BoundedRemoteImage.load(url, maxPixelSize: maxPixelSize)
                guard !Task.isCancelled else { return }
                switch outcome {
                case .image(let image):
                    phase = .success(Image(uiImage: image))
                case .tooLarge, .unavailable:
                    phase = .failure(URLError(.cannotDecodeContentData))
                }
            }
    }
}

// MARK: - Media

struct RichMediaCard: View {
    let card: RichCard

    @State private var opened: RichMedia?

    private var visual: [RichMedia] { card.media.filter { $0.kind != .audio } }
    private var audio: [RichMedia] { card.media.filter { $0.kind == .audio } }

    var body: some View {
        RichInfoCardFrame(title: card.title, source: card.source) {
            VStack(alignment: .leading, spacing: 12) {
                if visual.count == 1, let item = visual.first {
                    RichMediaTile(item: item, wide: true) { opened = item }
                } else if !visual.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(visual.enumerated()), id: \.offset) { _, item in
                                RichMediaTile(item: item, wide: false) { opened = item }
                            }
                        }
                    }
                }
                ForEach(Array(audio.enumerated()), id: \.offset) { _, item in
                    RichAudioRow(item: item)
                }
            }
        }
        .sheet(item: $opened) { item in
            RichMediaViewer(item: item)
        }
    }
}

extension RichMedia: Identifiable {
    var id: URL { url }
}

/// A photo or a video's still; a tap opens it.
private struct RichMediaTile: View {
    let item: RichMedia
    let wide: Bool
    let open: () -> Void

    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 190
    @ScaledMetric(relativeTo: .body) private var tileWidth: CGFloat = 220

    private var picture: URL? { item.kind == .image ? item.url : item.artwork }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Rectangle().fill(Color.secondary.opacity(0.12))
                    if let picture {
                        RichCardImage(url: picture) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Color.clear
                            }
                        }
                    }
                    if item.kind == .video {
                        Image(systemName: "play.circle.fill")
                            .font(.system(.largeTitle))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.45))
                            .accessibilityHidden(true)
                    }
                }
                .frame(height: height)
                .frame(maxWidth: wide ? .infinity : tileWidth)
                .frame(width: wide ? nil : tileWidth)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if let duration = item.duration {
                        Text(verbatim: RichMediaClock.text(duration))
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
                }
                if item.title != nil || item.by != nil || item.caption != nil {
                    RichMediaText(item: item)
                        .frame(maxWidth: wide ? .infinity : tileWidth, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: RichMediaText.spoken(item)))
        .accessibilityAddTraits(item.kind == .video ? .startsMediaSession : .isImage)
    }
}

/// An item's title, who made it and its caption.
private struct RichMediaText: View {
    let item: RichMedia

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title = item.title {
                Text(verbatim: title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            if let by = item.by {
                Text(verbatim: by)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let caption = item.caption {
                Text(verbatim: caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    static func spoken(_ item: RichMedia) -> String {
        [item.title ?? item.url.lastPathComponent, item.by, item.caption].compactMap { $0 }.joined(separator: ", ")
    }
}

enum RichMediaClock {
    /// Like 3:05, or 1:02:09.
    static func text(_ seconds: Int) -> String {
        let total = max(seconds, 0)
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

/// A photo full screen, or a video in the system player.
private struct RichMediaViewer: View {
    let item: RichMedia

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if item.kind == .video {
                    VideoPlayer(player: player)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .accessibilityLabel(Text(verbatim: RichMediaText.spoken(item)))
                        .accessibilityAddTraits(.startsMediaSession)
                } else {
                    RichCardImage(url: item.url, maxPixelSize: 4096) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFit()
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(Text(verbatim: RichMediaText.spoken(item)))
                }
                RichMediaText(item: item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            .padding(.vertical)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if let page = item.page {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            openURL(page)
                        } label: {
                            Image(systemName: "safari")
                        }
                        .accessibilityLabel(Text("Website"))
                    }
                }
            }
        }
        .onAppear {
            guard item.kind == .video, player == nil else { return }
            RichAudioPlayer.shared.stop(endingSession: false)
            RichAudioPlayer.preparePlayback()
            let player = AVPlayer(url: item.url)
            self.player = player
            player.play()
        }
        .onDisappear {
            guard let player else { return }
            player.pause()
            RichAudioPlayer.endPlayback()
        }
    }
}

/// Plays one audio item at a time, from any card.
@MainActor
final class RichAudioPlayer: ObservableObject {
    static let shared = RichAudioPlayer()

    @Published private(set) var playing: URL?
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var length: Double = 0

    private var player: AVPlayer?
    private var observer: Any?
    /// A file that won't load, or a call or Siri taking the audio, ends
    /// the item, so its row doesn't stay on Pause.
    private var endings: Set<AnyCancellable> = []

    func toggle(_ url: URL) {
        if playing == url {
            stop()
            return
        }
        stop(endingSession: false)
        Self.preparePlayback()
        let player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let item = self.player?.currentItem else { return }
                self.elapsed = time.seconds
                let length = item.duration.seconds
                self.length = length.isFinite ? length : 0
                // Not from inside the observer's own callback.
                if self.length > 0, self.elapsed >= self.length - 0.25 {
                    let ended = self.playing
                    Task { @MainActor in if self.playing == ended { self.stop() } }
                }
            }
        }
        player.currentItem?.publisher(for: \.status)
            .filter { $0 == .failed }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { if self?.playing == url { self?.stop() } } }
            .store(in: &endings)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .filter { ($0.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { if self?.playing == url { self?.stop(endingSession: false) } } }
            .store(in: &endings)
        self.player = player
        playing = url
        elapsed = 0
        length = 0
        player.play()
    }

    /// Whether a call, a voice conversation or Read Aloud holds the audio
    /// session, which a card then plays within and leaves alone.
    private static var sessionIsOwnedElsewhere: Bool {
        let coordinator = VoiceAudioSessionCoordinator.shared
        return coordinator.appliedPolicy != nil || coordinator.isInNativeCall
            || AVAudioSession.sharedInstance().category == .playAndRecord
    }

    /// Media plays even with the ringer switch off, as a player does.
    static func preparePlayback() {
        guard !sessionIsOwnedElsewhere else { return }
        VoiceAudioSessionCoordinator.shared.activateForCardPlayback()
    }

    /// Hands the audio back to whatever the card's media paused.
    static func endPlayback() {
        let session = AVAudioSession.sharedInstance()
        guard !sessionIsOwnedElsewhere, session.category == .playback else { return }
        VoiceAudioSessionCoordinator.shared.deactivateAfterCardPlayback()
    }

    /// `endingSession` false: another item starts right away.
    func stop(endingSession: Bool = true) {
        let wasPlaying = player != nil
        endings.removeAll()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        playing = nil
        elapsed = 0
        length = 0
        if endingSession, wasPlaying { Self.endPlayback() }
    }
}

private struct RichAudioRow: View {
    let item: RichMedia

    @ObservedObject private var player = RichAudioPlayer.shared
    @ScaledMetric(relativeTo: .body) private var artworkSize: CGFloat = 48

    private var isPlaying: Bool { player.playing == item.url }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.conduitAccent.opacity(0.14))
                if let artwork = item.artwork {
                    RichCardImage(url: artwork, maxPixelSize: 512) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: "waveform")
                                .foregroundStyle(Color.conduitAccent)
                        }
                    }
                } else {
                    Image(systemName: "waveform")
                        .foregroundStyle(Color.conduitAccent)
                }
            }
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                RichMediaText(item: item)
                if isPlaying, player.length > 0 {
                    ProgressView(value: min(player.elapsed / player.length, 1))
                        .tint(Color.conduitAccent)
                        .accessibilityHidden(true)
                } else if let duration = item.duration {
                    Text(verbatim: RichMediaClock.text(duration))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                player.toggle(item.url)
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(.title))
                    .foregroundStyle(Color.conduitAccent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? Text("Pause") : Text("Play"))
            .accessibilityValue(Text(verbatim: RichMediaText.spoken(item)))
        }
    }
}

// MARK: - Contact

struct RichContactCard: View {
    let card: RichCard

    /// The people the user shared with Hermes, read once for the card.
    @State private var shared: [PhonePerson] = []

    var body: some View {
        RichInfoCardFrame(title: card.title, source: card.source) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(card.people.enumerated()), id: \.offset) { index, person in
                    if index > 0 { Divider() }
                    RichPersonRow(person: person, known: person.match(in: shared))
                }
            }
        }
        .task(id: card) {
            shared = PhonePeopleStore.load(from: .standard)
        }
    }
}

private struct RichPersonRow: View {
    let person: RichPerson
    /// Who it is among the people the user shared with Hermes.
    let known: PhonePerson?

    @Environment(\.openURL) private var openURL
    @State private var addsContact = false
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: person.name)
                        .font(.subheadline.weight(.semibold))
                    if let detail = person.detail {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let known {
                        Label {
                            if let relation = known.relation, !relation.isEmpty {
                                Text("In your contacts") + Text(verbatim: " · \(relation)")
                            } else {
                                Text("In your contacts")
                            }
                        } icon: {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .accessibilityHidden(true)
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.conduitAccent)
                        .labelStyle(RichCompactLabelStyle())
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if let phone = person.phone {
                Text(verbatim: phone)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let email = person.email {
                Text(verbatim: email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let address = person.address {
                Text(verbatim: address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let note = person.note {
                Text(verbatim: note)
                    .font(.caption)
                    .italic()
            }
            actions
        }
        .sheet(isPresented: $addsContact) {
            RichNewContactSheet(person: person)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var avatar: some View {
        ZStack {
            Circle().fill(Color.conduitAccent.opacity(0.16))
            Text(verbatim: initials)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.conduitAccent)
            if let photo = person.photo {
                RichCardImage(url: photo.url, maxPixelSize: 512) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
            }
        }
        .frame(width: avatarSize, height: avatarSize)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initials: String {
        let words = person.name.split(separator: " ").prefix(2)
        return words.compactMap(\.first).map { String($0) }.joined().uppercased()
    }

    private var actions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let dialable = person.dialable {
                    if let url = URL(string: "tel:\(dialable)") {
                        RichPersonAction(title: Text("Call"), symbol: "phone.fill") { openURL(url) }
                    }
                    if let url = URL(string: "sms:\(dialable)") {
                        RichPersonAction(title: Text("Message"), symbol: "message.fill") { openURL(url) }
                    }
                }
                if let email = person.email, let url = RichPerson.mailtoURL(email) {
                    RichPersonAction(title: Text("Email"), symbol: "envelope.fill") { openURL(url) }
                }
                if let url = person.url {
                    RichPersonAction(title: Text("Website"), symbol: "safari.fill") { openURL(url) }
                }
                if known == nil, person.phone != nil || person.email != nil {
                    RichPersonAction(title: Text("Add to Contacts"), symbol: "person.crop.circle.badge.plus") { addsContact = true }
                }
            }
        }
    }
}

private struct RichPersonAction: View {
    let title: Text
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                title
            } icon: {
                Image(systemName: symbol)
                    .accessibilityHidden(true)
            }
            .font(.caption.weight(.semibold))
            .labelStyle(RichCompactLabelStyle())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(Color.conduitAccent)
            .background(Color.conduitAccent.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The system's new-contact screen, filled in from the card. It runs
/// outside Conduit's process, so it needs no contacts permission.
private struct RichNewContactSheet: UIViewControllerRepresentable {
    let person: RichPerson

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let contact = CNMutableContact()
        let parts = person.name.split(separator: " ", maxSplits: 1).map(String.init)
        contact.givenName = parts.first ?? person.name
        if parts.count > 1 { contact.familyName = parts[1] }
        if let detail = person.detail { contact.jobTitle = detail }
        if let phone = person.phone {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: phone))]
        }
        if let email = person.email {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelWork, value: email as NSString)]
        }
        if let url = person.url {
            contact.urlAddresses = [CNLabeledValue(label: CNLabelURLAddressHomePage, value: url.absoluteString as NSString)]
        }
        let controller = CNContactViewController(forNewContact: contact)
        controller.delegate = context.coordinator
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        let dismiss: () -> Void

        init(dismiss: @escaping () -> Void) {
            self.dismiss = dismiss
        }

        func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
            dismiss()
        }
    }
}

// MARK: - Status

struct RichStatusCard: View {
    let card: RichCard

    var body: some View {
        if let status = card.status {
            RichInfoCardFrame(title: card.title, source: card.source) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: status.state)
                            .font(.title3.weight(.semibold))
                        Spacer(minLength: 8)
                        RichPhaseBadge(phase: status.phase)
                    }
                    if let progress = status.shownProgress {
                        ProgressView(value: progress)
                            .tint(RichPhaseBadge.color(status.phase))
                            .accessibilityLabel(Text(verbatim: status.state))
                            .accessibilityValue(Text(verbatim: progress.formatted(.percent.precision(.fractionLength(0)).locale(AppLocalization.formattingLocale))))
                    }
                    if status.detail != nil || status.eta != nil {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let detail = status.detail {
                                Text(verbatim: detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if let eta = status.eta {
                                Label {
                                    Text(verbatim: eta)
                                } icon: {
                                    Image(systemName: "clock")
                                        .accessibilityHidden(true)
                                }
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .labelStyle(RichCompactLabelStyle())
                            }
                        }
                    }
                    if !status.milestones.isEmpty {
                        RichMilestones(milestones: status.milestones, tint: RichPhaseBadge.color(status.phase))
                    }
                }
            }
            .animation(.snappy, value: status)
        }
    }
}

private struct RichPhaseBadge: View {
    let phase: RichStatus.Phase

    static func color(_ phase: RichStatus.Phase) -> Color {
        switch phase {
        case .waiting: .secondary
        case .active: .conduitAccent
        case .done: .green
        case .problem: .orange
        }
    }

    var body: some View {
        Group {
            switch phase {
            case .waiting: Text("Not started")
            case .active: Text("In progress")
            case .done: Text("Done")
            case .problem: Text("Needs attention")
            }
        }
        .font(.caption2.weight(.bold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(Self.color(phase))
        .background(Self.color(phase).opacity(0.14), in: Capsule())
    }
}

/// The stages in order, done ones filled in.
private struct RichMilestones: View {
    let milestones: [RichStatus.Milestone]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(milestones.enumerated()), id: \.offset) { _, stage in
                HStack(spacing: 8) {
                    Image(systemName: stage.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(stage.done ? tint : Color.secondary)
                        .accessibilityHidden(true)
                    Text(verbatim: stage.label)
                        .font(.subheadline)
                        .foregroundStyle(stage.done ? Color.primary : Color.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(stage.done ? Text("Done") : Text(verbatim: ""))
            }
        }
    }
}

/// Where a chat showed a live card that a later one brought up to date.
struct RichLiveUpdatedLine: View {
    let title: String?

    var body: some View {
        Label {
            if let title {
                Text(verbatim: title) + Text(verbatim: " · ") + Text("Updated below")
            } else {
                Text("Updated below")
            }
        } icon: {
            Image(systemName: "arrow.down.circle")
                .accessibilityHidden(true)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.vertical, 2)
    }
}
