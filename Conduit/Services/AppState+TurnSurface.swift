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
    /// A message typed or spoken in the app, on this device or CarPlay.
    func messageTurnSurface(spoken: Bool) -> TurnSurface {
        TurnSurface.message(spoken: spoken, carPlay: isCarPlayVoiceSurfaceActive)
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
}
