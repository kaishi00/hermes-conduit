//
//  PhonePeople.swift
//  Conduit
//
//  The people Hermes knows from this iPhone: only those the user picked, one
//  by one, in the system contact picker (which needs no address-book
//  access), each with how they're related to the user ("wife", "boss").
//  Kept on the phone and sent as the `contacts` list when the user shares
//  them (phone-v1-contract.md section 6). Picking someone again refreshes
//  what Conduit has.
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
