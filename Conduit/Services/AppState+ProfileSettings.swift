//
//  AppState+ProfileSettings.swift
//  Conduit
//
//  A dashboard's settings and its profiles' names, pictures, colors and
//  order, with the server identity a chat resume keys on. Moved out of
//  AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

extension AppState {
    // MARK: - Profile and connection settings

    /// Runtime-only speech retirement at the server-replacement boundary.
    ///
    /// Voice Conversation and Read Aloud own speech transports that are
    /// independent of `HermesClient`: a gateway binds one dashboard bridge and
    /// base URL, and each spoken response opens its own ticket-minted speech
    /// websocket. Those transports would otherwise keep streaming against —
    /// and playing audio from — the outgoing server after a new connection
    /// becomes authoritative, because replacing the client or the gateway
    /// reference does not terminate an operation that already holds the old
    /// gateway. This mirrors the voice teardown `disconnect()` performs, with
    /// the operation generations doing the rest: every parked continuation
    /// (capture resume, speech drain, playback completion) re-checks its
    /// generation and turns inert, so nothing the outgoing server owned can
    /// resurrect capture or playback.
    ///
    /// Deliberately NOT logout: no credential, cookie, ticket, or preference
    /// state is touched here — only the outgoing connection's runtime speech
    /// ownership. If the incoming connection fails to activate, the retired
    /// operations stay retired; the outgoing server's speech is not valid
    /// merely because the replacement failed. Same-server reconnects never
    /// reach this path: `prepareDashboardBridge(for:)` keeps the bridge (and
    /// therefore the gateways) when the normalized URL is unchanged, and the
    /// capability refresh intentionally keeps equivalent gateways alive.
    func retireSpeechOperationsForServerReplacement(previousIdentity: String, identity: String) {
        let voiceWasLive = voiceConversationController.hasLiveVoiceSession
        let readAloudWasActive: Bool
        if case .idle = messageReadAloudController.state {
            readAloudWasActive = false
        } else {
            readAloudWasActive = true
        }
        speechOwnershipLog.info(
            "Server replacement \(previousIdentity, privacy: .private) -> \(identity, privacy: .private): retiring speech ownership (voiceLive=\(voiceWasLive ? "yes" : "no", privacy: .public), readAloudActive=\(readAloudWasActive ? "yes" : "no", privacy: .public))"
        )
        voiceConversationController.stop()
        stopQwenLiveConversation()
        stopGeminiLiveConversation()
        stopGPTLiveConversation()
        stopGrokLiveConversation()
        stopLocalLiveConversation()
        retireVoiceBackgroundJobs()
        // Read Aloud teardown flows through the controller's own pinned
        // Option-A semantics: replacing a non-nil gateway performs the single
        // authoritative stop. A nil gateway means nothing can be live — an
        // operation cannot start without one.
        messageReadAloudController.setGateway(nil)
        // A swapped gateway must never hand a later operation to the outgoing
        // server's bridge; the incoming connection rebuilds both references
        // from its own bridge (capability refresh, read-aloud assignment).
        voiceConversationController.setGateway(nil)
        readAloudGatewayBridge = nil
        readAloudSpeaker = nil
        // Server replacement is a destructive Voice boundary: a suspended
        // conversation from the outgoing server must never be restored.
        suspendedVoiceConversation = nil
        voiceSheetShouldAutoListen = false
        voiceControllerSessionProfile = nil
        showVoiceSheet = false
        clearClassicVoiceCards()
    }

    /// Internal so the saved-dashboard migration can normalize the legacy
    /// identity key the same way the runtime boundary does.
    nonisolated static func normalizedChatResumeServerIdentity(_ baseURL: String) -> String? {
        guard let normalized = try? ConnectionURLPolicy.normalizedBaseURL(baseURL),
              var components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else { return nil }
        components.scheme = scheme
        components.host = host
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        return components.string
    }

