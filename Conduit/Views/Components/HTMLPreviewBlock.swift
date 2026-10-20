//
//  HTMLPreviewBlock.swift
//  Conduit
//
//  Hermes' `::preview{file="…"}` transcript directive: the agent writes an
//  HTML file on its host (a chart, a small dashboard) and asks for it to be
//  shown inside the reply. Hermes Desktop draws it in a sandboxed frame;
//  Conduit draws it in a web page the same way MarkupBlock draws diagrams.
//
//  The file comes from the host through the authenticated dashboard (the
//  same read MEDIA: files use). The page runs the file's own scripts, since
//  charts need them, but it keeps nothing (no cookies or storage survive
//  the page), can't reach the app beyond reporting its height, and can't
//  navigate: a tapped link opens in the browser instead. In the message the
//  page takes no touches, so the chat scrolls over it; a tap opens it full
//  screen, where it is interactive.
//
//  A path that isn't HTML, a file the host won't send, or a page that never
//  measures itself falls back to the ordinary file card.
//

import SwiftUI
import UIKit
import WebKit

/// Finds `::preview{file="…"}` directives in a line of a reply. The grammar
/// follows Hermes Desktop's transcript directives (lib/transcript-
/// directives.ts): the directive starts a word (so `std::preview` isn't
/// one), attributes are `key="value"` or `key='value'`, and a directive
/// without a file stays the text it is.
enum TranscriptDirectives {
    enum Segment: Equatable {
        case text(String)
        case preview(file: String)
    }

    private static let previewExpression = try! NSRegularExpression(
        pattern: #"(?:^|(?<=\s))::preview\{([^{}\n]{0,1024})\}"#
    )
    private static let attributeExpression = try! NSRegularExpression(
        pattern: #"([A-Za-z][\w-]{0,63})=(?:"([^"]*)"|'([^']*)')"#
    )
    private static let htmlExpression = try! NSRegularExpression(
        pattern: #"\.(?:html?|xhtml)$"#,
        options: [.caseInsensitive]
    )

    /// The line split into text and previews, or nil when it holds none.
    static func segments(in line: String) -> [Segment]? {
        guard line.contains("::preview{") else { return nil }
        let nsLine = line as NSString
        var segments: [Segment] = []
        var cursor = 0
        for match in previewExpression.matches(in: line, range: NSRange(location: 0, length: nsLine.length)) {
            let body = nsLine.substring(with: match.range(at: 1))
            guard let file = attributes(in: body)["file"]?.trimmingCharacters(in: .whitespaces),
                  !file.isEmpty else { continue }
            appendText(nsLine.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), to: &segments)
            segments.append(.preview(file: file))
            cursor = NSMaxRange(match.range)
        }
        guard cursor > 0 else { return nil }
        appendText(nsLine.substring(from: cursor), to: &segments)
        return segments
    }

    /// Whether the file draws in place; anything else gets a file card.
    static func isHTML(_ path: String) -> Bool {
        htmlExpression.firstMatch(in: path, range: NSRange(location: 0, length: (path as NSString).length)) != nil
    }

    /// `text` without its previews, for places that read a reply rather
    /// than render it (Read Aloud).
    static func removingPreviews(from text: String) -> String {
        guard text.contains("::preview{") else { return text }
        // Line endings normalized as the parser does, so its table check sees the same lines.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return lines.indices.compactMap { index -> String? in
            let line = lines[index]
            // A quoted directive is an example and a table header cell is
            // table text; the chat shows both as written.
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix(">"),
                  let segments = segments(in: line),
                  !MarkdownParser.isTableHeader(lines, at: index) else { return line }
            let kept = segments.compactMap { segment -> String? in
                if case .text(let value) = segment { return value }
                return nil
            }
            return kept.isEmpty ? nil : kept.joined(separator: " ")
        }.joined(separator: "\n")
    }

    private static func attributes(in body: String) -> [String: String] {
        let nsBody = body as NSString
        var attributes: [String: String] = [:]
        for match in attributeExpression.matches(in: body, range: NSRange(location: 0, length: nsBody.length)) {
            let name = nsBody.substring(with: match.range(at: 1)).lowercased()
            let valueRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            attributes[name] = valueRange.location != NSNotFound ? nsBody.substring(with: valueRange) : ""
        }
        return attributes
    }

    private static func appendText(_ text: String, to segments: inout [Segment]) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { segments.append(.text(trimmed)) }
    }
}

