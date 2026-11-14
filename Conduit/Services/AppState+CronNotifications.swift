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
        guard shownBot.cronMutedJobsKey == cronNotificationsKey(profile: activeProfile) else { return true }
        return !shownBot.cronMutedJobIDs.contains(job.id)
    }

    func refreshCronNotifications() async {
        guard supportsCronNotifications else { return }
        // A save in flight owns the list until the host answers it; a read
        // asked for meanwhile runs once it ends, so one triggered by the
        // capability landing is not lost.
        guard cronNotificationsChangingJobID == nil else {
            shownBot.cronNotificationsReadDeferred = true
            return
        }
        let profile = activeProfile
        let key = cronNotificationsKey(profile: profile)
        let generation = shownBot.cronNotificationsGeneration
        do {
            let choices = try await cronNotificationsClient.choices(profile: profile)
            guard key == cronNotificationsKey(profile: activeProfile),
                  cronNotificationsChangingJobID == nil,
                  generation == shownBot.cronNotificationsGeneration else { return }
            shownBot.cronMutedJobIDs = choices.muted
            shownBot.cronActingJobIDs = choices.act
            shownBot.cronShowsBotChatReports = choices.showsReports
            shownBot.cronMutedJobsKey = key
        } catch is CancellationError {
            return
        } catch {
            cronNotificationsLogger.notice("Cron notifications not read: \(LogRedaction.message(error), privacy: .public)")
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
        shownBot.cronNotificationsGeneration += 1
        defer {
            cronNotificationsChangingJobID = nil
            shownBot.cronNotificationsGeneration += 1
            if shownBot.cronNotificationsReadDeferred { refreshCronNotificationsAfterSave() }
        }
        // The switch moves at once; the host's answer settles it. Not read
        // yet: start from nothing muted, as the switch showed.
        let seeded = shownBot.cronMutedJobsKey != key
        if seeded {
            shownBot.cronMutedJobIDs = []
            shownBot.cronActingJobIDs = []
            // Unknown until a read says this Hermes shows reports.
            shownBot.cronShowsBotChatReports = false
            shownBot.cronMutedJobsKey = key
        }
        let wasMuted = shownBot.cronMutedJobIDs.contains(job.id)
        if notify { shownBot.cronMutedJobIDs.remove(job.id) } else { shownBot.cronMutedJobIDs.insert(job.id) }
        do {
            let muted = try await cronNotificationsClient.setNotify(notify, jobID: job.id, profile: profile)
            guard key == cronNotificationsKey(profile: activeProfile) else {
                // The workspace changed meanwhile: its own list was left to this save.
                refreshCronNotificationsAfterSave()
                return false
            }
            shownBot.cronMutedJobIDs = muted
            shownBot.cronMutedJobsKey = key
            return true
        } catch {
            let stillHere = key == cronNotificationsKey(profile: activeProfile)
            if shownBot.cronMutedJobsKey == key {
                if seeded {
                    // Never read: back to unknown, which reads as on.
                    shownBot.cronMutedJobsKey = nil
                    shownBot.cronMutedJobIDs = []
                    shownBot.cronActingJobIDs = []
                    shownBot.cronShowsBotChatReports = false
                } else if wasMuted {
                    shownBot.cronMutedJobIDs.insert(job.id)
                } else {
                    shownBot.cronMutedJobIDs.remove(job.id)
                }
            }
            if !stillHere || seeded { refreshCronNotificationsAfterSave() }
            if error is CancellationError { return false }
            cronNotificationsLogger.notice("Cron notifications not saved: \(LogRedaction.message(error), privacy: .public)")
            if stillHere {
                errorMessage = AppLocalization.string("Could not change this job's notifications: \(UserFacingError.message(for: error))", table: .tasks)
            }
            return false
        }
    }

    /// Whether the host's plugin shows a Bot Chat job's report without a
    /// turn, and keeps the per-job choice to let the bot act instead.
    var supportsCronBotChatReports: Bool {
        notifierPlugin.reports(CronNotificationsClient.botChatReportsCapability)
    }

    /// The job editor offers the choice: the plugin keeps it and the
    /// profile's Hermes can show a report without a turn, as last read.
    var offersCronBotChatChoice: Bool {
        supportsCronBotChatReports && shownBot.cronMutedJobsKey == cronNotificationsKey(profile: activeProfile)
            && shownBot.cronShowsBotChatReports
    }

    /// Whether a job delivered to a Bot Chat lets the bot act on its
    /// report. Unknown (not read yet) counts as just showing it, as the
    /// host defaults.
    func cronJobLetsBotAct(_ jobID: String) -> Bool {
        guard shownBot.cronMutedJobsKey == cronNotificationsKey(profile: activeProfile) else { return false }
        return shownBot.cronActingJobIDs.contains(jobID)
    }

    /// Saves a job's Bot Chat choice on the profile the job was saved to.
    /// Throws when the host didn't take it.
    func setCronJobLetsBotAct(_ act: Bool, jobID: String, profile: String) async throws {
        guard supportsCronBotChatReports else { return }
        shownBot.cronNotificationsGeneration += 1
        defer { shownBot.cronNotificationsGeneration += 1 }
        let choices = try await cronNotificationsClient.setActs(act, jobID: jobID, profile: profile)
        let key = cronNotificationsKey(profile: profile)
        guard key == cronNotificationsKey(profile: activeProfile) else { return }
        shownBot.cronMutedJobIDs = choices.muted
        shownBot.cronActingJobIDs = choices.act
        shownBot.cronShowsBotChatReports = choices.showsReports
        shownBot.cronMutedJobsKey = key
    }

    /// A refresh skipped while the save ran, once it has ended.
    private func refreshCronNotificationsAfterSave() {
        shownBot.cronNotificationsReadDeferred = false
        Task { @MainActor [weak self] in
            await Task.yield()
            await self?.refreshCronNotifications()
        }
    }
}