    /// Stored chat-resume identities are either a normalized server URL
    /// (legacy builds) or a dashboard UUID string (multi-server). UUID
    /// strings pass through untouched; URL shapes normalize as before. A
    /// UUID-shaped stored value must never be URL-parsed into nil — that
    /// would make every cold start look like a server switch.
    static func normalizedStoredChatResumeIdentity(_ stored: String) -> String? {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if UUID(uuidString: trimmed) != nil { return trimmed }
        return Self.normalizedChatResumeServerIdentity(stored)
    }

    func refreshActiveChatScrollSessionIdentity(
        isReconciling: Bool? = nil,
        advanceSettledRevision: Bool = false
    ) {
        let current = activeChatScrollSessionIdentity
        let sessionCatalog = sessions + cronSessions
        let identityCatalog = sessionCatalog.map { session in
            ChatScrollSessionCatalogIdentity(
                profile: session.profile ?? activeProfile,
                canonicalSessionID: session.id,
                alternateSessionIDs: Set(session.alternateIds)
            )
        }
        let updated = ChatScrollSessionIdentityResolver.resolve(
            profile: activeProfile,
            activeSessionID: activeSessionId,
            catalog: identityCatalog,
            requestedSessionID: reconciliation?.requestedSessionId,
            resolvedSessionID: reconciliation?.resolvedSessionId,
            resolvedDurableSessionID: reconciliation?.resolvedDurableSessionId,
            previousIdentity: current,
            isReconciling: isReconciling ?? current.isReconciling,
            advanceSettledRevision: advanceSettledRevision
        )
        if updated != current {
            migrateChatResumePersistenceIfNeeded(
                from: current,
                to: updated,
                catalog: sessionCatalog
            )
            activeChatScrollSessionIdentity = updated
        }
    }

    private func migrateChatResumePersistenceIfNeeded(
        from current: ChatScrollSessionIdentity,
        to updated: ChatScrollSessionIdentity,
        catalog: [SessionSummary]
    ) {
        guard let canonicalKey = updated.canonicalSessionKey else { return }

        // Catalog-confirmed path: the new canonical is a catalog row, so the
        // row's id set positively establishes the previous runtime-keyed
        // persistence to migrate.
        if let canonicalSession = catalog.first(where: { session in
            let profile = session.profile ?? canonicalKey.profile
            return ChatScrollSessionKey(
                profile: profile,
                sessionID: session.id
            ) == canonicalKey
        }) {
            let equivalentSessionIDs = Set(
                ([canonicalSession.id] + canonicalSession.alternateIds).compactMap { sessionID in
                    let key = ChatScrollSessionKey(
                        profile: canonicalKey.profile,
                        sessionID: sessionID
                    )
                    return key.isValid ? key.sessionID : nil
                }
            )

            let persistedKey = chatResumeCoordinator
                .lastSessionID(for: canonicalKey.profile)
                .map { ChatScrollSessionKey(profile: canonicalKey.profile, sessionID: $0) }
            let activeKey = activeSessionId.map {
                ChatScrollSessionKey(profile: canonicalKey.profile, sessionID: $0)
            }
            let candidates = [persistedKey, current.canonicalSessionKey, activeKey]
                .compactMap { $0 }
            guard let runtimeKey = candidates.first(where: {
                $0 != canonicalKey
                    && $0.profile == canonicalKey.profile
                    && equivalentSessionIDs.contains($0.sessionID)
            }) else { return }

            chatResumeCoordinator.migrateSessionIdentity(from: runtimeKey, to: canonicalKey)
            return
        }

        // Admission-confirmed path: the canonical just moved to a durable id
        // that the resume response POSITIVELY admitted (establishment for a
        // runtime-only conversation) and that has no catalog row yet. The
        // reconciliation's accepted set is positive evidence of which
        // previous conversation keys belong to this same conversation, so the
        // runtime-keyed snapshot and resume-store entry can migrate without
        // catalog confirmation. Conversation-scoped: only the previous
        // canonical key of THIS conversation migrates; profile-scoped: the
        // coordinator migration requires a same-profile key pair.
        guard let admittedDurable = reconciliation?.resolvedDurableSessionId,
              canonicalKey.sessionID == admittedDurable,
              let previousKey = current.canonicalSessionKey,
              previousKey != canonicalKey,
              previousKey.profile == canonicalKey.profile,
              reconciliation?.acceptedSessionIDs.contains(previousKey.sessionID) == true else {
            return
        }
        chatResumeCoordinator.migrateSessionIdentity(from: previousKey, to: canonicalKey)
    }

