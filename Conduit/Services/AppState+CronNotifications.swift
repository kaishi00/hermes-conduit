//
//  AppState+CronNotifications.swift
//  Conduit
//
//  Per-job cron notifications: the Cron tab's "Notify me" switch, kept by
//  the host's notifier plugin so its turn-end hooks skip a muted job's push.
//

import Foundation
import OSLog

private let cronNotificationsLogger = Logger(subsystem: "com.milim.relay", category: "CronNotifications")

extension AppState {
    /// Whether the host's notifier plugin keeps per-job cron notifications.
    var supportsCronNotifications: Bool {
        notifierPlugin.reports(CronNotificationsClient.capability)
    }

    private func cronNotificationsKey(profile: String) -> String {
        (activeDashboardID?.uuidString ?? "") + "|" + profile
    }

    /// Whether a job's runs notify on the active dashboard and profile.
    /// Unknown (not read yet) counts as on, as the host defaults.
    func cronJobNotifies(_ job: CronJob) -> Bool {
        guard cronMutedJobsKey == cronNotificationsKey(profile: activeProfile) else { return true }
        return !cronMutedJobIDs.contains(job.id)
    }

    func refreshCronNotifications() async {
        // A save in flight owns the list until the host answers it.
        guard supportsCronNotifications, cronNotificationsChangingJobID == nil else { return }
        let profile = activeProfile
        let key = cronNotificationsKey(profile: profile)
        let generation = cronNotificationsGeneration
        do {
            let muted = try await cronNotificationsClient.muted(profile: profile)
            guard key == cronNotificationsKey(profile: activeProfile),
                  cronNotificationsChangingJobID == nil,
                  generation == cronNotificationsGeneration else { return }
            cronMutedJobIDs = muted
            cronMutedJobsKey = key
        } catch is CancellationError {
            return
        } catch {
            cronNotificationsLogger.notice("Cron notifications not read: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Turns a job's notifications on or off. False when the host didn't
    /// take it (the switch then shows the host's value again) or another
    /// change is still in flight (the switch is disabled meanwhile).
    @discardableResult
    func setCronJobNotifies(_ notify: Bool, for job: CronJob) async -> Bool {
        guard supportsCronNotifications, cronNotificationsChangingJobID == nil else { return false }
        let profile = activeProfile
        let key = cronNotificationsKey(profile: profile)
        cronNotificationsChangingJobID = job.id
        cronNotificationsGeneration += 1
        defer {
            cronNotificationsChangingJobID = nil
            cronNotificationsGeneration += 1
        }
        // The switch moves at once; the host's answer settles it. Not read
        // yet: start from nothing muted, as the switch showed.
        let seeded = cronMutedJobsKey != key
        if seeded {
            cronMutedJobIDs = []
            cronMutedJobsKey = key
        }
        let wasMuted = cronMutedJobIDs.contains(job.id)
        if notify { cronMutedJobIDs.remove(job.id) } else { cronMutedJobIDs.insert(job.id) }
        do {
            let muted = try await cronNotificationsClient.setNotify(notify, jobID: job.id, profile: profile)
            guard key == cronNotificationsKey(profile: activeProfile) else {
                // The workspace changed meanwhile: its own list was left to this save.
                refreshCronNotificationsAfterSave()
                return false
            }
            cronMutedJobIDs = muted
            cronMutedJobsKey = key
            return true
        } catch {
            let stillHere = key == cronNotificationsKey(profile: activeProfile)
            if cronMutedJobsKey == key {
                if seeded {
                    // Never read: back to unknown, which reads as on.
                    cronMutedJobsKey = nil
                    cronMutedJobIDs = []
                } else if wasMuted {
                    cronMutedJobIDs.insert(job.id)
                } else {
                    cronMutedJobIDs.remove(job.id)
                }
            }
            if !stillHere || seeded { refreshCronNotificationsAfterSave() }
            if error is CancellationError { return false }
            cronNotificationsLogger.notice("Cron notifications not saved: \(error.localizedDescription, privacy: .public)")
            if stillHere {
                errorMessage = AppLocalization.string("Could not change this job's notifications: \(UserFacingError.message(for: error))")
            }
            return false
        }
    }

    /// A refresh skipped while the save ran, once it has ended.
    private func refreshCronNotificationsAfterSave() {
        Task { @MainActor [weak self] in
            await Task.yield()
            await self?.refreshCronNotifications()
        }
    }
}
