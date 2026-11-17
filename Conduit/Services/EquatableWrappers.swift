//
//  EquatableWrappers.swift
//  Conduit
//
//  Fields a type's synthesized `==` should skip, or compare by instance.
//
//  Write no `static func ==` of your own on an app type: let Swift
//  synthesize it, and wrap the fields that need another comparison in one
//  of these. With a hand-written `==`, adding any member to its type
//  (stored or computed, even one nothing reads) recompiled 718 of the
//  app's 766 files; synthesized, the same change to ConversationAgentIdentity
//  recompiled 16 and to TranscriptCellEnvironment 3 (Xcode 27.2, CI's build
//  command, 2026-11-17). These wrappers keep their own `==`, but they are
//  generic and never change, so they cost nothing.
//  scripts/check-hand-written-equality.py holds the rule.
//
//  Keep this file in Conduit/Services: measured, the same file in
//  Conduit/Models brought back the near-full rebuilds (719 files) for every
//  type using a wrapper, for reasons the build log doesn't show.
//

import Foundation

/// A field that never makes two values unequal: an id each instance makes
/// for itself, a closure, a payload compared through another field.
@propertyWrapper
struct EqualityIgnored<Value>: Hashable {
    var wrappedValue: Value

    init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    static func == (lhs: Self, rhs: Self) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

extension EqualityIgnored: Sendable where Value: Sendable {}

/// An object field compared by instance (`===`), as an observable store or
/// a cache handed down unchanged is.
@propertyWrapper
struct IdentityEquatable<Value: AnyObject>: Hashable {
    var wrappedValue: Value

    init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.wrappedValue === rhs.wrappedValue }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(wrappedValue)) }
}

extension IdentityEquatable: Sendable where Value: Sendable {}

/// An optional object field compared by instance; two nils are equal.
@propertyWrapper
struct OptionalIdentityEquatable<Value: AnyObject>: Hashable {
    var wrappedValue: Value?

    init(wrappedValue: Value?) {
        self.wrappedValue = wrappedValue
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.wrappedValue === rhs.wrappedValue }
    func hash(into hasher: inout Hasher) { hasher.combine(wrappedValue.map(ObjectIdentifier.init)) }
}

extension OptionalIdentityEquatable: Sendable where Value: Sendable {}