    func makeSettingsSnapshot() -> SettingsSnapshot {
        SettingsSnapshot(
            server: connection?.baseUrl,
            isConnected: isConnected,
            profile: activeProfile,
            defaultProfileName: defaultProfileName,
            profileDisplayName: profileDisplayName(activeProfile),
            theme: themePreference,
            busyInputMode: busyInputMode,
            chatResumeBehavior: chatResumeBehavior,
            chatReturnSurface: chatReturnSurface,
            displayPreferences: displayPreferences,
            cloudflareAccess: dashboardScopedCloudflareAccess(for: connection?.baseUrl)
        )
    }

    func saveCloudflareAccess(clientID: String, clientSecret: String) {
        if let baseURL = connection?.baseUrl,
           let access = CloudflareAccessCredentials.from(clientID: clientID, clientSecret: clientSecret) {
            let normalized = (try? ConnectionURLPolicy.normalizedBaseURL(baseURL)) ?? baseURL
            if let dashboardID = resolveDashboardID(forNormalizedURL: normalized, registerIfMissing: true) {
                KeychainHelper.saveCloudflareAccess(access, origin: normalized, dashboardID: dashboardID)
            }
        } else if let dashboardID = activeDashboardID {
            KeychainHelper.clearCloudflareAccess(dashboardID: dashboardID)
        }
        if let baseURL = connection?.baseUrl { prepareDashboardBridge(for: baseURL) }
    }

    func customHeaders() -> [CustomHeader] {
        guard let baseURL = connection?.baseUrl else { return [] }
        return CustomHeaderStore.shared.headers(forServerURL: baseURL)
    }

    /// Saves the connected server's extra proxy headers and rebuilds the
    /// dashboard bridge so its page script carries the new set.
    func saveCustomHeaders(_ headers: [CustomHeader]) {
        guard let baseURL = connection?.baseUrl else { return }
        CustomHeaderStore.shared.setHeaders(headers, forServerURL: baseURL)
        prepareDashboardBridge(for: baseURL)
    }

    func removeCloudflareAccess() {
        if let dashboardID = activeDashboardID {
            KeychainHelper.clearCloudflareAccess(dashboardID: dashboardID)
        }
        if let baseURL = connection?.baseUrl { prepareDashboardBridge(for: baseURL) }
    }

    /// Names the roster's main bot by its Conduit name, so Bots, rooms, the
    /// widget and Artifacts call it what the rest of Conduit does (Eric
    /// 2026-10-28). Guarded, so a roster already stamped isn't written again.
    func stampMainBotConduitName() {
        guard let index = botRoster.firstIndex(where: { BotManagement.isDefaultProfile($0.name) }) else { return }
        let name = profileDisplayName("default")
        guard botRoster[index].conduitName != name else { return }
        botRoster[index].conduitName = name
        // An open main Bot Chat follows a name that changed elsewhere (Desktop's title).
        if let open = activeBotChatProfile, BotManagement.isDefaultProfile(open), activeSessionTitle != name {
            activeSessionTitle = name
        }
    }

    /// Gateway profile IDs remain stable; this is only the label used for
    /// presentation in the chat and profile picker: the profile's bot title,
    /// else its Hermes `display_name`, else its id. The main profile goes by
    /// its Conduit name, and by those only while it has none (#1257). A name
    /// given on the device (a gateway without bot looks) comes first until
    /// the roster says the gateway keeps bot looks.
    func profileDisplayName(_ profile: String) -> String {
        var normalized = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let isMain = normalized.isEmpty || normalized.lowercased() == "default"
        if isMain {
            guard defaultProfileName == ProfileAppearanceStore.defaultName else { return defaultProfileName }
            normalized = "default"
        }
        // Until the roster says the gateway keeps bot looks, launch and
        // offline included, as the device's photos do.
        if !isMain, botModePhase != .available, let name = profileDeviceNames[normalized] { return name }
        if let title = profileBotTitles[normalized] { return title }
        if let name = profileHermesNames[normalized] { return name }
        if isMain { return defaultProfileName }
        return String(normalized.prefix(1)).uppercased() + String(normalized.dropFirst())
    }

