//
//  WatchJobSettings.swift
//  Conduit
//
//  The user's limits on a Watch call's Hermes jobs through the push relay
//  (designs/apple-watch-voice-direct.md, "Wrist-down jobs through the
//  relay"): how many jobs one call may start, and whether the model may
//  answer a job's approval request by voice or only the Watch's buttons
//  can. Picked in Voice settings > Apple Watch test; a test build's
//  setting, so its text is English only.
//

import Foundation

enum WatchJobSettings {
    static let jobsPerCallKey = "watchDirect.jobsPerCall"
    static let voiceApprovalsKey = "watchDirect.voiceApprovals"
    static let defaultJobsPerCall = 5
    /// The host plugin's own cap (WATCH_JOBS_MAX).
    static let maximumJobsPerCall = 20

    /// 0 keeps a Watch call's jobs on the iPhone's path.
    static var jobsPerCall: Int {
        let stored = UserDefaults.standard.object(forKey: jobsPerCallKey) as? Int ?? defaultJobsPerCall
        return min(max(stored, 0), maximumJobsPerCall)
    }

    /// Off by default: text in a web page or a job's output could talk the
    /// model into approving. Voice approvals only ever approve once.
    static var voiceApprovals: Bool {
        UserDefaults.standard.bool(forKey: voiceApprovalsKey)
    }

    static func jobsPerCallTitle(_ count: Int) -> String {
        count == 0 ? "Off (jobs go through the iPhone)" : "\(count) job\(count == 1 ? "" : "s")"
    }
}
