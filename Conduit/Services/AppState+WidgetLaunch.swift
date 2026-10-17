import Foundation

extension AppState {
    /// Widget URLs have their own strict parser. A malformed URL in this
    /// namespace is still consumed so it cannot fall through to permissive
    /// app-link parsing.
    func routeWidgetLaunchURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "conduit",
              components.host?.lowercased() == "widget" else { return false }
        guard let link = WidgetLaunchLink(url: url) else { return true }
        cancelChatResumeRestoration()
        newChatLaunchStartedInApp = false
        widgetLaunchCoordinator.receive(link)
        // A New Chat's chat shows straight away, empty, while it waits for
        // what its launch needs.
        if showsPendingNewChat { revealChatForWidgetLaunch() }
        return true
    }

    func prepareWidgetLaunch(_ link: WidgetLaunchLink, lease: WidgetLaunchLease) async -> WidgetLaunchOutcome {
        guard lease.isCurrent else { return .deferred }
        guard widgetForegroundReady else { return .deferred }
        if link.action == .open, link.workspace == nil { return .handled }
        guard let workspace = link.workspace else { return .failed(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable")) }
        guard savedDashboardRegistry.dashboard(with: workspace.dashboardID) != nil else {
            return .failed(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable"))
        }
        if isVoiceCallInProgress {
            guard link.action == .open,
                  workspace.dashboardID == activeDashboardID,
                  workspace.profile == activeProfile else {
                return .failed(AppLocalization.string("End the call to open a chat in another workspace."))
            }
            return .handled
        }

        if workspace.dashboardID != activeDashboardID {
            await switchDashboard(to: workspace.dashboardID, widgetLease: lease)
            guard lease.isCurrent else { return .deferred }
            guard activeDashboardID == workspace.dashboardID else {
                return showLogin ? .failed(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable")) : .deferred
            }
        } else if !isConnected && !isConnecting {
            await switchDashboard(to: workspace.dashboardID, widgetLease: lease)
            guard lease.isCurrent else { return .deferred }
        }
        guard activeDashboardID == workspace.dashboardID else {
            return .failed(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable"))
        }
        if showLogin, widgetAwaitingInteractiveAuthenticationDashboardID == workspace.dashboardID {
            return .deferred
        }
        guard isConnected else {
            return isConnecting ? .deferred : .failed(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable"))
        }
        guard profiles.contains(where: { $0 == workspace.profile })
                || workspace.profile == "default"
                || workspace.profile == defaultProfileName else {
            return widgetSettledCatalogOwner == nil
                ? .deferred
                : .failed(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable"))
        }
        if activeProfile != workspace.profile {
            let switched = await switchProfileForWidget(to: workspace.profile, lease: lease)
            guard lease.isCurrent else { return .deferred }
            guard switched, activeProfile == workspace.profile else {
                return .failed(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable"))
            }
        }
        guard lease.isCurrent else { return .deferred }
        lease.bindTargetOwnership { [weak self] in
            self?.activeDashboardID == workspace.dashboardID && self?.activeProfile == workspace.profile
        }
        if link.action != .open, widgetSettledCatalogOwner != workspace {
            // The link itself cancels the launch or return-to-app sync that
            // would have read this catalog (routeWidgetLaunchURL), and a
            // cancelled sync drops the rows it fetched. Read it here rather
            // than wait for a load nothing else starts.
            await loadSessionsForWidgetLaunch()
            guard lease.isCurrent else { return .deferred }
            if widgetSettledCatalogOwner != workspace { return .deferred }
        }
        if link.action == .resume, let reference = link.reference, reference.kind == .dashboard {
            guard widgetSettledCatalogOwner == workspace else { return .deferred }
            guard activeProfileSessions.contains(where: { $0.id == reference.sessionID
                || $0.alternateIds.contains(reference.sessionID)
                || $0.storedSessionId == reference.sessionID }) else {
                return .failed(AppLocalization.string("WidgetLaunch.ConversationUnavailable"))
            }
        }
        return .handled
    }

    func performWidgetLaunch(_ link: WidgetLaunchLink, lease: WidgetLaunchLease) async -> WidgetLaunchOutcome {
        guard lease.isCurrent else { return .deferred }
        if link.action == .open { return .handled }
        guard let workspace = link.workspace,
              activeDashboardID == workspace.dashboardID,
              activeProfile == workspace.profile else {
            return .failed(AppLocalization.string("WidgetLaunch.WorkspaceUnavailable"))
        }
        revealChatForWidgetLaunch()
        switch link.action {
        case .open:
            return .handled
        case .newChat:
            let previous = activeSessionId
            await createNewSession(widgetLease: lease)
            guard lease.isCurrent else { return .deferred }
            return activeSessionId != previous
                ? .handled
                : .failed(AppLocalization.string("WidgetLaunch.ConversationUnavailable"))
        case .resume:
            guard let reference = link.reference else {
                return .failed(AppLocalization.string("WidgetLaunch.ConversationUnavailable"))
            }
            return await openWidgetConversation(reference, workspace: workspace, lease: lease)
        case .talk:
            return await openWidgetVoice(workspace: workspace, lease: lease)
        }
    }

    /// The chat a widget opens has to be what's on screen. The Sessions
    /// drawer (left open, or put up as the return surface before the link
    /// arrived) and the chat's own sheets would otherwise cover the new or
    /// resumed chat, and Talk's call screen would open over a list. Voice
    /// and Live sheets stay: one up is a call in progress, which prepare
    /// already refuses for anything but a plain open. This runs before the
    /// outcome is known on purpose: Talk's call screen can't present over
    /// them, and a launch that fails reports it over the chat.
    private func revealChatForWidgetLaunch() {
        dismissSidebarDrawer()
        requestSettingsDismissal()
        showModelPicker = false
        showContextSheet = false
        showWorkspaceSheet = false
        showGatewaySheet = false
        showAgentsSheet = false
        dismissChatCallTranscript()
    }
}