    /// Takes the bot titles the roster gave. The roster lists every
    /// profile, so it replaces what was known: a title another server's
    /// roster gave never names this one's profile.
    func adoptProfileBotTitles(_ rows: [(profile: String, title: String)]) {
        var titles: [String: String] = [:]
        for row in rows {
            let profile = row.profile.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !profile.isEmpty else { continue }
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            titles[profile] = title.isEmpty || title == profile ? nil : title
        }
        // A roster that answers means the gateway keeps bot looks, so names
        // kept on the device while it had none are dropped: they can't come
        // back over Hermes' names while loading or offline.
        if !profileDeviceNames.isEmpty {
            for profile in profileDeviceNames.keys {
                profileAppearanceStore.saveDeviceName(nil, for: profile, dashboardID: activeDashboardID)
            }
            profileDeviceNames = profileAppearanceStore.loadDeviceNames(dashboardID: activeDashboardID)
        }
        guard titles != profileBotTitles else { return }
        profileBotTitles = titles
        profileAppearanceStore.saveBotTitles(titles, dashboardID: activeDashboardID)
    }

    /// Takes the `display_name`s a listing gave. The bot roster and
    /// `/api/profiles` may not list the same profiles, so a profile either
    /// leaves out keeps what the other said; one listed without a name
    /// reads as its id again.
    func adoptProfileHermesNames(_ rows: [(profile: String, displayName: String)]) {
        var names = profileHermesNames
        for row in rows {
            let profile = row.profile.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !profile.isEmpty else { continue }
            let name = row.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            names[profile] = name.isEmpty || name == profile ? nil : name
        }
        guard names != profileHermesNames else { return }
        profileHermesNames = names
        profileAppearanceStore.saveHermesNames(names, dashboardID: activeDashboardID)
    }

    func profileAvatarURL(for profile: String) -> URL? {
        profileAvatarURLs[profile]
    }

    /// Each profile's backdrop glow color from its pick or its photo
    /// (`ProfileGlowAssignment`). The backdrop asks on every redraw, so the
    /// photos are only read again when the profiles, their photos or the
    /// picks change.
    func profileGlowColors() -> [String: ProfileGlowRGB] {
        var order = profiles
        if !order.contains(activeProfile) { order.append(activeProfile) }
        let key = ProfileGlowCacheKey(order: order, avatarRevision: profileAvatarRevision, picks: profileGlowPicks)
        if let profileGlowCache, profileGlowCache.key == key { return profileGlowCache.colors }
        if profileGlowPalettes.avatarRevision != profileAvatarRevision {
            profileGlowPalettes = (profileAvatarRevision, [:])
        }
        var palettes: [String: [ProfileGlowRGB]] = [:]
        var unreadable = false
        for profile in order {
            guard let url = profileAvatarURLs[profile] else { continue }
            if let known = profileGlowPalettes.byURL[url] {
                palettes[profile] = known
                continue
            }
            guard let image = ProfileAvatarImageCache.image(at: url)?.cgImage else {
                unreadable = true
                continue
            }
            let colors = ProfileGlowPalette.colors(from: image)
            profileGlowPalettes.byURL[url] = colors
            palettes[profile] = colors
        }
        let picked = profileGlowPicks.compactMapValues(ProfileGlowRGB.init(hex:))
        let colors = ProfileGlowAssignment.assign(order: order, palettes: palettes, picked: picked)
        // A photo that could not be read yet is tried again on a later redraw.
        if !unreadable { profileGlowCache = (key, colors) }
        return colors
    }

