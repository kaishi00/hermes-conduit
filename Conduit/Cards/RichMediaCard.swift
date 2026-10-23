//
//  RichMediaCard.swift
//  Conduit
//
//  Media, contact and status cards as the views read them, built from
//  cards RichCardSchema has normalized. Media is Hermes' links to files it
//  found, with where they're from; a contact is what Hermes has on someone,
//  checked against the people the user shared with Hermes (PhonePeople) to
//  say when it's someone they know, and maybe a text Hermes wrote for the
//  user to send them; a status is where something in
//  progress stands, which Hermes keeps up to date by showing it again
//  under the same live name.
//

import Foundation

struct RichMedia: Equatable, Hashable {
    enum Kind: String {
        case image, video, audio
    }

    let kind: Kind
    let url: URL
    let title: String?
    let by: String?
    let caption: String?
    /// Seconds, for video and audio.
    let duration: Int?
    /// A still or cover, for video and audio.
    let artwork: URL?
    let page: URL?

    init?(json: [String: Any]) {
        guard let kind = (json["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let url = RichJSON.webURL(json["url"]) else { return nil }
        self.kind = kind
        self.url = url
        title = json["title"] as? String
        by = json["by"] as? String
        caption = json["caption"] as? String
        duration = kind == .image ? nil : RichJSON.number(json["duration"]).map { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        artwork = kind == .image ? nil : RichJSON.webURL(json["artwork"])
        page = RichJSON.webURL(json["page"])
    }
}

struct RichPerson: Equatable, Hashable {
    let name: String
    let detail: String?
    let phone: String?
    let email: String?
    let url: URL?
    let address: String?
    /// Hermes' own words about them.
    let note: String?
    /// A text Hermes wrote for the user to send them, only with a phone.
    let message: String?
    let photo: RichPlace.Photo?

    init?(json: [String: Any]) {
        guard let name = json["name"] as? String, !name.isEmpty else { return nil }
        self.name = name
        detail = json["detail"] as? String
        phone = (json["phone"] as? String).flatMap { RichCardSchema.isPhone($0) ? $0 : nil }
        email = (json["email"] as? String).flatMap { RichCardSchema.isEmail($0) ? $0 : nil }
        url = RichJSON.webURL(json["url"])
        address = json["address"] as? String
        note = json["note"] as? String
        message = phone == nil ? nil : (json["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let photo = json["photo"] as? [String: Any], let url = RichJSON.webURL(photo["url"]),
           url.scheme?.lowercased() == "https", let source = photo["source"] as? String {
            self.photo = RichPlace.Photo(url: url, source: source, pageURL: RichJSON.webURL(photo["page_url"]))
        } else {
            photo = nil
        }
    }

    /// The number to dial: its digits, with a leading +.
    var dialable: String? {
        guard let phone else { return nil }
        let digits = phone.filter(\.isASCII).filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        // "+44 …" or "(+44) …": a + before the first digit is international.
        return phone.prefix(while: { !$0.isNumber }).contains("+") ? "+" + digits : digits
    }

    /// The Email action's link. It is built from parts, so nothing in the
    /// address can add a header or a recipient to the composer.
    static func mailtoURL(_ email: String) -> URL? {
        var link = URLComponents()
        link.scheme = "mailto"
        link.path = email
        return link.url
    }

    /// The person the user shared with Hermes that this is: the same
    /// number, the same email, or the same name.
    func match(in people: [PhonePerson]) -> PhonePerson? {
        if let dialable {
            let tail = String(dialable.filter(\.isNumber).suffix(9))
            if tail.count >= 7, let person = people.first(where: { person in
                person.phones.contains { String($0.number.filter(\.isASCII).filter(\.isNumber).suffix(9)) == tail }
            }) {
                return person
            }
        }
        if let email = email?.lowercased(),
           let person = people.first(where: { $0.emails.contains { $0.address.lowercased() == email } }) {
            return person
        }
        let name = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return people.first { person in
            [person.name, person.nickname ?? ""].contains {
                !$0.isEmpty && $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == name
            }
        }
    }
}

struct RichStatus: Equatable, Hashable {
    enum Phase: String {
        case waiting, active, done, problem
    }

    struct Milestone: Equatable, Hashable {
        let label: String
        let done: Bool
    }

    let state: String
    let phase: Phase
    /// 0 to 1, when Hermes knows.
    let progress: Double?
    let detail: String?
    let eta: String?
    let milestones: [Milestone]

    init?(json: Any?) {
        guard let json = json as? [String: Any], let state = json["state"] as? String, !state.isEmpty else { return nil }
        self.state = state
        phase = (json["phase"] as? String).flatMap(Phase.init(rawValue:)) ?? .active
        progress = RichJSON.number(json["progress"]).map { min(max($0, 0), 1) }
        detail = json["detail"] as? String
        eta = json["eta"] as? String
        milestones = (json["milestones"] as? [[String: Any]] ?? []).compactMap { stage in
            guard let label = stage["label"] as? String else { return nil }
            return Milestone(label: label, done: stage["done"] as? Bool ?? false)
        }
    }

    /// What the bar shows and VoiceOver reads: full once it's done.
    var shownProgress: Double? {
        progress.map { phase == .done ? 1 : $0 }
    }
}
