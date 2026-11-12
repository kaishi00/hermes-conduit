//
//  AppState+ProfilePhotos.swift
//  Conduit
//
//  Moved out of AppState.swift (issue 828): Profile photos from Hermes.
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Profile photos from Hermes

    func noteProfileAvatarWrite(_ name: String) {
        profileAvatarWriteSerial &+= 1
        profileAvatarLastWrite[name] = profileAvatarWriteSerial
    }

    /// Keeps the profile's photo file a copy of its Hermes picture, so chats
    /// and the profile picker draw it at launch and offline. Only a roster
    /// saying the profile has no picture removes the copy (`dropMirror`).
    func mirrorHermesPicture(_ data: Data, for name: String, dashboardID: UUID?) {
        guard dashboardID == activeDashboardID,
              let saved = try? profileAppearanceStore.saveMirroredAvatar(data, for: name, dashboardID: dashboardID)
        else { return }
        // Published when the bytes changed (same URL, new content) or the
        // URL is new, so views redraw only for a real change.
        if saved.changed || profileAvatarURLs[name] != saved.url {
            profileAvatarURLs[name] = saved.url
        }
    }

    /// The picture is gone from Hermes (removed here, or its profile was
    /// deleted).
    func forgetHermesPicture(for name: String) {
        noteProfileAvatarWrite(name)
        botAvatarImages[name] = nil
        botAvatarFetchedGeneration[name] = nil
        removeProfileAvatarFile(for: name)
    }

    /// After each roster read, brings every profile's photo file in step
    /// with its Hermes picture (see `ProfileAvatarSyncAction`). Runs on its
    /// own, so a connection never waits on picture downloads, and one sync
    /// at a time. `rosterWriteSerial` is the write serial when the roster
    /// read started: a profile whose picture this app changed since is
    /// newer than the roster and left alone.
    func syncProfileAvatarsWithHermes(rosterWriteSerial: Int) {
        let epoch = botRosterEpoch
        let dashboardID = activeDashboardID
        let rows = botRoster
        let previous = profileAvatarSyncTask
        profileAvatarSyncTask = Task { @MainActor [weak self] in
            await previous?.value
            var fetches: [BotProfile] = []
            for bot in rows {
                guard let self, self.botRosterEpoch == epoch, self.activeDashboardID == dashboardID,
                      let client = self.client, self.isConnected else { return }
                if (self.profileAvatarLastWrite[bot.name] ?? 0) > rosterWriteSerial { continue }
                switch ProfileAvatarSyncAction.action(
                    hermesHasAvatar: bot.hasAvatar,
                    hasPhotoOnDevice: self.profileAvatarURLs[bot.name] != nil,
                    photoIsMirror: self.profileAppearanceStore.isMirrored(bot.name, dashboardID: dashboardID)
                ) {
                case .fetch:
                    fetches.append(bot)
                case .dropMirror:
                    self.removeProfileAvatarFile(for: bot.name)
                case .upload:
                    await self.moveDevicePhotoToHermes(bot, client: client)
                case .keep:
                    break
                }
            }
            // A few downloads at a time rather than one after another
            // (issue 1967); each still fences itself on the roster epoch.
            let width = Self.botPictureDownloadWidth
            for start in stride(from: 0, to: fetches.count, by: width) {
                guard let self, self.botRosterEpoch == epoch, self.activeDashboardID == dashboardID,
                      self.isConnected, !Task.isCancelled else { return }
                let downloads = fetches[start..<min(start + width, fetches.count)].map { bot in
                    Task { @MainActor in _ = await self.loadBotAvatarIfNeeded(bot) }
                }
                for download in downloads { await download.value }
            }
        }
    }

    /// Bot pictures downloaded at once by a roster's picture sync.
    static let botPictureDownloadWidth = 4

    /// A photo picked on this device before photos moved to Hermes becomes
    /// the profile's Hermes picture. A failed upload keeps the photo and is
    /// tried again at the next roster read. A failed `imageKind` write after
    /// a good upload is accepted: the picture is on Hermes and Conduit shows
    /// it, and only Desktop keeps its old look until the photo is set again
    /// (an asset without `imageKind = photo` is also a state Desktop itself
    /// writes, so a sync can't tell it apart to retry).
    private func moveDevicePhotoToHermes(_ bot: BotProfile, client: HermesClient) async {
        let dashboardID = activeDashboardID
        _ = await queueProfilePhotoWrite(bot.name) {
            // A write queued ahead of this one may have replaced the photo.
            guard self.activeDashboardID == dashboardID,
                  !self.profileAppearanceStore.isMirrored(bot.name, dashboardID: dashboardID),
                  let data = self.profileAppearanceStore.avatarData(for: bot.name, dashboardID: dashboardID)
            else { return nil }
            guard let png = BotAvatarImage.hermesPicture(fromPhoneCopy: data) else { return nil }
            return await self.setHermesPicture(png, for: bot, client: client)
        }
    }

    /// One retry of a ui_meta write that lost its compare-and-swap: re-read
    /// the roster so the merge starts from the other client's write, then
    /// apply the same patch on top of it.
    func retryBotMetaWrite(
        _ name: String,
        patch: [String: Any?],
        client: HermesClient,
        epoch: Int
    ) async -> BotMetaWriteOutcome {
        await refreshBotRosterAfterWrite()
        guard botOpenFenceIsCurrent(epoch: epoch, client: client),
              let fresh = botRoster.first(where: { $0.name == name }) else { return .failed }
        do {
            let result = try await client.configureBotProfile(
                name: name,
                botMeta: BotMetaPatch.merged(existing: fresh.botMeta, patch: patch),
                expectedMetaRevision: fresh.botMetaRevision
            )
            return BotMetaWriteOutcome(configureResult: result)
        } catch {
            return .failed
        }
    }

    /// A roster refresh guaranteed to START after the caller's write: an
    /// in-flight refresh may have read the gateway before it, so it is
    /// waited out and released instead of joined.
    func refreshBotRosterAfterWrite() async {
        if let running = botRosterRefreshFlight {
            await running.task.value
            if botRosterRefreshFlight === running {
                botRosterRefreshFlight = nil
            }
        }
        await refreshBotRoster()
        // A picture removed, a bot deleted or renamed: rooms over Links show
        // the roster as it now is (digest-gated, RoomLooks.swift).
        await shareRoomLooksIfNeeded()
    }
}
