import SwiftUI

/// A cron job's report in a Bot Chat, shown without a turn (the plugin's
/// cron_bot_chat): the job delivers to the Bot Chat and, unless it lets the
/// bot act on it, the report is written into the chat as a note. Its first
/// line names the job; the rest is the report as the run wrote it.
struct CronBotChatReport: Equatable {
    let job: String
    let report: String

    /// The plugin's first line (cron_bot_chat.HEADER).
    private static let prefix = "[Cron job \""
    private static let suffix = "\" report: shown in the chat, no reply asked for]"

    static func parse(_ text: String) -> CronBotChatReport? {
        guard text.hasPrefix(prefix) else { return nil }
        // A CRLF report reads as the transcript reads it (MarkdownText
        // normalizes line ends too), so a closing fence still closes.
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        let firstLine = text.prefix { $0 != "\n" }
        guard firstLine.hasSuffix(suffix), firstLine.count > prefix.count + suffix.count else { return nil }
        let job = String(firstLine.dropFirst(prefix.count).dropLast(suffix.count))
        let report = text.dropFirst(firstLine.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return CronBotChatReport(job: job, report: report)
    }

    /// The report as the card draws it: a picture or file the run delivered
    /// on a line of its own becomes the `MEDIA:` tag the transcript draws
    /// as that picture or file. The plugin writes it as an `@image:` or
    /// `@file:` reference (notifier 0.161.3, issue 581), which Hermes
    /// Desktop shows on the note's user row; an older plugin left the
    /// run's own `MEDIA:` tag, which reads the same. A list marker before
    /// the reference goes, as the plugin drops it. A reference inside a
    /// sentence or a quote, or in fenced code or a math block (opaque to
    /// the transcript too), stays as written.
    var shown: String {
        guard report.contains("@image:") || report.contains("@file:") else { return report }
        return lines.map(\.text).joined(separator: "\n")
    }

    /// The report for the folded card: each delivered picture or file by
    /// its name, never its path on the host. A tag in fenced code or a
    /// math block stays as written, as it does in `shown`.
    var preview: String {
        lines.map { line in
            guard let path = line.media else { return line.text }
            return GatewayMediaTags.fileName(of: path)
        }.joined(separator: "\n")
    }

    /// The report's lines as the card draws them, each with the path of
    /// the picture or file it delivers, if it delivers one.
    private var lines: [(text: String, media: String?)] {
        var openFence: MarkdownFence?
        var mathClosing: String?
        return report.components(separatedBy: "\n").map { (line: String) -> (text: String, media: String?) in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = openFence {
                if fence.closes(trimmed) { openFence = nil }
                return (line, nil)
            }
            if let closing = mathClosing {
                if trimmed == closing { mathClosing = nil }
                return (line, nil)
            }
            if let fence = MarkdownFence.opening(trimmed) { openFence = fence; return (line, nil) }
            if trimmed == "$$" { mathClosing = "$$"; return (line, nil) }
            if trimmed == "\\[" { mathClosing = "\\]"; return (line, nil) }
            let marker = trimmed.range(of: #"^(?:[-*+]|\d{1,9}[.)])\s+"#, options: .regularExpression)
            if let path = Self.referencePath(marker.map { String(trimmed[$0.upperBound...]) } ?? trimmed) {
                return (ToolResultPresentation.mediaTag(for: path), path)
            }
            return (line, GatewayMediaTags.soleMediaPath(line))
        }
    }

    /// The path of a line that is only an `@image:` or `@file:` reference,
    /// bare or quoted as Hermes quotes one (`format_reference_value`).
    private static func referencePath(_ line: String) -> String? {
        guard let prefix = ["@image:", "@file:"].first(where: line.hasPrefix) else { return nil }
        var value = String(line.dropFirst(prefix.count))
        if value.count >= 2, let first = value.first, first == value.last, "`\"'".contains(first) {
            value = String(value.dropFirst().dropLast())
            // Two quoted references on one line are two files, not one path.
            guard !value.contains(first) else { return nil }
        } else if value.contains(where: \.isWhitespace) {
            return nil
        }
        // Nor are two references run together without a space.
        guard !value.contains("@image:"), !value.contains("@file:") else { return nil }
        guard !value.isEmpty, !value.contains("`"), !value.allSatisfy({ "\"'".contains($0) }) else { return nil }
        return value
    }
}

/// The report as a card in the Bot Chat: the job's name, the first lines,
/// all of it a tap away. An event in the chat, not the bot speaking.
struct CronReportCard: View {
    let report: CronBotChatReport
    let timestamp: String
    /// Reads the pictures and files the report delivered from Hermes, as
    /// a reply's are read. Nil leaves their tags as text.
    let gatewayResolver: GatewayMediaDataURLResolver?
    /// The row's key in `disclosure`, so a rebuilt row stays open.
    let disclosureID: String
    @Environment(\.chatRowDisclosure) private var disclosure
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Nil until tapped here: a rebuilt row takes what the reader chose
    /// from `disclosure`.
    @State private var tapped: Bool?

    private var expanded: Bool {
        tapped ?? disclosure?.isExpanded(disclosureID, default: false) ?? false
    }

    var body: some View {
        Button {
            Haptics.selection()
            let opens = !expanded
            // Tells the scroller first, as every row that opens does.
            disclosure?.willToggle(disclosureID, to: opens)
            withAnimation(ConduitMotion.ease(reduceMotion: reduceMotion)) { tapped = opens }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .scaledFont(.caption.weight(.bold))
                        .foregroundStyle(Color.secondary)
                        .accessibilityHidden(true)
                    Text(report.job)
                        .scaledFont(.caption.weight(.bold))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !report.report.isEmpty {
                        Text(expanded ? AppLocalization.string("Show less") : AppLocalization.string("Show all"))
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .scaledFont(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
                // The report and its footer as one: opened, the whole
                // text fades in where it lands, and the preview and the
                // footer don't slide through it.
                VStack(alignment: .leading, spacing: 6) {
                    if expanded {
                        MarkdownText(
                            source: report.shown,
                            gatewayMediaDataURL: gatewayResolver.map { resolver in
                                { path in await resolver.dataURL(for: path) }
                            }
                        )
                            .scaledFont(.subheadline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !report.report.isEmpty {
                        Text(BotWorkLook.rendered(report.preview))
                            .scaledFont(.subheadline)
                            .foregroundStyle(Color.primary)
                            .lineLimit(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 6) {
                        Text(AppLocalization.string("Scheduled job report", table: .tasks))
                        if let time = MessageTimestampFormatter.displayString(for: timestamp) {
                            Text(verbatim: "·")
                            Text(time)
                        }
                    }
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
                }
                .id(expanded)
                .transition(.rowFoldSwap)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
            // As it grows open, the text shows only inside the card.
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(report.report.isEmpty)
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityValue(expanded ? AppLocalization.string("Expanded") : AppLocalization.string("Collapsed"))
        .accessibilityHint(expanded ? AppLocalization.string("Shows less") : AppLocalization.string("Shows more"))
        .accessibilityIdentifier("cron.report")
    }
}