    /// The glow color picked in the profile picker; nil goes back to the
    /// color drawn from the profile's photo.
    func setProfileGlowColor(_ color: ProfileGlowRGB?, for profile: String) {
        let hex = color?.hex
        guard profileGlowPicks[profile] != hex else { return }
        profileAppearanceStore.saveGlowColor(hex, for: profile, dashboardID: activeDashboardID)
        profileGlowPicks[profile] = hex
        // Rooms over Links draw the bot in it on other people's Conduits too.
        Task { await shareRoomLooksIfNeeded() }
    }

    func saveDefaultProfileName(_ name: String) {
        defaultProfileName = profileAppearanceStore.saveDefaultName(name, dashboardID: activeDashboardID)
        // The main bot's open Bot Chats go by it too (#1457); a name cleared
        // hands them back to the roster's label.
        renameCapturedBotChatLabels(for: "default", to: defaultProfileName == ProfileAppearanceStore.defaultName ? "" : defaultProfileName)
        publishWidgetSnapshot()
        // A call ringing on the Watch shows it.
        shareWatchCallVoices()
    }

    /// The Profiles sheet's Rename. The main profile keeps its Conduit
    /// name, as Settings > Edit profile does; any other profile's bot title
    /// is written as Edit Bot writes it, so Bots, Desktop and every name in
    /// Conduit follow. A gateway without bot looks keeps it on the device,
    /// like its photos. An empty name goes back to Hermes' name, and the
    /// name already shown writes nothing, so a Save with no edit never pins
    /// a display name as a title. Returns a message when it was not saved.
    func renameProfile(_ profile: String, to name: String) async -> String? {
        guard name.trimmingCharacters(in: .whitespacesAndNewlines) != profileDisplayName(profile) else { return nil }
        if BotManagement.isDefaultProfile(profile) {
            saveDefaultProfileName(name)
            return nil
        }
        switch await profilePhotoHome(for: profile) {
        case .device:
            // Also returned for a profile a bot-capable roster doesn't list:
            // its name has nowhere to go.
            guard botModePhase == .gatewayUnsupported else {
                return AppLocalization.string("The name was not saved.")
            }
            profileAppearanceStore.saveDeviceName(name, for: profile, dashboardID: activeDashboardID)
            profileDeviceNames = profileAppearanceStore.loadDeviceNames(dashboardID: activeDashboardID)
            publishWidgetSnapshot()
            return nil
        case .offline:
            return AppLocalization.string("Connect to Hermes to rename this profile.")
        case .hermes(let bot, let client):
            // In the photo writes' queue: they write the same ui_meta, and
            // one landing mid-rename would spend the rename's retry.
            return await queueProfilePhotoWrite(bot.name) {
                await self.writeProfileTitle(name, for: bot, client: client)
            }
        }
    }

    private func writeProfileTitle(_ name: String, for bot: BotProfile, client: HermesClient) async -> String? {
        let epoch = botRosterEpoch
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let patch: [String: Any?] = ["title": title.isEmpty ? nil : title]
        // The photo write ahead in the queue may have moved the revision on.
        let current = botRoster.first(where: { $0.name == bot.name }) ?? bot
        var outcome: BotMetaWriteOutcome
        do {
            let result = try await client.configureBotProfile(
                name: current.name,
                botMeta: BotMetaPatch.merged(existing: current.botMeta, patch: patch),
                expectedMetaRevision: current.botMetaRevision
            )
            outcome = BotMetaWriteOutcome(configureResult: result)
            if outcome == .conflict {
                outcome = await retryBotMetaWrite(current.name, patch: patch, client: client, epoch: epoch)
            }
        } catch {
            outcome = .failed
        }
        guard outcome == .persisted || outcome == .unsupported else {
            await refreshBotRosterAfterWrite()
            return AppLocalization.string("The name was not saved.")
        }
        if botOpenFenceIsCurrent(epoch: epoch, client: client) {
            // Shown at once, whether or not the roster refresh below answers.
            var titles = profileBotTitles
            titles[current.name] = title.isEmpty || title == current.name ? nil : title
            if titles != profileBotTitles {
                profileBotTitles = titles
                profileAppearanceStore.saveBotTitles(titles, dashboardID: activeDashboardID)
            }
            // A name kept on the device while the gateway had no bot looks
            // is replaced by the title.
            if profileDeviceNames[current.name] != nil {
                profileAppearanceStore.saveDeviceName(nil, for: current.name, dashboardID: activeDashboardID)
                profileDeviceNames = profileAppearanceStore.loadDeviceNames(dashboardID: activeDashboardID)
            }
            renameCapturedBotChatLabels(for: current.name, to: title)
            publishWidgetSnapshot()
        }
        await refreshBotRosterAfterWrite()
        return nil
    }