/// An agent's HTML file drawn in the message.
struct HTMLPreviewBlock<Fallback: View>: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let path: String
    let gatewayMediaDataURL: ((String) async -> String?)?
    /// False while the streaming reply may still be writing this line; the
    /// file is often still being written too.
    var isComplete = true
    /// The file card shown when the page can't be drawn.
    @ViewBuilder let fallback: () -> Fallback

    @Environment(\.markupDrawsInPlace) private var drawsInPlace
    @Environment(\.colorScheme) private var colorScheme
    @State private var state: LoadState = .loading
    @State private var measuredHeight: CGFloat?
    @State private var showsFullScreen = false
    /// The page the sheet shows, kept apart from `state` so a reload
    /// underneath doesn't blank an open sheet.
    @State private var sheetHTML: String?

    enum LoadState: Equatable {
        case loading
        case loaded(String)
        case unavailable
    }

    /// How long a page may take to measure itself before the block gives
    /// up on it and shows the file card.
    static var drawTimeout: Duration { .seconds(20) }

    private var draws: Bool { isComplete && drawsInPlace }
    private var isMeasuring: Bool {
        if case .loaded = state { return measuredHeight == nil }
        return false
    }
    private var name: String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    var body: some View {
        Group {
            // A settled reply that still shows sources (a very large one
            // while it streams) shows the file card rather than waiting.
            if state == .unavailable || (isComplete && !drawsInPlace) {
                fallback()
            } else {
                card
            }
        }
        .task(id: LoadKey(path: path, draws: draws)) {
            await loadDocument()
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if case .loaded(let html) = state {
                page(html)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading preview…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 56)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.secondary.opacity(0.20), lineWidth: 1) }
        .sheet(isPresented: $showsFullScreen, onDismiss: { sheetHTML = nil }) {
            if let sheetHTML {
                HTMLPreviewSheet(name: name, html: sheetHTML)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Label {
                Text(verbatim: name).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: "chart.xyaxis.line")
            }
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(.secondary)
            // The spinner over a measuring page isn't read out; say it here
            // (before the page loads, the loading row says it). Once
            // measured, the page element carries the name and the action.
            .accessibilityValue(isMeasuring ? Text("Loading preview…") : Text(verbatim: ""))
            .accessibilityHidden(measuredHeight != nil)
            Spacer()
            if measuredHeight != nil {
                Button {
                    openFullScreen()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2.weight(.semibold))
                }
                .tint(.conduitAccent)
                .accessibilityLabel(Text("Open full screen"))
                .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func page(_ html: String) -> some View {
        let light = colorScheme == .light
        HTMLPreviewWebView(
            html: HTMLPreviewPage.framed(html, theme: HTMLPreviewTheme(light: light), presentation: .inline),
            interactive: false,
            onHeight: { height in
                let clamped = HTMLPreviewPage.clampedInlineHeight(height)
                HTMLPreviewHeights.store(clamped, for: path)
                if measuredHeight != clamped { measuredHeight = clamped }
            },
            // WebKit kept ending the page's process: the file card instead
            // of a blank frame.
            onFailed: { state = .unavailable }
        )
        .frame(maxWidth: .infinity)
        .frame(height: measuredHeight ?? HTMLPreviewHeights.height(for: path) ?? HTMLPreviewPage.placeholderHeight)
        .opacity(measuredHeight == nil ? 0 : 1)
        .overlay {
            if measuredHeight == nil {
                ProgressView()
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { openFullScreen() }
            }
        }
        .task(id: html) {
            // A page that never reports (WebKit stalled, the file isn't
            // really a page) turns into the file card.
            try? await Task.sleep(for: Self.drawTimeout)
            guard !Task.isCancelled, measuredHeight == nil else { return }
            state = .unavailable
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Open full screen"))
        .accessibilityAction { openFullScreen() }
        .accessibilityHidden(measuredHeight == nil)
    }

    private func openFullScreen() {
        guard case .loaded(let html) = state else { return }
        sheetHTML = html
        showsFullScreen = true
    }

    private func loadDocument() async {
        guard draws else {
            state = .loading
            return
        }
        guard let gatewayMediaDataURL else {
            state = .unavailable
            return
        }
        // Read on every appearance, so a file the agent rewrote for a later
        // reply shows its new version; the reserved height keeps the row still.
        state = .loading
        measuredHeight = nil
        let dataURL = await gatewayMediaDataURL(path)
        guard !Task.isCancelled else { return }
        guard let dataURL, let html = HTMLPreviewPage.decodedDocument(fromDataURL: dataURL) else {
            state = .unavailable
            return
        }
        state = .loaded(html)
    }

    private struct LoadKey: Hashable {
        let path: String
        let draws: Bool
    }
}

/// Measured heights by path, so a rebuilt row reserves its real height
/// while its page draws again.
@MainActor
enum HTMLPreviewHeights {
    private static var heights: [String: CGFloat] = [:]
    private static let limit = 128

    static func height(for path: String) -> CGFloat? { heights[path] }

    static func store(_ height: CGFloat, for path: String) {
        if heights[path] == nil, heights.count >= limit {
            // Drop half rather than all, as MarkupHeights does, so a long
            // chat doesn't lose every reserved height at once.
            for stale in Array(heights.keys.prefix(limit / 2)) {
                heights[stale] = nil
            }
        }
        heights[path] = height
    }
}

/// The app's colors handed to the page under the names Hermes tells agents
/// to use (`var(--foreground)` and friends), so a widget reads as part of
/// the chat.
struct HTMLPreviewTheme: Equatable {
    let light: Bool
    let foreground: String
    let mutedForeground: String
    let accent: String
    let border: String
    let card: String

    init(light: Bool) {
        let traits = UITraitCollection(userInterfaceStyle: light ? .light : .dark)
        func css(_ color: UIColor) -> String { HTMLPreviewTheme.css(color.resolvedColor(with: traits)) }
        self.light = light
        foreground = css(.label)
        mutedForeground = css(.secondaryLabel)
        accent = css(UIColor(Color.conduitAccent))
        border = css(.separator)
        card = css(.secondarySystemBackground)
    }

    static func css(_ color: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "currentColor" }
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        let opacity = String(format: "%.3f", Double(min(max(alpha, 0), 1)))
        return "rgba(\(channel(red)),\(channel(green)),\(channel(blue)),\(opacity))"
    }
}

