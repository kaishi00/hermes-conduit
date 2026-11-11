import Foundation

/// One open card in the Pulse widget (issue 2190): its words as the Pulse
/// screen shows them, and which of its buttons work from the widget.
struct PulseWidgetCard: Codable, Hashable, Identifiable {
    let id: Int
    /// What it's about ("Promise", "Deadline"…), in the app's language.
    let heading: String
    /// The pick's headline, or the card's words when it has no pick.
    let headline: String
    /// The pick's one more sentence; "" when it has none.
    let sentence: String
    let offersDone: Bool
    /// Do it sends the card's message from the widget. A pick's Ask, whose
    /// words are for the user to change first, isn't offered there.
    let offersDoIt: Bool
    let offersLater: Bool
    /// When the widget's Do it sent its message: the row says so in place
    /// of the button until Pulse sees it done.
    var sentAt: Date?

    init(id: Int, heading: String, headline: String, sentence: String,
         offersDone: Bool, offersDoIt: Bool, offersLater: Bool, sentAt: Date? = nil) {
        self.id = id
        self.heading = String(heading.prefix(80))
        self.headline = String(headline.prefix(400))
        self.sentence = String(sentence.prefix(400))
        self.offersDone = offersDone
        self.offersDoIt = offersDoIt
        self.offersLater = offersLater
        self.sentAt = sentAt
    }
}

/// What the Pulse widget shows: the newest open cards of the dashboard in
/// use, as it last read them, and when Pulse looks next. Kept as the
/// widget's last good read, for when the host can't be reached.
struct PulseWidgetSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1
    /// The most a large widget can show, with room for one more.
    static let maximumCards = 6
    /// How long a sent row stays sent while Pulse hasn't seen it done.
    static let sentLifetime: TimeInterval = 24 * 3600
    /// How long why a button didn't go through stays up.
    static let noteLifetime: TimeInterval = 15 * 60

    let schemaVersion: Int
    let dashboardID: UUID
    let appLanguage: String
    let cards: [PulseWidgetCard]
    /// Every open card, the ones that don't fit included.
    let openCount: Int
    /// When Pulse looks through the chats next (Settings > Pulse's Next look).
    let nextLookAt: Date?
    /// Pulse is quiet now, until then.
    let quietUntil: Date?
    /// Why the last button press didn't go through, or that Conduit needs
    /// opening to sign in again, and since when.
    let note: String?
    let noteAt: Date?

    init(dashboardID: UUID, appLanguage: String, cards: [PulseWidgetCard], openCount: Int,
         nextLookAt: Date?, quietUntil: Date?, note: String? = nil, noteAt: Date? = nil) {
        schemaVersion = Self.currentSchemaVersion
        self.dashboardID = dashboardID
        self.appLanguage = appLanguage
        var seen = Set<Int>()
        self.cards = Array(cards.filter { seen.insert($0.id).inserted }.prefix(Self.maximumCards))
        self.openCount = max(openCount, self.cards.count)
        self.nextLookAt = nextLookAt
        self.quietUntil = quietUntil
        self.note = note.flatMap { $0.isEmpty ? nil : String($0.prefix(200)) }
        self.noteAt = self.note == nil ? nil : noteAt
    }

    /// A fresh read, with what the last one kept that a read can't know:
    /// the rows Do it sent in the last day that are still open, and a
    /// button's note from the last quarter hour.
    func merging(_ previous: PulseWidgetSnapshot?, now: Date = Date()) -> PulseWidgetSnapshot {
        guard let previous, previous.dashboardID == dashboardID else { return self }
        let sent = Dictionary(previous.cards.compactMap { card in card.sentAt.map { (card.id, $0) } },
                              uniquingKeysWith: { first, _ in first })
        let kept = cards.map { card -> PulseWidgetCard in
            var card = card
            if card.sentAt == nil, let at = sent[card.id], now.timeIntervalSince(at) < Self.sentLifetime {
                card.sentAt = at
            }
            return card
        }
        let recent = note == nil && previous.noteAt.map { now.timeIntervalSince($0) < Self.noteLifetime } == true
        return with(cards: kept, note: recent ? .some(previous.note) : nil, noteAt: recent ? previous.noteAt : nil)
    }

    /// The same, with these changed. `note: .some(nil)` takes the note off.
    func with(cards: [PulseWidgetCard]? = nil, openCount: Int? = nil, nextLookAt: Date?? = nil,
              note: String?? = nil, noteAt: Date? = nil) -> PulseWidgetSnapshot {
        let cards = cards ?? self.cards
        let note = note ?? self.note
        return PulseWidgetSnapshot(
            dashboardID: dashboardID, appLanguage: appLanguage, cards: cards,
            openCount: openCount ?? max(self.openCount - (self.cards.count - cards.count), cards.count),
            nextLookAt: nextLookAt ?? self.nextLookAt, quietUntil: quietUntil,
            note: note, noteAt: noteAt ?? self.noteAt ?? (note == nil ? nil : Date())
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, dashboardID, appLanguage, cards, openCount, nextLookAt, quietUntil, note, noteAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: values,
                                                   debugDescription: "Unsupported Pulse widget schema")
        }
        self.init(
            dashboardID: try values.decode(UUID.self, forKey: .dashboardID),
            appLanguage: try values.decode(String.self, forKey: .appLanguage),
            cards: try values.decode([PulseWidgetCard].self, forKey: .cards),
            openCount: try values.decode(Int.self, forKey: .openCount),
            nextLookAt: try values.decodeIfPresent(Date.self, forKey: .nextLookAt),
            quietUntil: try values.decodeIfPresent(Date.self, forKey: .quietUntil),
            note: try values.decodeIfPresent(String.self, forKey: .note),
            noteAt: try values.decodeIfPresent(Date.self, forKey: .noteAt)
        )
    }
}

