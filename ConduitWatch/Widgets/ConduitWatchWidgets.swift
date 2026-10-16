//
//  ConduitWatchWidgets.swift
//  Conduit Watch Widgets
//
//  Ways to start a Watch call with one press: a watch face complication
//  and a control for the Action button on Apple Watch Ultra, Control
//  Center and the Smart Stack. Both open Conduit straight into a call,
//  whatever Call on open says.
//

import AppIntents
import SwiftUI
import WidgetKit

@main
struct ConduitWatchWidgets: WidgetBundle {
    var body: some Widget {
        TalkToHermesComplication()
        TalkToHermesControl()
    }
}

/// Watch face complication: a tap opens Conduit into a call.
struct TalkToHermesComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.milim.relay.watch.talk", provider: TalkToHermesProvider()) { _ in
            TalkToHermesComplicationView()
                .widgetURL(WatchCallURL.talk)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Talk to Hermes")
        .description("Starts a voice call to Hermes on your Watch.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct TalkToHermesEntry: TimelineEntry {
    let date: Date
}

/// Nothing on it changes: one entry, never reloaded.
struct TalkToHermesProvider: TimelineProvider {
    func placeholder(in context: Context) -> TalkToHermesEntry { TalkToHermesEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (TalkToHermesEntry) -> Void) {
        completion(TalkToHermesEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TalkToHermesEntry>) -> Void) {
        completion(Timeline(entries: [TalkToHermesEntry(date: .now)], policy: .never))
    }
}

struct TalkToHermesComplicationView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCorner:
            Image(systemName: "waveform")
                .font(.title2.weight(.semibold))
                .widgetLabel { Text("Talk to Hermes") }
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.title3.weight(.semibold))
                VStack(alignment: .leading, spacing: 0) {
                    Text("Conduit")
                        .font(.headline)
                    Text("Talk to Hermes")
                        .font(.caption)
                }
                Spacer(minLength: 0)
            }
        case .accessoryInline:
            Label("Talk to Hermes", systemImage: "waveform")
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "waveform")
                    .font(.title3.weight(.semibold))
            }
        }
    }
}

/// Control for the Action button, Control Center and the Smart Stack.
struct TalkToHermesControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.milim.relay.watch.talk.control") {
            ControlWidgetButton(action: TalkToHermesIntent()) {
                Label("Talk to Hermes", systemImage: "waveform")
            }
        }
        .displayName("Talk to Hermes")
        .description("Starts a voice call to Hermes on your Watch.")
    }
}
