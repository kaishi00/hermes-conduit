//
//  MarkupBlock.swift
//  Conduit
//
//  Mermaid diagrams and LaTeX formulas in messages. Each one draws in place,
//  in a small web page, as soon as its block is complete; a tap opens it full
//  screen to zoom. The renderers (Mermaid, KaTeX) load from jsDelivr, which
//  WebKit's cache keeps after the first page.
//
//  While a reply streams, its last block may still be half written, so a
//  diagram or formula there shows its source until more text follows it or
//  the reply settles. Drawing a half-written chart only produces errors.
//  A very large reply (see MarkdownLargeDocumentPolicy) shows every source
//  while it streams and draws once it settles, where its chunk windows
//  bound how many pages mount.
//

import CryptoKit
import SwiftUI
import UIKit
import WebKit

enum MarkupKind: Hashable {
    case mermaid
    case math
}

/// One drawable source and every input its page depends on.
struct MarkupDocument: Hashable {
    let kind: MarkupKind
    let source: String
    let light: Bool
    /// Formulas follow the chat text size; diagrams scale to their width
    /// and don't use it (zero), so a size change doesn't redraw them.
    let fontSize: CGFloat
}

/// A diagram or formula drawn in the message, with its source a copy away.
struct MarkupBlock: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let kind: MarkupKind
    let source: String
    /// False while the streaming reply may still be writing this block.
    var isComplete = true

    @Environment(\.markupDrawsInPlace) private var drawsInPlace
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatTextSize) private var chatTextSize
    /// The chat's scroll engine, which says when the card takes its height.
    @Environment(\.chatRowDisclosure) private var disclosure
    /// The room the card holds and the height it has taken (#1238).
    @StateObject private var cardHeight = ChatCardHeight()
    /// The block's frame, and a failure waiting to take the drawing's
    /// place (#1238).
    @StateObject private var fallbackArrival = ChatRowArrival()
    /// A page's failure, when it reported one or never reported.
    @State private var report: MarkupDrawReport?
    /// The page whose failure shows: it takes the drawing's place only
    /// once the scroll engine lets it.
    @State private var shownFailure: MarkupDrawKey?
    /// Bumped by Try again, which rebuilds the page.
    @State private var attempt = 0
    @State private var showsFullScreen = false

    /// How long a page may take before the block offers Try again. Covers
    /// a slow first download of the renderer.
    static let drawTimeout: Duration = .seconds(20)
    /// How much of the source VoiceOver reads as the block's value.
    static let accessibilitySourceLimit = 2_000
    /// Space held for a page that hasn't measured itself yet.
    static func placeholderHeight(for kind: MarkupKind) -> CGFloat {
        kind == .mermaid ? 180 : 56
    }

    private var document: MarkupDocument {
        MarkupDocument(
            kind: kind,
            source: source,
            light: colorScheme == .light,
            fontSize: kind == .math ? ChatTypography.font(for: .body, appearance: chatTextSize).pointSize : 0
        )
    }

    private var key: MarkupDrawKey { MarkupDrawKey(document: document, attempt: attempt) }

    /// Whether the block draws now, or shows its source until it can.
    private var draws: Bool { isComplete && drawsInPlace }

    /// What the current page reported and shows; nil while it's still
    /// drawing, or while its failure waits to take the drawing's place.
    private var outcome: MarkupDrawReport.Outcome? {
        report?.key == key && shownFailure == key ? report?.outcome : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !draws {
                sourcePreview
            } else if case .failed(let detail) = outcome {
                failure(detail)
                sourcePreview
            } else {
                drawing
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.secondary.opacity(0.20), lineWidth: 1) }
        .sheet(isPresented: $showsFullScreen) {
            MarkupPreviewSheet(document: document)
        }
        .chatRowFrame(fallbackArrival)
        // A failure still waiting goes with the block and comes back with
        // it, since the page doesn't report again.
        .onDisappear { fallbackArrival.rowDisappeared() }
        .onAppear {
            if report?.key == key { showFailure(of: key) }
        }
        .task(id: MarkupDrawTask(key: key, draws: draws)) {
            await offerRetryIfStillDrawing()
        }
        // Another page (the theme or text size changed, Try again) draws in
        // the same room and shows once it reports; a failure the page before
        // reported goes with it.
        .onChange(of: key) {
            cardHeight.pageReplaced()
            fallbackArrival.rowDisappeared()
        }
    }

    private var title: String { kind == .mermaid ? "Mermaid" : "LaTeX" }

    private var header: some View {
        HStack(spacing: 14) {
            Label(title, systemImage: kind == .mermaid ? "point.3.connected.trianglepath.dotted" : "function")
                .scaledFont(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
            // Only for a block still being written; one waiting for a large
            // reply to settle isn't working on anything yet.
            if !isComplete {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            Button {
                UIPasteboard.general.string = source
                Haptics.light()
            } label: { Label("Copy source", systemImage: "doc.on.doc").scaledFont(.caption2.weight(.semibold)) }
                .tint(.conduitAccent)
            // A failed page has nothing to zoom; Try again is the way on.
            if draws, !hasFailed {
                Button {
                    showsFullScreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .scaledFont(.caption2.weight(.semibold))
                }
                .tint(.conduitAccent)
                .accessibilityLabel(Text("Open full screen"))
            }
        }
    }

    /// The current page's height, once it has reported and taken it.
    private var drawnHeight: CGFloat? {
        cardHeight.isDrawn(key) ? cardHeight.taken : nil
    }

    private var hasFailed: Bool {
        if case .failed = outcome { return true }
        return false
    }

    @ViewBuilder
    private var drawing: some View {
        let document = self.document
        let key = self.key
        let drawnHeight = self.drawnHeight
        MarkupWebView(document: document) { event in
            record(event, for: key)
        }
        .id(attempt)
        .frame(maxWidth: .infinity)
        // The room the page draws in, held from the card's first frame and
        // through a redraw; it changes only when the page has measured
        // itself and the scroll engine lets the card take the height.
        .frame(height: cardHeight.frameHeight(
            reserving: TranscriptPictureMemory.height(for: Self.heightKey(for: document)) ?? Self.placeholderHeight(for: kind)
        ))
        .cardStackFrame(cardHeight)
        .opacity(drawnHeight == nil ? 0 : 1)
        .overlay {
            if drawnHeight == nil {
                ProgressView()
            } else {
                // The page takes no touches, so the chat keeps scrolling over
                // it; a tap opens it full screen.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { showsFullScreen = true }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(kind == .mermaid ? AppLocalization.string("Diagram") : AppLocalization.string("Formula")))
        // The source is the only text form of what's drawn.
        .accessibilityValue(Text(verbatim: String(source.prefix(Self.accessibilitySourceLimit))))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Open full screen"))
        .accessibilityAction { showsFullScreen = true }
        // Like the tap, only once there's something to see; the header
        // still names the block while it draws.
        .accessibilityHidden(drawnHeight == nil)
    }

    private func failure(_ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kind == .mermaid ? AppLocalization.string("Couldn't draw this diagram.") : AppLocalization.string("Couldn't draw this formula."))
                .scaledFont(.footnote.weight(.semibold))
            if let detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            Button {
                attempt += 1
            } label: {
                Label("Try again", systemImage: "arrow.clockwise").scaledFont(.caption.weight(.semibold))
            }
            .tint(.conduitAccent)
        }
    }

    private var sourcePreview: some View {
        SelectableTextView(
            text: source,
            font: ChatTypography.font(for: .sourceCode, appearance: chatTextSize),
            textColor: .label,
            maximumNumberOfLines: 5
        )
    }

    private func record(_ event: MarkupWebView.Event, for key: MarkupDrawKey) {
        switch event {
        case .height(let height):
            // A page measured before it had a width reports nothing useful.
            guard height >= 1 else { return }
            TranscriptPictureMemory.rememberHeight(height, for: Self.heightKey(for: key.document))
            // A page already replaced reports to nobody.
            guard key == self.key else { return }
            cardHeight.pageMeasured(height, page: key, engine: disclosure?.engine)
        case .failed(let detail):
            guard key == self.key else { return }
            report = MarkupDrawReport(key: key, outcome: .failed(detail))
            showFailure(of: key)
        }
    }

    /// The failure takes the drawing's place once the reader's scrolling
    /// allows, the way a card takes its height, with a height only its
    /// layout tells (#1238).
    private func showFailure(of key: MarkupDrawKey) {
        guard shownFailure != key else { return }
        fallbackArrival.arrive(rowHeight: nil, engine: disclosure?.engine) { shownFailure = key }
    }

    /// A page that never reports (the renderer didn't download, WebKit
    /// stalled) turns into the failure card instead of spinning forever.
    private func offerRetryIfStillDrawing() async {
        guard draws, outcome == nil, drawnHeight == nil else { return }
        let key = self.key
        try? await Task.sleep(for: Self.drawTimeout)
        guard !Task.isCancelled, report?.key != key, !cardHeight.hasMeasured(key) else { return }
        report = MarkupDrawReport(key: key, outcome: .failed(nil))
        showFailure(of: key)
    }

    /// Where a page's height is kept across launches: by what decides it,
    /// the kind, the text size (formulas) and the source, never the theme.
    /// A digest, so the memo holds no sources.
    static func heightKey(for document: MarkupDocument) -> String {
        let kind = document.kind == .mermaid ? "mermaid" : "math"
        let digest = SHA256.hash(data: Data("\(kind)\u{1f}\(document.fontSize)\u{1f}\(document.source)".utf8))
        return "markup|" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

struct MarkupDrawKey: Hashable {
    let document: MarkupDocument
    let attempt: Int
}

private struct MarkupDrawTask: Hashable {
    let key: MarkupDrawKey
    let draws: Bool
}

/// False where diagrams and formulas show their source instead of drawing:
/// a very large streaming reply, whose finished chunks pile up as it grows.
struct MarkupDrawsInPlaceKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var markupDrawsInPlace: Bool {
        get { self[MarkupDrawsInPlaceKey.self] }
        set { self[MarkupDrawsInPlaceKey.self] = newValue }
    }
}

/// A block's page failing, and which page: its heights go through
/// ChatCardHeight instead.
struct MarkupDrawReport: Equatable {
    enum Outcome: Equatable {
        /// The renderer's own message, when it gave one.
        case failed(String?)
    }

    let key: MarkupDrawKey
    let outcome: Outcome
}

/// The page a block draws in. It takes no touches: the chat scrolls over it
/// and the block handles taps.
struct MarkupWebView: UIViewRepresentable {
    enum Event: Equatable {
        case height(CGFloat)
        case failed(String?)
    }

    let document: MarkupDocument
    let onEvent: (Event) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(
            MarkupMessageProxy(context.coordinator),
            name: MarkupHTML.messageHandlerName
        )
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        view.navigationDelegate = context.coordinator
        context.coordinator.onEvent = onEvent
        context.coordinator.load(document, into: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onEvent = onEvent
        context.coordinator.load(document, into: view)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: MarkupHTML.messageHandlerName)
        view.navigationDelegate = nil
        view.stopLoading()
        coordinator.onEvent = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onEvent: ((Event) -> Void)?
        private var loaded: MarkupDocument?
        private var html = ""
        private var reloads = MarkupReloads()

        /// Loads the page once per document; SwiftUI calls this on every
        /// update, which during a stream is every frame.
        func load(_ document: MarkupDocument, into view: WKWebView) {
            guard document != loaded else { return }
            loaded = document
            reloads = MarkupReloads()
            html = MarkupHTML.page(document, presentation: .inline)
            view.loadHTMLString(html, baseURL: MarkupHTML.baseURL)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let height = body["height"] as? Double {
                reloads.pageDrew()
                onEvent?(.height(CGFloat(height)))
            } else if let detail = body["failed"] as? String {
                onEvent?(.failed(detail.isEmpty ? nil : detail))
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // WebKit can end an off-screen page's process under memory
            // pressure, which leaves the block blank until it reloads. A
            // page that keeps ending it before it draws gets the failure
            // card instead of reloading forever.
            guard !html.isEmpty else { return }
            if reloads.mayReload() {
                webView.loadHTMLString(html, baseURL: MarkupHTML.baseURL)
            } else {
                onEvent?(.failed(nil))
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(MarkupHTML.allowsNavigation(to: navigationAction.request.url) ? .allow : .cancel)
        }
    }
}

/// Reloads after WebKit ends a page's process. A page that draws starts
/// counting again; one that keeps losing its process before it draws stops
/// reloading.
struct MarkupReloads {
    static let limit = 2
    private(set) var sinceLastDraw = 0

    mutating func mayReload() -> Bool {
        guard sinceLastDraw < Self.limit else { return false }
        sinceLastDraw += 1
        return true
    }

    mutating func pageDrew() {
        sinceLastDraw = 0
    }
}

/// WebKit keeps its message handlers for the configuration's lifetime; the
/// proxy holds the page's coordinator weakly so the two don't keep each
/// other alive.
@MainActor
final class MarkupMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// A diagram or formula full screen, where it can be zoomed, with its source.
struct MarkupPreviewSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let document: MarkupDocument
    @Environment(\.dismiss) private var dismiss
    @Environment(\.chatTextSize) private var chatTextSize

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SafeMarkupWebView(html: MarkupHTML.page(document, presentation: .fullScreen))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    SelectableTextView(
                        text: document.source,
                        font: ChatTypography.font(for: .sourceCode, appearance: chatTextSize),
                        textColor: .label,
                        wrapsLines: false
                    )
                    .padding(12)
                }
                    .frame(maxHeight: 96)
            }
            .navigationTitle(document.kind == .mermaid ? AppLocalization.string("Diagram") : AppLocalization.string("Formula"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

struct SafeMarkupWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(html, baseURL: MarkupHTML.baseURL)
        return view
    }

    /// A new page while the sheet is open (light or dark switched) reloads.
    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.html != html else { return }
        context.coordinator.html = html
        context.coordinator.reloads = MarkupReloads()
        view.loadHTMLString(html, baseURL: MarkupHTML.baseURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator(html: html) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var html: String
        var reloads = MarkupReloads()

        init(html: String) {
            self.html = html
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // Same as the inline page: reload rather than stay blank, a
            // couple of times. This page doesn't report when it has drawn,
            // so the count only starts again with a new page.
            guard reloads.mayReload() else { return }
            webView.loadHTMLString(html, baseURL: MarkupHTML.baseURL)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(MarkupHTML.allowsNavigation(to: navigationAction.request.url) ? .allow : .cancel)
        }
    }
}

/// Fixes slips models commonly make in Mermaid they write, where the intent
/// is plain. An xychart axis range is `0 --> 20`; "0 to 20" is the usual
/// slip and fails the whole chart.
enum MermaidSourceRepair {
    static func repaired(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        guard lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces).hasPrefix("xychart") == true else { return source }
        return lines.map { line in
            guard line.range(of: #"^\s*[xy]-axis\b"#, options: .regularExpression) != nil else { return line }
            return line.replacingOccurrences(
                of: #"(-?\d+(?:\.\d+)?)\s+(?:to|-|–|—|->|\.\.)\s+(-?\d+(?:\.\d+)?)\s*$"#,
                with: "$1 --> $2",
                options: .regularExpression
            )
        }.joined(separator: "\n")
    }
}

private struct MarkupPalette {
    let background: String
    let foreground: String
    let muted: String
    let primary: String
    let border: String

    init(light: Bool) {
        (background, foreground, muted, primary, border) = light ? ("#ffffff", "#1b1d22", "#727780", "#f6f3eb", "#d4cdbf") : ("#16181e", "#f4f5f8", "#9ca1ac", "#20232b", "#454a57")
    }
}

/// The pages diagrams and formulas draw in. Inline pages are transparent,
/// fit the message width and report their height (or failure) through
/// `conduitMarkup`; full-screen pages fill the sheet and can be zoomed.
enum MarkupHTML {
    enum Presentation {
        case inline
        case fullScreen
    }

    static let baseURL = URL(string: "https://conduit.local/")
    static let messageHandlerName = "conduitMarkup"
    /// The tallest a diagram draws in a message; a taller one scales down
    /// to fit, and full screen shows it at size.
    static let inlineDiagramMaximumHeight = 480

    /// The page itself and the renderers' files on the CDN; anything else (a
    /// link in a diagram, another path, a javascript:, data: or file: URL)
    /// stays out.
    static func allowsNavigation(to url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" { return url.absoluteString.lowercased() == "about:blank" }
        guard scheme == "https", let host = url.host?.lowercased() else { return false }
        switch host {
        case "conduit.local":
            return url.path.isEmpty || url.path == "/"
        case "cdn.jsdelivr.net":
            return rendererPaths.contains(url.path) || url.path.hasPrefix(rendererFontFolder)
        default:
            return false
        }
    }

    /// Only the hashed files below and KaTeX's fonts, so a reference to
    /// another file or version can't load around the hashes.
    private static let rendererPaths = [mermaidScript, katexScript, katexStylesheet].compactMap { URL(string: $0.url)?.path }
    private static let rendererFontFolder = (URL(string: katexStylesheet.url)?.deletingLastPathComponent().path ?? "") + "/fonts/"

    /// The renderers' files, pinned by version and by hash: a file the CDN
    /// serves changed doesn't run. A version bump takes new hashes: hash the
    /// files in the npm tarball (`openssl dgst -sha384 -binary <file> | base64`)
    /// after checking the tarball against the registry's `dist.integrity`.
    /// A wrong hash shows "Couldn't draw" on every diagram or formula.
    static let mermaidScript = Subresource(
        url: "https://cdn.jsdelivr.net/npm/mermaid@11.16.0/dist/mermaid.min.js",
        integrity: "sha384-T/0lMUdJpd2S1ZHtRiofG3htU3xPCrFVeAQ1UUE2TJwlEJSV5NUwn30kP28n238E"
    )
    static let katexScript = Subresource(
        url: "https://cdn.jsdelivr.net/npm/katex@0.16.22/dist/katex.min.js",
        integrity: "sha384-cMkvdD8LoxVzGF/RPUKAcvmm49FQ0oxwDF3BGKtDXcEc+T1b2N+teh/OJfpU0jr6"
    )
    static let katexStylesheet = Subresource(
        url: "https://cdn.jsdelivr.net/npm/katex@0.16.22/dist/katex.min.css",
        integrity: "sha384-5TcZemv2l/9On385z///+d7MSYlvIEw9FuZTIdZ14vJLqWphw7e7ZPuOiCHJcFCP"
    )

    struct Subresource {
        let url: String
        let integrity: String

        var scriptTag: String {
            #"<script src="\#(url)" integrity="\#(integrity)" crossorigin="anonymous"></script>"#
        }

        var stylesheetTag: String {
            #"<link rel="stylesheet" href="\#(url)" integrity="\#(integrity)" crossorigin="anonymous">"#
        }
    }

    static func page(_ document: MarkupDocument, presentation: Presentation) -> String {
        switch document.kind {
        case .mermaid: return mermaid(document, presentation: presentation)
        case .math: return math(document, presentation: presentation)
        }
    }

    /// Posts to the app when it's listening (inline pages) and shows a
    /// failure as text, never as markup: the renderer's message can quote
    /// the source.
    private static func reportingScript(failureTitle: String) -> String {
        """
        function report(message){try{window.webkit.messageHandlers.\(messageHandlerName).postMessage(message)}catch(e){}}
        function fail(detail){report({failed:detail});const content=document.getElementById('content');const error=document.createElement('div');error.className='error';error.textContent=detail||\(jsonString(failureTitle));content.replaceChildren(error);}
        """
    }

    private static func mermaid(_ document: MarkupDocument, presentation: Presentation) -> String {
        let palette = MarkupPalette(light: document.light)
        let inline = presentation == .inline
        let background = inline ? "transparent" : palette.background
        let padding = inline ? "0" : "16px"
        let heightLimit = inline ? "#content svg{max-height:\(inlineDiagramMaximumHeight)px}" : ""
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;padding:0;background:\(background);color:\(palette.foreground)}#content{padding:\(padding);box-sizing:border-box}svg{display:block;max-width:100%;height:auto;margin:auto}\(heightLimit).error{font:14px -apple-system,sans-serif;color:#d14b4b;white-space:pre-wrap}</style>
        </head><body><div id="content"></div>
        \(mermaidScript.scriptTag)
        <script>\(reportingScript(failureTitle: AppLocalization.string("Couldn't draw this diagram.")))
        (async function(){const content=document.getElementById('content');if(typeof mermaid==='undefined'){fail('');return;}try{mermaid.initialize({startOnLoad:false,securityLevel:'strict',suppressErrorRendering:true,theme:'base',themeVariables:{background:'\(palette.background)',primaryColor:'\(palette.primary)',primaryTextColor:'\(palette.foreground)',primaryBorderColor:'\(palette.border)',lineColor:'\(palette.muted)',fontFamily:'-apple-system,BlinkMacSystemFont,sans-serif'}});const result=await mermaid.render('conduit-diagram',\(jsonString(MermaidSourceRepair.repaired(document.source))));content.innerHTML=result.svg;const send=()=>report({height:Math.ceil(content.getBoundingClientRect().height)});new ResizeObserver(send).observe(content);send();}catch(error){fail(String(error&&error.message?error.message:error));}})();</script></body></html>
        """
    }

    private static func math(_ document: MarkupDocument, presentation: Presentation) -> String {
        let palette = MarkupPalette(light: document.light)
        let inline = presentation == .inline
        let background = inline ? "transparent" : palette.background
        // Inline formulas sit at the chat's text size and shrink to fit a
        // narrow message; full screen keeps them large and scrollable.
        let fontSize = inline ? "\(Int(document.fontSize.rounded()))px" : "1.2em"
        let contentStyle = inline
            ? "#content{padding:4px 0;box-sizing:border-box;overflow:hidden}.katex-display{margin:0;overflow:visible}"
            : "#content{padding:24px;box-sizing:border-box;overflow:auto}"
        let throwsOnError = inline ? "true" : "false"
        let fitting = inline
            ? "function fit(){content.style.fontSize='';const formula=content.querySelector('.katex')||content;const overflow=formula.scrollWidth/Math.max(content.clientWidth,1);if(overflow>1){content.style.fontSize=Math.max(0.5,1/overflow)+'em';}}"
            : "function fit(){}"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        \(katexStylesheet.stylesheetTag)
        <style>html,body{margin:0;padding:0;background:\(background);color:\(palette.foreground)}body{font-size:\(fontSize)}\(contentStyle).error{font:14px -apple-system,sans-serif;color:#d14b4b;white-space:pre-wrap}</style>
        </head><body><div id="content"></div>
        \(katexScript.scriptTag)
        <script>\(reportingScript(failureTitle: AppLocalization.string("Couldn't draw this formula.")))
        (function(){const content=document.getElementById('content');if(typeof katex==='undefined'){fail('');return;}try{katex.render(\(jsonString(document.source)),content,{displayMode:true,throwOnError:\(throwsOnError),trust:false});}catch(error){fail(String(error&&error.message?error.message:error));return;}\(fitting)const send=()=>{fit();report({height:Math.ceil(content.getBoundingClientRect().height)});};new ResizeObserver(send).observe(content);document.fonts.ready.then(send);send();})();</script></body></html>
        """
    }

    static func jsonString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("\"\"".utf8)
        let json = String(data: data, encoding: .utf8) ?? "\"\""
        return json
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
