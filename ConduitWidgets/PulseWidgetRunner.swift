import Foundation

/// The widget's stand-in for the app's runner (AppState+PulseWidget.swift).
/// The Pulse widget's buttons are LiveActivityIntents, which the system
/// performs in Conduit's own process, so this is never called: the widget
/// holds no credentials and can't reach Hermes.
enum PulseWidgetRunner {
    static func run(_ action: PulseWidgetAction, card: Int, dashboard: String) async {}
}
