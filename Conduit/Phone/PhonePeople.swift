//
//  PhonePeople.swift
//  Conduit
//
//  The people Hermes knows from this iPhone: only those the user picked, one
//  by one, in the system contact picker (which needs no address-book
//  access), each with how they're related to the user ("wife", "boss").
//  Kept on the phone and sent as the `contacts` list when the user shares
//  them (phone-v1-contract.md section 6). Picking someone again refreshes
//  what Conduit has; with Contacts access (limited or full) each sync reads
//  the picked people again, by their contact identifier, so edits made in
//  Contacts reach Hermes, and a person Conduit can't read is flagged on
//  their row with what Hermes keeps.
//

import Contacts
import ContactsUI
import CryptoKit
import Foundation
import UIKit

struct PhonePerson: Codable, Equatable, Identifiable {
    struct Phone: Codable, Equatable {
        var number: String
        var label: String?
    }

    struct Email: Codable, Equatable {
        var address: String
        var label: String?
    }

    /// Stable for the same contact: its identifier, hashed.
    var id: String
    var name: String
    var nickname: String?
    /// Typed by the user, at most 40 characters.
    var relation: String?
    var organization: String?
    var phones: [Phone] = []
    var emails: [Email] = []
    /// `YYYY-MM-DD`, or `--MM-DD` without a year.
    var birthday: String?
    /// The contact's identifier on this phone, to read them again. Never
    /// sent. Nil for someone picked before Conduit kept it.
    var contactID: String?

    static let maximum = 200
    static let relationLength = 40

    /// As the host takes it.
    var json: [String: Any] {
        var value: [String: Any] = ["id": id, "name": name]
        if let nickname, !nickname.isEmpty { value["nickname"] = nickname }
        if let relation = relation?.trimmingCharacters(in: .whitespacesAndNewlines), !relation.isEmpty {
            value["relation"] = String(relation.prefix(Self.relationLength))
        }
        if let organization, !organization.isEmpty { value["organization"] = organization }
        if !phones.isEmpty {
            value["phones"] = phones.prefix(10).map { phone -> [String: Any] in
                var entry: [String: Any] = ["number": phone.number]
                if let label = phone.label, !label.isEmpty { entry["label"] = label }
                return entry
            }
        }
        if !emails.isEmpty {
            value["emails"] = emails.prefix(10).map { email -> [String: Any] in
                var entry: [String: Any] = ["address": email.address]
                if let label = email.label, !label.isEmpty { entry["label"] = label }
                return entry
            }
        }
        if let birthday { value["birthday"] = birthday }
        return value
    }

