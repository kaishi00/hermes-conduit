import AppIntents
import SwiftUI
import WidgetKit

struct LauncherWidgetEntry: TimelineEntry {
    let date: Date
    let model: WidgetEntryModel
    let appLanguage: String
    let hideTitle: Bool

    static func make(configuration: LauncherWidgetConfigurationIntent, snapshot: WidgetSnapshot?) -> Self {
        let workspace = configuration.workspace?.workspaceID
        let conversation = configuration.conversation
        let model = WidgetSelection.resolve(
            snapshot: snapshot,
            workspace: workspace,
            conversation: conversation?.reference,
            conversationWorkspace: conversation?.workspaceID,
            hideTitle: configuration.shouldHideTitle
        )
        return Self(date: Date(), model: model, appLanguage: snapshot?.appLanguage ?? "system", hideTitle: configuration.shouldHideTitle)
    }
}

struct LauncherTimelineProvider: AppIntentTimelineProvider {
    typealias Entry = LauncherWidgetEntry
    typealias Intent = LauncherWidgetConfigurationIntent

    func placeholder(in context: Context) -> Entry {
        Entry.make(configuration: Intent(), snapshot: nil)
    }

    func snapshot(for configuration: Intent, in context: Context) async -> Entry {
        Entry.make(configuration: configuration, snapshot: WidgetSnapshotStore.production?.read())
    }

    func timeline(for configuration: Intent, in context: Context) async -> Timeline<Entry> {
        let entry = Entry.make(configuration: configuration, snapshot: WidgetSnapshotStore.production?.read())
        return Timeline(entries: [entry], policy: .never)
    }
}
