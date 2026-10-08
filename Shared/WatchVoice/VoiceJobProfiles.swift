//
//  VoiceJobProfiles.swift
//  Conduit
//
//  Which of the user's Hermes profiles a voice job runs on: "for Fam,
//  check the router" runs on Fam. Shared by the iPhone's calls and the
//  Watch's, which resolve the name from the list the iPhone sends it.
//

import Foundation

/// What a profile or bot name spoken for a job refers to.
enum VoiceJobProfileTarget: Equatable {
    /// The profile the call is already on.
    case active
    /// Another profile (or bot) on the same Hermes server.
    case other(String)
    case unknown
}

enum VoiceJobProfiles {
    /// Where a job goes: `profile` nil is the call's own profile, and
    /// `label` is the name the user gave another one.
    enum Route: Equatable {
        case run(instructions: String, profile: String?, label: String?)
        /// A name that isn't one of the user's profiles: never guessed at.
        case unknown(String)
    }

    /// `spokenProfile` is the profile or bot the model named for the job.
    /// Without one, a leading "for <profile>, …" in the instructions names
    /// it; with one, that lead is trimmed only when it names the same profile.
    static func route(
        instructions: String,
        spokenProfile: String?,
        resolve: (String) -> VoiceJobProfileTarget
    ) -> Route {
        var instructions = instructions
        var profile: String?
        var label: String?
        if let spoken = spokenProfile?.trimmingCharacters(in: .whitespacesAndNewlines), !spoken.isEmpty {
            switch resolve(spoken) {
            case .active:
                break
            case .other(let name):
                profile = name
                label = spoken
            case .unknown:
                return .unknown(spoken)
            }
            // The model may also leave "for Fam, …" in the task itself.
            if let target = leadingTarget(in: instructions, resolve: resolve),
               target.target == (profile.map { VoiceJobProfileTarget.other($0) } ?? .active) {
                instructions = target.remainder
            }
        } else if let target = leadingTarget(in: instructions, resolve: resolve) {
            if case .other(let name) = target.target {
                profile = name
                label = target.name
            }
            instructions = target.remainder
        }
        return .run(instructions: instructions, profile: profile, label: label)
    }

    /// Where a Watch job goes when the host runs jobs on some of the
    /// user's other profiles (`hosted`, lowercased).
    enum RelayRoute: Equatable {
        /// Through the relay: `profile` nil is the call's own.
        case relay(instructions: String, profile: String?)
        /// One of the user's profiles the host doesn't run this call's
        /// jobs on: the iPhone starts it, as before.
        case viaPhone(label: String)
        /// Not one of the names the iPhone sent: the iPhone, which knows
        /// them all, answers it.
        case unknown(String)
    }

    static func relayRoute(
        instructions: String,
        spokenProfile: String?,
        names: [WatchVoiceWire.JobProfileName],
        hosted: Set<String>
    ) -> RelayRoute {
        switch route(instructions: instructions, spokenProfile: spokenProfile, resolve: { target(named: $0, in: names) }) {
        case .unknown(let name):
            return .unknown(name)
        case .run(let task, nil, _):
            return .relay(instructions: task, profile: nil)
        case .run(let task, let profile?, let label):
            return hosted.contains(profile.lowercased()) ? .relay(instructions: task, profile: profile) : .viaPhone(label: label ?? profile)
        }
    }

    /// The answer to a job for one of the user's profiles a Watch call
    /// can't start it on.
    static func viaPhoneReply(_ name: String) -> String {
        "Jobs on \(name) can't start from this Watch call. Tell the user to start them from the iPhone."
    }

    /// The answer to a job for a profile the user doesn't have.
    static func unknownProfileReply(_ name: String) -> String {
        "I don't know a profile or bot called \(name), so I didn't start the job."
    }

    /// "for Fam, check the router" → (Fam, "check the router").
    /// Only a leading "for/on/with <name>" whose name (up to three words)
    /// is a known profile (this one included) counts; anything else stays
    /// the task.
    static func leadingTarget(
        in instructions: String,
        resolve: (String) -> VoiceJobProfileTarget
    ) -> (target: VoiceJobProfileTarget, name: String, remainder: String)? {
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let words = instructions.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard words.count >= 3,
              // Not "to": it usually starts a verb ("to check the router").
              ["for", "on", "with"].contains(words[0].lowercased()) else { return nil }
        for length in stride(from: min(3, words.count - 2), through: 1, by: -1) {
            let nameWords = words[1...length]
            let name = nameWords.joined(separator: " ").trimmingCharacters(in: separators)
            guard !name.isEmpty else { continue }
            let target = resolve(name)
            guard target != .unknown else { continue }
            let remainder = words[(length + 1)...].joined(separator: " ")
                .trimmingCharacters(in: separators)
            guard !remainder.isEmpty else { return nil }
            return (target, name, remainder)
        }
        return nil
    }

    /// `name` resolved against the names the iPhone listed, in its order
    /// (profiles, then the default profile's name, then bots), as
    /// `AppState.voiceJobProfileTarget` resolves it there.
    static func target(named name: String, in names: [WatchVoiceWire.JobProfileName]) -> VoiceJobProfileTarget {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return .unknown }
        let match = names.first { entry in
            entry.names.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(wanted) == .orderedSame }
        }
        guard let match else { return .unknown }
        return match.profile.map { .other($0) } ?? .active
    }
}
