//
//  PhoneContactChanges.swift
//  Conduit
//
//  Contacts Hermes asks to add, or picked people's cards it asks to change
//  or delete, when the user lets it (Settings > Calendar & phone > People).
//  Each waits on a card; nothing here happens without the user's yes. A new
//  contact joins the picked people, so Hermes knows them from then on; a
//  deleted one leaves them.
//

import Contacts
import Foundation

/// What a contact change sets. Only what it names changes; phones and
/// emails, when named, replace the card's whole list.
struct PhoneContactEdit: Equatable {
    var givenName: String?
    var familyName: String?
    var nickname: String?
    var organization: String?
    /// How they relate to the user: kept by Conduit, never on the card.
    var relation: String?
    var phones: [PhonePerson.Phone]?
    var emails: [PhonePerson.Email]?
    /// `YYYY-MM-DD`, or `--MM-DD` without a year.
    var birthday: String?

    init?(json: [String: Any]) {
        func text(_ key: String, _ limit: Int) -> String? {
            (json[key] as? String).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit)) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        givenName = text("given_name", 120)
        familyName = text("family_name", 120)
        nickname = text("nickname", 120)
        organization = text("organization", 120)
        relation = text("relation", PhonePerson.relationLength)
        // A list with nothing usable in it changes nothing; only an empty one clears the card's.
        phones = (json["phones"] as? [[String: Any]]).flatMap { list in
            Self.usable(list, from: list.compactMap { entry -> PhonePerson.Phone? in
                guard let number = (entry["number"] as? String).map(PhonePerson.plainNumber),
                      PhonePerson.isDialable(number) else { return nil }
                return PhonePerson.Phone(number: number, label: entry["label"] as? String)
            })
        }
        emails = (json["emails"] as? [[String: Any]]).flatMap { list in
            Self.usable(list, from: list.compactMap { entry -> PhonePerson.Email? in
                guard let address = entry["address"] as? String, address.contains("@"), !address.contains(" ") else { return nil }
                return PhonePerson.Email(address: address, label: entry["label"] as? String)
            })
        }
        birthday = (json["birthday"] as? String).flatMap { Self.birthdayParts($0) != nil ? $0 : nil }
        guard givenName != nil || familyName != nil || nickname != nil || organization != nil || relation != nil
                || phones != nil || emails != nil || birthday != nil else { return nil }
    }

    /// Up to ten of what was usable, or nil when a list that had entries had
    /// none usable: replacing the card's list with nothing would wipe it.
    private static func usable<T>(_ sent: [[String: Any]], from kept: [T]) -> [T]? {
        if kept.isEmpty, !sent.isEmpty { return nil }
        return Array(kept.prefix(10))
    }

    /// A new contact needs a name or a company.
    var hasName: Bool { givenName != nil || familyName != nil || organization != nil }

    /// What a card changes, in a line: "+1 555 0100 · jo@example.com".
    var summary: String {
        var parts: [String] = []
        let name = [givenName, familyName].compactMap { $0 }.joined(separator: " ")
        if !name.isEmpty { parts.append(name) }
        if let nickname { parts.append("“\(nickname)”") }
        if let organization { parts.append(organization) }
        if let relation { parts.append(relation) }
        if let phones { parts.append(phones.isEmpty ? AppLocalization.string("no phone numbers") : phones.map(\.number).joined(separator: ", ")) }
        if let emails { parts.append(emails.isEmpty ? AppLocalization.string("no email addresses") : emails.map(\.address).joined(separator: ", ")) }
        if let birthday, let day = Self.birthdayParts(birthday),
           let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: day.year ?? 2000, month: day.month, day: day.day)) {
            parts.append(day.year == nil ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }

    static func birthdayParts(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        if text.hasPrefix("--"), parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]),
           (1...12).contains(month), (1...31).contains(day) {
            return DateComponents(month: month, day: day)
        }
        if text.count == 10, parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
           (1...12).contains(month), (1...31).contains(day) {
            return DateComponents(year: year, month: month, day: day)
        }
        return nil
    }

    /// Writes what this sets onto a card.
    func fill(_ contact: CNMutableContact) {
        if let givenName { contact.givenName = givenName }
        if let familyName { contact.familyName = familyName }
        if let nickname { contact.nickname = nickname }
        if let organization { contact.organizationName = organization }
        if let phones {
            contact.phoneNumbers = phones.map { CNLabeledValue(label: Self.label($0.label, phone: true), value: CNPhoneNumber(stringValue: $0.number)) }
        }
        if let emails {
            contact.emailAddresses = emails.map { CNLabeledValue(label: Self.label($0.label, phone: false), value: $0.address as NSString) }
        }
        if let birthday, let parts = Self.birthdayParts(birthday) {
            var components = parts
            components.calendar = Calendar(identifier: .gregorian)
            contact.birthday = components
        }
    }

    /// A label Hermes wrote (mobile, home, work), as Contacts' own when it is one.
    private static func label(_ text: String?, phone: Bool) -> String? {
        switch text?.lowercased() {
        case nil, "": return nil
        case "mobile", "cell": return phone ? CNLabelPhoneNumberMobile : CNLabelOther
        case "iphone": return phone ? CNLabelPhoneNumberiPhone : CNLabelOther
        case "main": return phone ? CNLabelPhoneNumberMain : CNLabelOther
        case "home": return CNLabelHome
        case "work": return CNLabelWork
        case "other": return CNLabelOther
        default: return text
        }
    }
}

enum PhoneContactChangeError: LocalizedError, Equatable {
    case noAccess
    case notFound

    var errorDescription: String? {
        switch self {
        case .noAccess: return AppLocalization.string("Conduit needs Contacts access to change contacts. Allow it in the Settings app.")
        case .notFound: return AppLocalization.string("That contact isn't on this iPhone any more.")
        }
    }
}

extension SystemContactsSource {
    func applyChange(_ change: PhoneChange, contactID: String?) async throws -> String {
        guard access.canRead else { throw PhoneContactChangeError.noAccess }
        return try await Task.detached(priority: .userInitiated) { () throws -> String in
            let store = CNContactStore()
            let request = CNSaveRequest()
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                        CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactBirthdayKey].map { $0 as CNKeyDescriptor }
            do {
                switch change.kind {
                case .addContact:
                    let contact = CNMutableContact()
                    change.fields.contact?.fill(contact)
                    request.add(contact, toContainerWithIdentifier: nil)
                    try store.execute(request)
                    return contact.identifier
                case .updateContact, .deleteContact:
                    guard let contactID else { throw PhoneContactChangeError.notFound }
                    let found = try store.unifiedContact(withIdentifier: contactID, keysToFetch: keys)
                    guard let contact = found.mutableCopy() as? CNMutableContact else { throw PhoneContactChangeError.notFound }
                    if change.kind == .deleteContact {
                        request.delete(contact)
                    } else {
                        change.fields.contact?.fill(contact)
                        request.update(contact)
                    }
                    try store.execute(request)
                    return contactID
                default:
                    throw PhoneContactChangeError.notFound
                }
            } catch let error as CNError where error.code == .recordDoesNotExist {
                throw PhoneContactChangeError.notFound
            } catch let error as CNError where error.code == .authorizationDenied {
                throw PhoneContactChangeError.noAccess
            }
        }.value
    }
}