    var mainProfileNamesByDashboard: [String: String] {
        profileAppearanceStore.defaultNamesByDashboard()
    }

    func selectAppIcon(_ choice: AppIconChoice) async -> Bool {
        guard choice != appIconChoice else { return true }
        guard UIApplication.shared.supportsAlternateIcons else {
            errorMessage = AppLocalization.string("This build does not include alternate app icons.")
            return false
        }

        return await withCheckedContinuation { continuation in
            UIApplication.shared.setAlternateIconName(choice.alternateIconName) { [weak self] error in
                Task { @MainActor in
                    if let error {
                        self?.errorMessage = AppLocalization.string("Could not change the app icon: \(UserFacingError.message(for: error))")
                        continuation.resume(returning: false)
                    } else {
                        self?.appIconChoice = choice
                        continuation.resume(returning: true)
                    }
                }
            }
        }
    }

    /// A photo kept on this device only: the gateway has no profile asset
    /// store (older Hermes).
    func saveProfileAvatarOnDevice(_ data: Data, for profile: String) throws {
        profileAvatarURLs[profile] = try profileAppearanceStore.saveAvatar(data, for: profile, dashboardID: activeDashboardID)
    }

    func removeProfileAvatarFile(for profile: String) {
        profileAppearanceStore.removeAvatar(for: profile, dashboardID: activeDashboardID)
        profileAvatarURLs.removeValue(forKey: profile)
    }

    /// False only on a gateway without the profile asset store, where
    /// photos stay on this device.
    var profilePhotosLiveOnHermes: Bool {
        botModePhase != .gatewayUnsupported
    }

    /// The profile picker's photo. It is the profile's Hermes picture, the
    /// one bots and Hermes Desktop show, so it is written there; the copy on
    /// disk follows. `animation` is a moving picture made by AnimatedAvatar,
    /// stored as it is. Nil `image` and `animation` remove it. Returns a
    /// message when it was not saved.
    func setProfilePhoto(_ image: UIImage?, animation: Data? = nil, for profile: String) async -> String? {
        switch await profilePhotoHome(for: profile) {
        case .device:
            if animation == nil, image == nil {
                removeProfileAvatarFile(for: profile)
                return nil
            }
            guard let data = animation ?? image?.pngData() else { return ProfileAppearanceError.invalidImage.errorDescription }
            do {
                try saveProfileAvatarOnDevice(data, for: profile)
                return nil
            } catch {
                return UserFacingError.message(for: error)
            }
        case .offline:
            return AppLocalization.string("Connect to Hermes to change this photo.")
        case .hermes(let bot, let client):
            if let animation {
                return await queueProfilePhotoWrite(bot.name) {
                    await self.setHermesPicture(animation, for: bot, client: client)
                }
            }
            if let image {
                guard let png = BotAvatarImage.normalizedPNG(from: image) else {
                    return AppLocalization.string("That picture could not be used.")
                }
                return await queueProfilePhotoWrite(bot.name) {
                    await self.setHermesPicture(png, for: bot, client: client)
                }
            }
            return await queueProfilePhotoWrite(bot.name) {
                await self.removeHermesPicture(for: bot, client: client)
            }
        }
    }

