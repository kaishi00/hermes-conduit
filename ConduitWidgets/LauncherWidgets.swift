import SwiftUI
import WidgetKit

private enum LauncherWidgetStyle: Equatable {
    case native
    case character
}

struct NativeLauncherWidget: Widget {
    let kind = ConduitWidgetKind.native

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: LauncherWidgetConfigurationIntent.self, provider: LauncherTimelineProvider()) { entry in
            LauncherWidgetView(entry: entry, style: .native)
        }
        .configurationDisplayName("Native")
        .description("Open your workspace, start a new chat, or talk with Conduit.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct CharacterLauncherWidget: Widget {
    let kind = ConduitWidgetKind.character

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: LauncherWidgetConfigurationIntent.self, provider: LauncherTimelineProvider()) { entry in
            LauncherWidgetView(entry: entry, style: .character)
        }
        .configurationDisplayName("Conduit-chan")
        .description("Open your workspace, start a new chat, or talk with Conduit-chan.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct ConduitWidgets: WidgetBundle {
    var body: some Widget {
        NativeLauncherWidget()
        CharacterLauncherWidget()
        PulseWidget()
        HermesTurnLiveActivity()
    }
}

private struct LauncherWidgetView: View {
    let entry: LauncherWidgetEntry
    let style: LauncherWidgetStyle

    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Group {
            switch family {
            case .systemSmall: smallBody
            case .systemLarge: largeBody
            default: mediumBody
            }
        }
        .containerBackground(.background, for: .widget)
    }

    // MARK: Sizes

    private var mediumBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading
            Spacer(minLength: 0)
            actionLinks
        }
        .padding(.vertical, 2)
    }

    /// The medium layout with the workspace's other saved chats under it.
    private var largeBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading
            actionLinks
            if !entry.model.moreChats.isEmpty {
                Divider()
                moreChatsList
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// One tap target (WidgetKit takes no links in the small size), opening
    /// what the widget's Small size opens picks.
    private var smallBody: some View {
        let action = entry.model.smallAction(entry.smallAction)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 0) {
                if style == .native {
                    nativeMark(size: 32)
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    characterArtwork(width: 54, height: 60)
                }
            }
            Spacer(minLength: 0)
            workspaceLabel
            smallTitle(action)
        }
        .widgetURL(entry.model.smallLink(entry.smallAction).url)
    }

    // MARK: Parts

    @ViewBuilder
    private var heading: some View {
        if style == .native {
            HStack(alignment: .top, spacing: 12) {
                nativeMark(size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    workspaceLabel
                    titleLink
                }
                Spacer(minLength: 0)
            }
        } else {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    workspaceLabel
                    titleLink
                }
                Spacer(minLength: 0)
                characterArtwork(width: 84, height: 94)
            }
        }
    }

    @ViewBuilder
    private func nativeMark(size: CGFloat) -> some View {
        if #available(iOS 18.0, *), renderingMode == .accented {
            Image("WidgetMark")
                .resizable()
                .widgetAccentedRenderingMode(.accentedDesaturated)
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image("WidgetMark")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func characterArtwork(width: CGFloat, height: CGFloat) -> some View {
        if #available(iOS 18.0, *), renderingMode == .accented {
            Image("WidgetCharacter")
                .resizable()
                .widgetAccentedRenderingMode(.accentedDesaturated)
                .scaledToFit()
                .frame(width: width, height: height)
                .accessibilityHidden(true)
        } else {
            Image("WidgetCharacter")
                .resizable()
                .scaledToFit()
                .frame(width: width, height: height)
                .accessibilityHidden(true)
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
        .privacySensitive()
    }

    private var title: String {
        WidgetLocalization.title(entry.model.titleCopy, language: entry.appLanguage)
    }

    @ViewBuilder
    private var titleLink: some View {
        let title = self.title
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
    private func smallTitle(_ action: LauncherSmallAction) -> some View {
        switch action {
        case .conversation:
            Text(verbatim: title)
                .font(.headline)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.leading)
                .privacySensitive()
        case .newChat:
            smallActionLabel(WidgetLocalization.string("New Chat", language: entry.appLanguage), systemImage: "plus.bubble")
        case .talk:
            smallActionLabel(WidgetLocalization.string("Talk", language: entry.appLanguage), systemImage: "waveform")
        }
    }

    private func smallActionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(.tint)
    }

    private var moreChatsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: WidgetLocalization.string("Chats", language: entry.appLanguage))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(entry.model.moreChats, id: \.link.url) { chat in
                Link(destination: chat.link.url) {
                    HStack(spacing: 8) {
                        Image(systemName: chat.isPinned ? "pin.fill" : "bubble.left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(verbatim: chat.title)
                            .font(.subheadline)
                            .lineLimit(1)
                            .privacySensitive()
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                }
                .accessibilityLabel(Text(verbatim: chat.title))
            }
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