/// The Pulse widget's file, beside the launcher's in the widgets' App Group.
struct PulseWidgetStore {
    static let filename = "pulse-v1.json"
    private let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    static var production: PulseWidgetStore? {
        guard let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetSnapshotStore.appGroup) else { return nil }
        return PulseWidgetStore(directory: directory)
    }

    private var url: URL { directory.appendingPathComponent(Self.filename) }

    func read() -> PulseWidgetSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PulseWidgetSnapshot.self, from: data)
    }

    /// Whether it changed: the same bytes aren't written again.
    @discardableResult
    func write(_ snapshot: PulseWidgetSnapshot) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        if let previous = try? Data(contentsOf: url), previous == data { return false }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return true
    }

    /// Whether there was one to remove.
    @discardableResult
    func remove() -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        return (try? fileManager.removeItem(at: url)) != nil
    }
}

/// A tap on the Pulse widget: the Pulse screen, at a card when one was
/// tapped, on the dashboard the widget showed.
/// `conduit://widget/pulse?dashboard=<uuid>[&card=<id>]`.
struct PulseWidgetLink: Equatable {
    let dashboardID: UUID
    let card: Int?

    init(dashboardID: UUID, card: Int?) {
        self.dashboardID = dashboardID
        self.card = card
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "conduit", components.host?.lowercased() == "widget",
              components.percentEncodedPath == "/pulse",
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil else { return nil }
        let items = components.queryItems ?? []
        guard items.allSatisfy({ $0.name == "dashboard" || $0.name == "card" }),
              Set(items.map(\.name)).count == items.count,
              let dashboard = items.first(where: { $0.name == "dashboard" })?.value.flatMap(UUID.init(uuidString:))
        else { return nil }
        var card: Int?
        if let item = items.first(where: { $0.name == "card" }) {
            guard let value = item.value, let id = Int(value), id > 0 else { return nil }
            card = id
        }
        self.init(dashboardID: dashboard, card: card)
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "conduit"
        components.host = "widget"
        components.path = "/pulse"
        components.queryItems = [URLQueryItem(name: "dashboard", value: dashboardID.uuidString)]
            + (card.map { [URLQueryItem(name: "card", value: String($0))] } ?? [])
        return components.url!
    }
}
