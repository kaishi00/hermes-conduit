//
//  AppState+UsageWidget.swift
//  Conduit
//
//  The Plan limits widget (issue 2796). The widget reads Hermes' plan
//  limits itself (`/api/model/options?explicit_only=true`, the REST twin of the call
//  Settings > Usage makes), with a host pass Conduit keeps for it while one
//  is on the Home Screen (UsageWidgetAccess), so its numbers stay current
//  without Conduit running. The pass names the profile in use, since each
//  profile signs in to its own providers.
//

import Foundation
import WidgetKit

extension AppState {
    func reloadUsageWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: ConduitWidgetKind.usage)
    }

    /// Keeps what the widget reads with current: the dashboard and profile
    /// in use and a host pass for the dashboard. Only while a Plan limits
    /// widget is on the Home Screen; otherwise the item goes, and so does
    /// what the widget showed. At each connect, each return to the screen,
    /// each profile change and when a native sign-in's token rotates.
    func saveUsageWidgetAccess() async {
        guard let dashboardID = activeDashboardID else { return }
        let profile = activeProfile
        // A sign-out while the pass is made leaves it unsaved.
        let generation = dashboardSwitchGeneration
        // Another dashboard or profile is in use now: the widget stops
        // reading the old one's before this one's pass is ready.
        if let kept = UsageWidgetKeychain.load(), kept.dashboardID != dashboardID || kept.profile != profile {
            removeUsageWidget(dashboardID: kept.dashboardID)
        }
        guard let bridge = dashboardTicketBridge else { return }
        // WidgetKit couldn't list the widgets: what the widget has stays.
        guard let installed = await installedWidgetKinds()?.contains(ConduitWidgetKind.usage) else { return }
        guard installed else {
            removeUsageWidget()
            return
        }
        guard let pass = await dashboardHostPass(bridge: bridge, dashboardID: dashboardID),
              dashboardSwitchGeneration == generation,
              activeDashboardID == dashboardID, activeProfile == profile else { return }
        let access = UsageWidgetAccess(dashboardID: dashboardID, profile: profile, pass: pass)
        let before = UsageWidgetKeychain.load()
        guard UsageWidgetKeychain.save(access) else { return }
        // Another dashboard or profile, or a new sign-in: read again.
        if before?.dashboardID != dashboardID || before?.profile != profile || before?.pass.headers != pass.headers {
            reloadUsageWidget()
        }
    }

    /// No Plan limits widget, or `dashboardID` removed or signed out of: the
    /// widget can't read it any more and shows nothing of it.
    func removeUsageWidget(dashboardID: UUID? = nil) {
        let access = UsageWidgetKeychain.load()
        let kept = UsageWidgetStore.production?.read()
        var changed = false
        if let access, dashboardID == nil || access.dashboardID == dashboardID {
            UsageWidgetKeychain.clear()
            changed = true
        }
        if let kept, dashboardID == nil || kept.dashboardID == dashboardID, UsageWidgetStore.production?.remove() == true {
            changed = true
        }
        if changed { reloadUsageWidget() }
    }

    /// The kinds of Conduit's widgets on the Home Screen; nil when WidgetKit
    /// couldn't say.
    func installedWidgetKinds() async -> Set<String>? {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                continuation.resume(returning: (try? result.get()).map { Set($0.map(\.kind)) })
            }
        }
    }
}