/// The page around an agent's HTML: the theme first (so the file's own
/// styles win), then the scripts that report its height and stand in for
/// Desktop's `window.hermes`.
enum HTMLPreviewPage {
    enum Presentation {
        case inline
        case fullScreen
    }

    static let messageHandlerName = "conduitPreview"
    /// No base URL: the page has no origin of its own, so it can't reach
    /// files on the phone or pass for a site.
    static let baseURL: URL? = nil
    /// The page can draw anything and load images, media, styles and
    /// scripts from anywhere, but can't send data off with fetch, XHR,
    /// sockets, beacons or forms, or load frames, workers or plug-ins that
    /// would run outside this policy (#770). A policy in the file itself
    /// only adds limits; it can't lift these. What it may still load can
    /// carry data one way in the URL; blocking that would break charts
    /// drawn with a CDN library.
    /// WebRTC is outside any policy; closing it would take a script of the
    /// app's own in the page.
    static let contentSecurityPolicy = "connect-src data: blob:; frame-src 'none'; worker-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"

    /// The app listens for the inline page's height and nothing else.
    static func messageHandlerNames(reportsHeight: Bool) -> [String] {
        reportsHeight ? [messageHandlerName] : []
    }
    static let placeholderHeight: CGFloat = 280
    static let minimumInlineHeight: CGFloat = 60
    /// The tallest a page draws in a message; full screen shows the rest.
    static let maximumInlineHeight: CGFloat = 900
    /// Larger files get the file card rather than a page.
    static let maximumDocumentBytes = 4 * 1024 * 1024

    static func clampedInlineHeight(_ height: CGFloat) -> CGFloat {
        min(maximumInlineHeight, max(minimumInlineHeight, height.rounded(.up)))
    }