    func queueProfilePhotoWrite(
        _ name: String,
        _ write: @escaping @MainActor () async -> String?
    ) async -> String? {
        let previous = profilePhotoWriteQueue[name]
        let task = Task { @MainActor in
            _ = await previous?.value
            return await write()
        }
        profilePhotoWriteQueue[name] = task
        let result = await task.value
        if profilePhotoWriteQueue[name] == task { profilePhotoWriteQueue[name] = nil }
        return result
    }

    private enum ProfilePhotoHome {
        case hermes(BotProfile, HermesClient)
        case device
        case offline
    }

    /// Every profile is on the `profiles.list` roster, so a roster row is
    /// what says the picture lives on Hermes.
    private func profilePhotoHome(for profile: String) async -> ProfilePhotoHome {
        if botModePhase == .gatewayUnsupported { return .device }
        guard let client, isConnected else { return .offline }
        if !botRoster.contains(where: { $0.name == profile }) {
            await refreshBotRoster()
        }
        guard client === self.client, isConnected else { return .offline }
        if botModePhase == .gatewayUnsupported { return .device }
        guard let bot = botRoster.first(where: { $0.name == profile }) else {
            return botModePhase == .available ? .device : .offline
        }
        return .hermes(bot, client)
    }

    /// Uploads the picture, then sets Desktop's `imageKind` to the photo
    /// (the bot editor's order, so `imageKind` never claims a photo the
    /// asset store lacks).
    func setHermesPicture(_ png: Data, for bot: BotProfile, client: HermesClient) async -> String? {
        let epoch = botRosterEpoch
        guard await storeBotAvatar(png, for: bot.name, client: client, epoch: epoch) else {
            return AppLocalization.string("The picture was not saved.")
        }
        let lookSaved = await writeBotImageKind("photo", for: bot, client: client, epoch: epoch)
        await refreshBotRosterAfterWrite()
        return lookSaved ? nil : AppLocalization.string("The picture was saved, but its look was not.")
    }

    /// Sets `imageKind` back to the shape first, then clears the asset.
    private func removeHermesPicture(for bot: BotProfile, client: HermesClient) async -> String? {
        let epoch = botRosterEpoch
        noteProfileAvatarWrite(bot.name)
        guard await writeBotImageKind("shape", for: bot, client: client, epoch: epoch) else {
            return AppLocalization.string("The picture was not removed.")
        }
        do {
            try await client.setBotAvatar(name: bot.name, png: nil)
        } catch {
            return AppLocalization.string("The picture was not removed.")
        }
        if botOpenFenceIsCurrent(epoch: epoch, client: client) {
            forgetHermesPicture(for: bot.name)
        }
        await refreshBotRosterAfterWrite()
        return nil
    }

    private func writeBotImageKind(_ kind: String, for bot: BotProfile, client: HermesClient, epoch: Int) async -> Bool {
        var patch: [String: Any?] = ["imageKind": kind]
        if kind == "photo" { patch["custom"] = true }
        do {
            let result = try await client.configureBotProfile(
                name: bot.name,
                botMeta: BotMetaPatch.merged(existing: bot.botMeta, patch: patch),
                expectedMetaRevision: bot.botMetaRevision
            )
            var outcome = BotMetaWriteOutcome(configureResult: result)
            if outcome == .conflict {
                outcome = await retryBotMetaWrite(bot.name, patch: patch, client: client, epoch: epoch)
            }
            return outcome == .persisted || outcome == .unsupported
        } catch {
            return false
        }
    }

    /// Profile order is only a device-local presentation preference, kept
    /// per dashboard.
    func moveProfile(from index: Int, to destination: Int) {
        guard profiles.indices.contains(index), profiles.indices.contains(destination), index != destination else { return }
        profiles.swapAt(index, destination)
        var orders = defaults.dictionary(forKey: profileOrderByDashboardKey) as? [String: [String]] ?? [:]
        orders[Self.dashboardPreferenceBucket(activeDashboardID)] = profiles
        defaults.set(orders, forKey: profileOrderByDashboardKey)
    }
}
