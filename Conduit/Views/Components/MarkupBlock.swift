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
//

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

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatTextSize) private var chatTextSize
    @State private var report: MarkupDrawReport?
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
            fontSize: kind == .math ? ChatTypography.font(for: .body, chatSize: chatTextSize).pointSize : 0
        )
    }

    private var key: MarkupDrawKey { MarkupDrawKey(document: document, attempt: attempt) }

    /// What the current page reported; nil while it's still drawing.
    private var outcome: MarkupDrawReport.Outcome? {
        report?.key == key ? report?.outcome : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !isComplete {
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
        .task(id: MarkupDrawTask(key: key, isComplete: isComplete)) {
            await offerRetryIfStillDrawing()
        }
    }

    private var title: String { kind == .mermaid ? "Mermaid" : "LaTeX" }

    private var header: some View {
        HStack(spacing: 14) {
            Label(title, systemImage: kind == .mermaid ? "point.3.connected.trianglepath.dotted" : "function")
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(.secondary)
            if !isComplete {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            Button {
                UIPasteboard.general.string = source
                Haptics.light()
            } label: { Label("Copy source", systemImage: "doc.on.doc").font(.caption2.weight(.semibold)) }
                .tint(.conduitAccent)
            if isComplete {
                Button {
                    showsFullScreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2.weight(.semibold))
                }
                .tint(.conduitAccent)
                .accessibilityLabel(Text("Open full screen"))
            }
        }
    }

    private var drawnHeight: CGFloat? {
        if case .drawn(let height) = outcome { return height }
        return nil
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
        .frame(height: drawnHeight ?? MarkupHeights.height(for: document) ?? Self.placeholderHeight(for: kind))
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
    }

    private func failure(_ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kind == .mermaid ? AppLocalization.string("Couldn't draw this diagram.") : AppLocalization.string("Couldn't draw this formula."))
                .font(.footnote.weight(.semibold))
            if let detail, !detail.isEmpty {
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            Button {
                attempt += 1
            } label: {
                Label("Try again", systemImage: "arrow.clockwise").font(.caption.weight(.semibold))
            }
            .tint(.conduitAccent)
        }
    }

    private var sourcePreview: some View {
        SelectableTextView(
            text: source,
            font: ChatTypography.font(for: .sourceCode, chatSize: chatTextSize),
            textColor: .label,
            maximumNumberOfLines: 5
        )
    }

    private func record(_ event: MarkupWebView.Event, for key: MarkupDrawKey) {
        switch event {
        case .height(let height):
            // A page measured before it had a width reports nothing useful.
            guard height >= 1 else { return }
            MarkupHeights.store(height, for: key.document)
            let next = MarkupDrawReport(key: key, outcome: .drawn(height: height))
            if report != next { report = next }
        case .failed(let detail):
            report = MarkupDrawReport(key: key, outcome: .failed(detail))
        }
    }

    /// A page that never reports (the renderer didn't download, WebKit
    /// stalled) turns into the failure card instead of spinning forever.
    private func offerRetryIfStillDrawing() async {
        guard isComplete, outcome == nil else { return }
        let key = self.key
        try? await Task.sleep(for: Self.drawTimeout)
        guard !Task.isCancelled, report?.key != key else { return }
        report = MarkupDrawReport(key: key, outcome: .failed(nil))
    }
}

struct MarkupDrawKey: Hashable {
    let document: MarkupDocument
    let attempt: Int
}

private struct MarkupDrawTask: Hashable {
    let key: MarkupDrawKey
    let isComplete: Bool
}

/// What a block's page last reported, and for which page.
struct MarkupDrawReport: Equatable {
    enum Outcome: Equatable {
        case drawn(height: CGFloat)
        /// The renderer's own message, when it gave one.
        case failed(String?)
    }

    let key: MarkupDrawKey
    let outcome: Outcome
}

/// Measured heights by document. The chat list rebuilds a row it scrolls
/// back to, and its diagram reserves its real height instead of growing
/// from the placeholder while it redraws. Keyed by the document's hash so
/// the cache holds no sources; a collision only misplaces a placeholder,
/// which the page's own report corrects.
@MainActor
enum MarkupHeights {
    private static var heights: [Int: CGFloat] = [:]
    private static let limit = 256

    static func height(for document: MarkupDocument) -> CGFloat? {
        heights[document.hashValue]
    }

    static func store(_ height: CGFloat, for document: MarkupDocument) {
        let key = document.hashValue
        if heights[key] == nil, heights.count >= limit {
            // Drop half rather than all, so a long session doesn't lose
            // every height at once.
            for stale in Array(heights.keys.prefix(limit / 2)) {
                heights[stale] = nil
            }
        }
        heights[key] = height
    }
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

        /// Loads the page once per document; SwiftUI calls this on every
        /// update, which during a stream is every frame.
        func load(_ document: MarkupDocument, into view: WKWebView) {
            guard document != loaded else { return }
            loaded = document
            html = MarkupHTML.page(document, presentation: .inline)
            view.loadHTMLString(html, baseURL: MarkupHTML.baseURL)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            if let height = body["height"] as? Double {
                onEvent?(.height(CGFloat(height)))
            } else if let detail = body["failed"] as? String {
                onEvent?(.failed(detail.isEmpty ? nil : detail))
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // WebKit can end an off-screen page's process under memory
            // pressure, which leaves the block blank until it reloads.
            guard !html.isEmpty else { return }
            webView.loadHTMLString(html, baseURL: MarkupHTML.baseURL)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(MarkupHTML.allowsNavigation(to: navigationAction.request.url) ? .allow : .cancel)
        }
    }
}

/// WebKit keeps its message handlers for the configuration's lifetime; the
/// proxy holds the page's coordinator weakly so the two don't keep each
/// other alive.
@MainActor
private final class MarkupMessageProxy: NSObject, WKScriptMessageHandler {
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
                        font: ChatTypography.font(for: .sourceCode, chatSize: chatTextSize),
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
        .presentationDetents([.medium, .large])
    }
}

private struct SafeMarkupWebView: UIViewRepresentable {
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

    func updateUIView(_ view: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(html: html) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let html: String

        init(html: String) {
            self.html = html
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // Same as the inline page: reload rather than stay blank.
            webView.loadHTMLString(html, baseURL: MarkupHTML.baseURL)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
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

    /// The page itself and the renderer's CDN; anything else (a link in a
    /// diagram, a javascript:, data: or file: URL) stays out.
    static func allowsNavigation(to url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" { return url.absoluteString.lowercased() == "about:blank" }
        guard scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "conduit.local" || host == "cdn.jsdelivr.net"
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
        <script src="https://cdn.jsdelivr.net/npm/mermaid@11.16.0/dist/mermaid.min.js"></script>
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
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.22/dist/katex.min.css">
        <style>html,body{margin:0;padding:0;background:\(background);color:\(palette.foreground)}body{font-size:\(fontSize)}\(contentStyle).error{font:14px -apple-system,sans-serif;color:#d14b4b;white-space:pre-wrap}</style>
        </head><body><div id="content"></div>
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.22/dist/katex.min.js"></script>
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
