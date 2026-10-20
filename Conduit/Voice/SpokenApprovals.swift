//
//  SpokenApprovals.swift
//  Conduit
//
//  Classic voice answers what waits on the user's OK out loud: a change
//  Hermes asked for on this iPhone (calendar, reminders, alarms), a
//  confirmation Hermes put on screen, or an approval in the open chat or a
//  voice job. A live call answers these with its own tools; Classic voice is
//  Hermes itself, which can't approve for the user, so Conduit takes a plain
//  yes or no when exactly one thing waits and answers it as a tap would,
//  which takes its card away. Hermes still hears the words.
//

import Foundation

/// What a spoken yes or no answers.
enum SpokenApprovalTarget: Equatable {
    /// A change Hermes asked for on this iPhone, by its id.
    case phoneChange(id: String)
    /// A confirmation Hermes put on screen, by its id.
    case presented(id: String)
    /// An approval card in the open chat, by its message id.
    case chatApproval(messageID: String)
    /// The approval a voice job's turn waits on.
    case jobApproval(id: UUID)
}

@MainActor
enum SpokenApprovals {
    /// What waits on the user while they speak.
    struct Waiting {
        var phoneChanges: [String] = []
        var presented: [PresentedConfirm] = []
        var chatApprovals: [String] = []
        var jobApprovals: [UUID] = []

        var count: Int { phoneChanges.count + presented.count + chatApprovals.count + jobApprovals.count }
    }

    /// The one thing `words` answer and whether they approve it. Nil when
    /// they aren't a plain yes or no for it, or when nothing or more than one
    /// thing waits: which one a bare yes meant would be a guess.
    static func answer(_ words: String, waiting: Waiting) -> (target: SpokenApprovalTarget, approve: Bool)? {
        guard waiting.count == 1 else { return nil }
        // "No", "no thanks", "never mind": a no with nothing more. "No, make
        // it 5" is a change, which only Hermes can make.
        let declines = VoiceThreadRouting.heldRequestAnswer(words) == .no(change: nil)
        let target: SpokenApprovalTarget
        let approves: Bool
        if let id = waiting.phoneChanges.first {
            target = .phoneChange(id: id)
            // A yes, or a short "change it" / "delete it" naming the change.
            approves = PhoneVoiceTools.confirmsChange(words)
        } else if let prompt = waiting.presented.first {
            target = .presented(id: prompt.id)
            // A yes, or one of the phrases Hermes gave ("send it").
            approves = prompt.isConfirmed(by: words)
        } else if let messageID = waiting.chatApprovals.first {
            target = .chatApproval(messageID: messageID)
            approves = VoiceCallDecisionOutcome.isYes(words)
        } else if let jobID = waiting.jobApprovals.first {
            target = .jobApproval(id: jobID)
            approves = VoiceCallDecisionOutcome.isYes(words)
        } else {
            return nil
        }
        if approves { return (target, true) }
        return declines ? (target, false) : nil
    }
}
