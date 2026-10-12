import SwiftUI
import WidgetKit

private enum LauncherWidgetStyle: Equatable {
    case native
    case character
}

struct NativeLauncherWidget: Widget {
    let kind = "com.milim.relay.widgets.native"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: LauncherWidgetConfigurationIntent.self, provider: LauncherTimelineProvider()) { entry in
            LauncherWidgetView(entry: entry, style: .native)
        }
        .configurationDisplayName("Native")
        .description("Open your workspace, start a new chat, or talk with Conduit.")
        .supportedFamilies([.systemMedium])
    }
}

struct CharacterLauncherWidget: Widget {
    let kind = "com.milim.relay.widgets.character"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: LauncherWidgetConfigurationIntent.self, provider: LauncherTimelineProvider()) { entry in
            LauncherWidgetView(entry: entry, style: .character)
        }
        .configurationDisplayName("Conduit-chan")
        .description("Open your workspace, start a new chat, or talk with Conduit-chan.")
        .supportedFamilies([.systemMedium])
    }
}

@main
struct ConduitWidgets: WidgetBundle {
    var body: some Widget {
        NativeLauncherWidget()
        CharacterLauncherWidget()
    }
}

private struct LauncherWidgetView: View {
    let entry: LauncherWidgetEntry
    let style: LauncherWidgetStyle

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if style == .native {
                nativeHeading
            } else {
                characterHeading
            }
            Spacer(minLength: 0)
            actionLinks
        }
        .padding(.vertical, 2)
        .containerBackground(.background, for: .widget)
    }

    private var nativeHeading: some View {
        HStack(alignment: .top, spacing: 12) {
            nativeMark
            VStack(alignment: .leading, spacing: 3) {
                workspaceLabel
                titleLink
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var nativeMark: some View {
        if #available(iOS 18.0, *), renderingMode == .accented {
            Image("WidgetMark")
                .resizable()
                .widgetAccentedRenderingMode(.accentedDesaturated)
                .scaledToFit()
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)
        } else {
            Image("WidgetMark")
                .resizable()
                .scaledToFit()
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)
        }
    }

    private var characterHeading: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                workspaceLabel
                titleLink
            }
            Spacer(minLength: 0)
            characterArtwork
        }
    }

    private var workspaceLabel: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !entry.model.dashboardLabel.isEmpty {
                Text(entry.model.dashboardLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            if !entry.model.profileLabel.isEmpty {
                Text(entry.model.profileLabel)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var titleLink: some View {
        let title = WidgetLocalization.title(entry.model.titleCopy, language: entry.appLanguage)
        Link(destination: entry.model.resumeLink.url) {
            Text(verbatim: title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.leading)
                .privacySensitive()
        }
        .accessibilityLabel(Text(verbatim: title))
    }

    @ViewBuilder
    private var characterArtwork: some View {
        if #available(iOS 18.0, *), renderingMode == .accented {
            Image("WidgetCharacter")
                .resizable()
                .widgetAccentedRenderingMode(.accentedDesaturated)
                .scaledToFit()
                .frame(width: 84, height: 94)
                .accessibilityHidden(true)
        } else {
            Image("WidgetCharacter")
            .resizable()
            .scaledToFit()
            .frame(width: 84, height: 94)
            .accessibilityHidden(true)
        }
    }

    private var actionLinks: some View {
        HStack(spacing: 10) {
            if let link = entry.model.newChatLink {
                actionLink(link, title: WidgetLocalization.string("New Chat", language: entry.appLanguage), systemImage: "plus.bubble")
            }
            Spacer(minLength: 0)
            if let link = entry.model.talkLink {
                actionLink(link, title: WidgetLocalization.string("Talk", language: entry.appLanguage), systemImage: "waveform")
            }
        }
    }

    private func actionLink(_ link: WidgetLaunchLink, title: String, systemImage: String) -> some View {
        Link(destination: link.url) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .foregroundStyle(.tint)
                .background(.quaternary, in: Capsule())
        }
        .accessibilityLabel(Text(verbatim: title))
    }
}