    static func id(forContact identifier: String) -> String {
        "p_" + SHA256.hash(data: Data(identifier.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// What the host takes as a number: digits and dialling signs, at most
    /// 40, at least one digit. A number spelled with letters is left out.
    static func isDialable(_ number: String) -> Bool {
        let allowed = Set("0123456789+()*#.,;/ -")
        return (1...40).contains(number.count) && number.allSatisfy { allowed.contains($0) } && number.contains(where: \.isNumber)
    }

    /// Contacts often hold no-break spaces and typographic dashes.
    static func plainNumber(_ number: String) -> String {
        String(number.map { character -> Character in
            if character.isWhitespace { return " " }
            return "\u{2010}\u{2011}\u{2012}\u{2013}\u{2014}".contains(character) ? "-" : character
        }).trimmingCharacters(in: .whitespaces)
    }

    static func birthday(_ parts: DateComponents) -> String? {
        guard let month = parts.month, let day = parts.day, (1...12).contains(month), (1...31).contains(day) else { return nil }
        if let year = parts.year, year > 0, year != NSDateComponentUndefined {
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        return String(format: "--%02d-%02d", month, day)
    }
}

extension PhonePerson {
    /// What the picker handed back. Reads only the properties it fetched:
    /// asking a contact for one it didn't raises.
    init?(contact: CNContact, relation: String? = nil) {
        func has(_ key: String) -> Bool { contact.isKeyAvailable(key) }
        var name = ""
        if contact.areKeysAvailable([CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]) {
            name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        }
        if name.isEmpty {
            name = [has(CNContactGivenNameKey) ? contact.givenName : "", has(CNContactFamilyNameKey) ? contact.familyName : ""]
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        let organization = has(CNContactOrganizationNameKey) ? contact.organizationName : ""
        if name.isEmpty { name = organization }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        self.init(id: Self.id(forContact: contact.identifier), name: String(name.prefix(120)))
        self.relation = relation
        contactID = contact.identifier
        if has(CNContactNicknameKey), !contact.nickname.isEmpty { nickname = String(contact.nickname.prefix(60)) }
        if !organization.isEmpty, organization != name { self.organization = String(organization.prefix(120)) }
        if has(CNContactPhoneNumbersKey) {
            phones = Array(contact.phoneNumbers.map { value in
                Phone(number: Self.plainNumber(value.value.stringValue), label: value.label.map { CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0) })
            }.filter { Self.isDialable($0.number) }.prefix(10))
        }
        if has(CNContactEmailAddressesKey) {
            emails = Array(contact.emailAddresses.map { value in
                Email(address: value.value as String, label: value.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) })
            }.filter { $0.address.contains("@") && !$0.address.contains(" ") && $0.address.count <= 254 }.prefix(10))
        }
        if has(CNContactBirthdayKey), let parts = contact.birthday { birthday = Self.birthday(parts) }
    }
}

/// Whether Conduit may read the picked people again from Contacts.
enum PhoneContactsAccess: Equatable, Sendable {
    case notAsked, denied, limited, full

    var canRead: Bool { self == .limited || self == .full }
}

/// Why a picked person couldn't be read again. Hermes keeps what Conduit
/// last read for them.
enum PhonePersonProblem: Equatable, Sendable {
    /// Limited Contacts access that leaves them out.
    case notShared
    /// No longer in Contacts (deleted, or their card merged into another).
    case notFound
    /// Contacts didn't answer.
    case unreadable
}

enum PhoneContactRead: Equatable, Sendable {
    case person(PhonePerson)
    case problem(PhonePersonProblem)
}

/// Reads picked people again, and nothing else of the address book.
protocol PhoneContactsSource: Sendable {
    var access: PhoneContactsAccess { get }
    func requestAccess() async -> PhoneContactsAccess
    /// Each identifier's person as the contact says now, or why not.
    func read(_ identifiers: [String]) async -> [String: PhoneContactRead]
    /// For people picked before Conduit kept their contact's identifier:
    /// the identifier whose hash is each person's id. Reads identifiers only.
    /// Nil when Contacts couldn't be searched.
    func identifiers(for ids: Set<String>) async -> [String: String]?
}

struct SystemContactsSource: PhoneContactsSource {
    var access: PhoneContactsAccess {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if #available(iOS 18.0, *), status == .limited { return .limited }
        switch status {
        case .authorized: return .full
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    func requestAccess() async -> PhoneContactsAccess {
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        return access
    }

    /// What PhonePerson(contact:) reads.
    private static func keys() -> [CNKeyDescriptor] {
        [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]
            + [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
               CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactBirthdayKey].map { $0 as CNKeyDescriptor }
    }

    func read(_ identifiers: [String]) async -> [String: PhoneContactRead] {
        let limited = access == .limited
        return await Task.detached(priority: .utility) {
            let store = CNContactStore()
            let keys = Self.keys()
            var reads: [String: PhoneContactRead] = [:]
            for identifier in identifiers {
                do {
                    // The unified contact, so a card linked to another one still reads.
                    let contact = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keys)
                    // A card left with no name and no company has nothing to
                    // show: the last copy stays, with nothing wrong to say.
                    if let person = PhonePerson(contact: contact) { reads[identifier] = .person(person) }
                } catch let error as CNError where error.code == .recordDoesNotExist {
                    // Limited access answers the same for a contact it leaves out.
                    reads[identifier] = .problem(limited ? .notShared : .notFound)
                } catch {
                    reads[identifier] = .problem(.unreadable)
                }
            }
            return reads
        }.value
    }

    func identifiers(for ids: Set<String>) async -> [String: String]? {
        await Task.detached(priority: .utility) { () -> [String: String]? in
            let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
            // Each card on its own: the picker may have handed back any of a
            // linked contact's cards.
            request.unifyResults = false
            var found: [String: String] = [:]
            do {
                try CNContactStore().enumerateContacts(with: request) { contact, stop in
                    let id = PhonePerson.id(forContact: contact.identifier)
                    if ids.contains(id), found[id] == nil { found[id] = contact.identifier }
                    if found.count == ids.count { stop.pointee = true }
                }
            } catch {
                return nil
            }
            return found
        }.value
    }
}

/// The picked people, kept in the app's settings.
enum PhonePeopleStore {
    static let storageKey = "conduit.phoneSync.people.v1"

    static func load(from defaults: UserDefaults) -> [PhonePerson] {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([PhonePerson].self, from: $0) } ?? []
    }

    static func save(_ people: [PhonePerson], to defaults: UserDefaults) {
        guard !people.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(Array(people.prefix(PhonePerson.maximum))) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// The picked contacts added to `people`: someone picked again keeps
    /// their relation and gets what the contact says now.
    static func merging(_ picked: [PhonePerson], into people: [PhonePerson]) -> [PhonePerson] {
        var result = people
        for person in picked {
            if let index = result.firstIndex(where: { $0.id == person.id }) {
                var updated = person
                updated.relation = result[index].relation
                result[index] = updated
            } else {
                result.append(person)
            }
        }
        return Array(result.prefix(PhonePerson.maximum))
    }

    /// `people` with what Contacts says now, each keeping their id and
    /// relation; someone not read keeps what Conduit last read, with why
    /// in `problems`. `found`: identifiers found for people picked before
    /// Conduit kept them, nil when Contacts couldn't be searched for them.
    static func refreshed(_ people: [PhonePerson], reads: [String: PhoneContactRead], found: [String: String]?,
                          access: PhoneContactsAccess) -> (people: [PhonePerson], problems: [String: PhonePersonProblem]) {
        var problems: [String: PhonePersonProblem] = [:]
        let refreshed = people.map { person -> PhonePerson in
            guard let identifier = person.contactID ?? found?[person.id] else {
                // Picked before Conduit kept the identifier, and not found
                // (or the search failed).
                problems[person.id] = found == nil ? .unreadable : access == .limited ? .notShared : .notFound
                return person
            }
            var kept = person
            kept.contactID = identifier
            switch reads[identifier] {
            case .person(var fresh)?:
                fresh.id = person.id
                fresh.contactID = identifier
                fresh.relation = person.relation
                return fresh
            case .problem(let problem)?:
                problems[person.id] = problem
                return kept
            case nil:
                // Picked while the read ran: the picker's copy is current.
                return kept
            }
        }
        return (refreshed, problems)
    }
}

/// The system contact picker, shown from UIKit: it runs outside Conduit's
/// process, so it needs no contacts permission.
@MainActor
final class PhoneContactPicker: NSObject, CNContactPickerDelegate {
    private static var current: PhoneContactPicker?
    private let picked: ([CNContact]) -> Void

    private init(picked: @escaping ([CNContact]) -> Void) {
        self.picked = picked
    }

    static func present(_ picked: @escaping ([CNContact]) -> Void) {
        // One picker at a time: a second tap while one is up does nothing.
        guard current == nil, let top = topViewController() else { return }
        let delegate = PhoneContactPicker(picked: picked)
        current = delegate
        let picker = CNContactPickerViewController()
        picker.delegate = delegate
        top.present(picker, animated: true)
    }

    // The single-pick callback: the multi-pick one may hand back contacts with
    // only a name filled in.
    func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
        picked([contact])
        Self.current = nil
    }

    func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
        Self.current = nil
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
