//
//  AppState+TurnSurface.swift
//  Conduit
//
//  Tells the notifier plugin where a message is being sent from, just
//  before it goes (TurnSurface.swift, #888).
//

import Foundation

@MainActor
extension AppState {
    /// A message typed or spoken in the app, on this device or CarPlay. A
    /// typed one's reply is heard too while Read replies aloud reads it,
    /// which needs Conduit on screen when the message is sent.
    func messageTurnSurface(spoken: Bool) -> TurnSurface {
        TurnSurface.message(
            spoken: spoken, carPlay: isCarPlayVoiceSurfaceActive,
            heard: !spoken && ReadRepliesAloud.isOn(appDefaults) && readAloudUnavailableReason == nil
                && messageReadAloudController.isOnScreen
        )
    }

    /// Reports `surface` for the turn of `text` in `runtimeSessionID`. The task
    /// ends once the plugin answered or `TurnSurface.wait` passed, whichever
    /// is first, so awaiting it never holds a send up for long. Nil when the
    /// plugin doesn't take reports. A report that fails is dropped: that
    /// turn just has no line.
    func reportTurnSurface(_ surface: TurnSurface, runtimeSessionID: String, text: String) -> Task<Void, Never>? {
        guard turnSurfaceSender != nil || TurnSurface.isTaken(by: notifierPlugin) else { return nil }
        let send: ([String: Any]) async throws -> Void
        if let turnSurfaceSender {
            send = turnSurfaceSender
        } else {
            guard let bridge = dashboardTicketBridge else { return nil }
            send = { body in
                _ = try await bridge.requestJSON(path: TurnSurface.path, method: "POST", body: body,
                                                 timeoutMilliseconds: TurnSurface.timeoutMilliseconds)
            }
        }
        let body = surface.body(runtimeSessionID: runtimeSessionID, text: text)
        let upload = Task { @MainActor in _ = try? await send(body) }
        return Task { @MainActor in
            await LocationSharingController.waitAtMost(TurnSurface.wait, for: upload)
            // Not needed once the turn may have started.
            upload.cancel()
        }
    }

    /// Forgets the report for `text` in `runtimeSessionID` after its send
    /// failed: no turn of it is coming, so the same words sent from another
    /// client there would take its line. Not after a send whose reply was
    /// only lost (it may have started). Never waited on; one that fails to
    /// go is tried again after `TurnSurface.discardRetryDelays` (notifier
    /// issue 610). A plugin without the route keeps the report until it goes
    /// stale. `dashboardID` is the dashboard active when the report was
    /// made: once another is active, nothing is discarded anywhere, so the
    /// text never reaches a host it wasn't sent to and the new dashboard
    /// holds no hash for it (issue 2222).
    func discardTurnSurface(runtimeSessionID: String, text: String, after error: Error, reportedOn dashboardID: UUID?) {
        guard activeDashboardID == dashboardID else { return }
        guard !Self.isAmbiguousPromptDelivery(error) else { return }
        let body = TurnSurface.discardBody(runtimeSessionID: runtimeSessionID, text: text)
        let send: ([String: Any]) async throws -> Void
        if let turnSurfaceDiscarder {
            send = turnSurfaceDiscarder
        } else {
            guard notifierPlugin.reports(TurnSurface.discardCapability),
                  let bridge = dashboardTicketBridge else { return }
            send = { body in
                _ = try await bridge.requestJSON(path: TurnSurface.discardPath, method: "POST", body: body,
                                                 timeoutMilliseconds: TurnSurface.timeoutMilliseconds)
            }
        }
        let delays = turnSurfaceDiscardRetryDelays ?? TurnSurface.discardRetryDelays
        Task { @MainActor in
            for delay in [Duration.zero] + delays {
                if delay > .zero {
                    do { try await Task.sleep(for: delay) } catch { return }
                }
                do {
                    try await send(body)
                    return
                } catch {
                    guard TurnSurface.discardMayGoLater(error) else { return }
                }
            }
        }
    }
}
