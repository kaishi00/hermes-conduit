//
//  HermesFocusFilter.swift
//  Conduit
//
//  A Focus filter: in Settings > Focus > (a Focus) > Focus Filters, the user
//  adds Conduit and says what Hermes should know while that Focus is on (a
//  name such as "Work") and whether Hermes should hold its calls. iOS runs
//  this as the Focus turns on, and again with the default values as it turns
//  off. Conduit keeps the latest state and, when the user shares Focus with
//  Hermes, sends it with the next upload. iOS's own Focus status API only
//  says "focused or not" and needs a communication-app entitlement, so a
//  filter is both more useful and asks for nothing.
//

import AppIntents
import Foundation

@available(iOS 16.0, *)
struct HermesFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Tell Hermes"
    static let description: IntentDescription? = IntentDescription(
        "Let your Hermes agent know which Focus you're in, and hold its calls while it's on.")

    @Parameter(title: "Name for Hermes", default: "")
    var label: String

    @Parameter(title: "Hold calls from Hermes", default: false)
    var holdCalls: Bool

    var displayRepresentation: DisplayRepresentation {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let held: LocalizedStringResource = "Hold Hermes calls"
        if name.isEmpty {
            let title: LocalizedStringResource = holdCalls ? held : "Tell Hermes"
            return DisplayRepresentation(title: title)
        }
        let subtitle: LocalizedStringResource? = holdCalls ? held : nil
        return DisplayRepresentation(title: "\(name)", subtitle: subtitle)
    }

    func perform() async throws -> some IntentResult {
        let name = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        // Turning off runs this with the defaults: nothing named, nothing held.
        let snapshot = PhoneFocusSnapshot(active: !name.isEmpty || holdCalls, label: name.isEmpty ? nil : name,
                                          holdCalls: holdCalls, at: Date())
        snapshot.save()
        await Self.share()
        return .result()
    }

    /// Sends the new state now when the user shares Focus with Hermes.
    @MainActor
    private static func share() async {
        let app = AppStateRuntimeRegistry.shared.appState
        guard app.phoneSync.preferences.isOn, app.phoneSync.preferences.focus else { return }
        await app.runPhoneSync(reason: .focusChanged)
    }
}