    /// The file's text from the dashboard's data URL, or nil when it isn't
    /// a readable text file of a sensible size.
    static func decodedDocument(fromDataURL dataURL: String) -> String? {
        // Too large is told from the encoded length, before decoding.
        guard let comma = dataURL.firstIndex(of: ","),
              dataURL[dataURL.index(after: comma)...].utf8.count <= ((maximumDocumentBytes + 2) / 3) * 4,
              let data = DataURLLimits.decodeBase64DataURL(dataURL),
              data.count <= maximumDocumentBytes else { return nil }
        // UTF-8 only: any bytes decode as Latin-1, so invalid or non-UTF-8
        // bytes would draw as garbage instead of falling back to the card.
        guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    static func framed(_ document: String, theme: HTMLPreviewTheme, presentation: Presentation) -> String {
        let prelude = themePrelude(theme, presentation: presentation)
        let withPrelude: String
        if let headEnd = openingTagEnd("head", in: document) ?? openingTagEnd("html", in: document) {
            withPrelude = String(document[..<headEnd]) + prelude + String(document[headEnd...])
        } else if let doctypeEnd = doctypeEnd(in: document) {
            withPrelude = String(document[..<doctypeEnd]) + prelude + String(document[doctypeEnd...])
        } else {
            withPrelude = prelude + document
        }
        let scripts = bridgeScript(reportsHeight: presentation == .inline)
        let page: String
        if let bodyClose = withPrelude.range(of: "</body", options: [.caseInsensitive, .backwards]) {
            page = String(withPrelude[..<bodyClose.lowerBound]) + scripts + String(withPrelude[bodyClose.lowerBound...])
        } else {
            page = withPrelude + scripts
        }
        return withPolicyFirst(page)
    }

    /// The policy goes before anything of the file's but a leading doctype
    /// (moving that would change how the page lays out), so no script of
    /// the file's runs before it. The `<head>` the theme looks for can sit
    /// after a script, or inside one.
    private static func withPolicyFirst(_ page: String) -> String {
        let policy = #"<meta http-equiv="Content-Security-Policy" content="\#(contentSecurityPolicy)">"#
        guard let doctypeEnd = doctypeEnd(in: page) else { return policy + page }
        return String(page[..<doctypeEnd]) + policy + String(page[doctypeEnd...])
    }

    /// The page fits the phone's width, follows the app's light or dark
    /// look, and sits on the message with no margin or background of its
    /// own unless the file sets them.
    private static func themePrelude(_ theme: HTMLPreviewTheme, presentation: Presentation) -> String {
        let scheme = theme.light ? "light" : "dark"
        let background = presentation == .inline ? "transparent" : (theme.light ? "#ffffff" : "#000000")
        return """
        <meta name="viewport" content="width=device-width,initial-scale=1"><style>:root{color-scheme:\(scheme);--foreground:\(theme.foreground);--muted-foreground:\(theme.mutedForeground);--accent:\(theme.accent);--border:\(theme.border);--card:\(theme.card)}html,body{margin:0;padding:0;background:\(background);color:var(--foreground);font-family:-apple-system,BlinkMacSystemFont,sans-serif;-webkit-text-size-adjust:100%}</style>
        """
    }

    /// `window.hermes.send` exists so a Desktop widget's buttons don't throw;
    /// Conduit doesn't send widget prompts, so it answers that the prompt
    /// wasn't delivered, as Desktop does when no composer takes it.
    private static func bridgeScript(reportsHeight: Bool) -> String {
        let hermes = "window.hermes={maxLength:500,send:function(){return Promise.resolve({ok:false,error:'undelivered'})}};"
        guard reportsHeight else { return "<script>(function(){\(hermes)})()</script>" }
        return """
        <script>(function(){\(hermes)var last=0;function measure(){var b=document.body;if(!b)return 0;var bottom=0;for(var i=0;i<b.children.length;i++){var r=b.children[i].getBoundingClientRect();if(r.width===0&&r.height===0)continue;var s=getComputedStyle(b.children[i]);bottom=Math.max(bottom,r.bottom+window.scrollY+(parseFloat(s.marginBottom)||0));}return Math.ceil(bottom||b.scrollHeight);}function post(){var h=measure();if(h>0&&Math.abs(h-last)>1){last=h;try{window.webkit.messageHandlers.\(messageHandlerName).postMessage({height:h})}catch(e){}}}if(typeof ResizeObserver==='function'){var o=new ResizeObserver(post);o.observe(document.documentElement);if(document.body)o.observe(document.body);}addEventListener('load',post);setTimeout(post,250);setTimeout(post,1500);post();})()</script>
        """
    }

    private static func openingTagEnd(_ tag: String, in document: String) -> String.Index? {
        guard let range = document.range(of: "<\(tag)(\\s[^>]*)?>", options: [.regularExpression, .caseInsensitive]) else { return nil }
        return range.upperBound
    }

    private static func doctypeEnd(in document: String) -> String.Index? {
        // Only HTML whitespace may precede the doctype. Other Unicode
        // whitespace starts the body, where a CSP meta would be ignored.
        guard let range = document.range(of: #"^[\t\n\f\r ]*<!doctype[^>]*>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return range.upperBound
    }

    /// The page itself stays; frames (which the policy blocks too) and
    /// navigations away from it are cancelled, and a link the user tapped
    /// opens in the browser. A navigation without a URL is the page's own
    /// load.
    static func navigationDecision(url: URL?, isMainFrame: Bool, userTapped: Bool) -> (allow: Bool, openExternally: URL?) {
        let scheme = url?.scheme?.lowercased()
        if url == nil || url?.absoluteString == "about:blank" {
            return (true, nil)
        }
        if isMainFrame, userTapped, let url, scheme == "https" || scheme == "http" {
            return (false, url)
        }
        return (false, nil)
    }
}

/// The page an agent's HTML draws in. Nothing it stores outlives it, and
/// its only message to the app is its height.
struct HTMLPreviewWebView: UIViewRepresentable {
    let html: String
    let interactive: Bool
    var onHeight: ((CGFloat) -> Void)? = nil
    var onFailed: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = Self.configuration(
            reportsHeight: onHeight != nil,
            handler: MarkupMessageProxy(context.coordinator)
        )
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = interactive
        view.isUserInteractionEnabled = interactive
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.onHeight = onHeight
        context.coordinator.onFailed = onFailed
        context.coordinator.load(html, into: view)
        return view
    }

    /// What keeps an agent's script harmless: nothing stored outlives the
    /// page, no window opens on its own, and the only message the app takes
    /// is the height. Tests hold this in place.
    static func configuration(reportsHeight: Bool, handler: WKScriptMessageHandler) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        for name in HTMLPreviewPage.messageHandlerNames(reportsHeight: reportsHeight) {
            configuration.userContentController.add(handler, name: name)
        }
        return configuration
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onHeight = onHeight
        context.coordinator.onFailed = onFailed
        context.coordinator.load(html, into: view)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        // A no-op for the full-screen page, which never added it.
        view.configuration.userContentController.removeScriptMessageHandler(forName: HTMLPreviewPage.messageHandlerName)
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.stopLoading()
        coordinator.onHeight = nil
        coordinator.onFailed = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var onHeight: ((CGFloat) -> Void)?
        var onFailed: (() -> Void)?
        private var html = ""
        private var reloads = MarkupReloads()

        /// Loads once per page; SwiftUI calls this on every update.
        func load(_ html: String, into view: WKWebView) {
            guard html != self.html else { return }
            self.html = html
            reloads = MarkupReloads()
            view.loadHTMLString(html, baseURL: HTMLPreviewPage.baseURL)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let height = body["height"] as? Double,
                  height.isFinite, height > 0 else { return }
            reloads.pageDrew()
            onHeight?(CGFloat(height))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard !html.isEmpty else { return }
            if reloads.mayReload() {
                webView.loadHTMLString(html, baseURL: HTMLPreviewPage.baseURL)
            } else {
                onFailed?()
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let decision = HTMLPreviewPage.navigationDecision(
                url: navigationAction.request.url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                userTapped: navigationAction.navigationType == .linkActivated
            )
            if let url = decision.openExternally { UIApplication.shared.open(url) }
            decisionHandler(decision.allow ? .allow : .cancel)
        }

        /// `target="_blank"` links: no new page, the browser instead.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let decision = HTMLPreviewPage.navigationDecision(
                url: navigationAction.request.url,
                isMainFrame: true,
                userTapped: navigationAction.navigationType == .linkActivated
            )
            if let url = decision.openExternally { UIApplication.shared.open(url) }
            return nil
        }
    }
}

/// An agent's page full screen, where it can be touched, scrolled and
/// zoomed.
struct HTMLPreviewSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let name: String
    let html: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            HTMLPreviewWebView(
                html: HTMLPreviewPage.framed(html, theme: HTMLPreviewTheme(light: colorScheme == .light), presentation: .fullScreen),
                interactive: true,
                // WebKit kept ending the page: close rather than stay blank.
                onFailed: { dismiss() }
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(Text(verbatim: name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}
