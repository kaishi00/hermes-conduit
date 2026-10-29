//
//  AuthWebPasskeyNotice.swift
//  Conduit
//
//  iOS lets an app use passkeys only for the websites its entitlement
//  names, so a passkey request from a dashboard's sign-in page (an auth
//  proxy's identity provider such as Pocket ID, Authentik, Authelia or
//  Keycloak) fails at once in the sign-in WebView, and the page shows its
//  own "canceled or timed out" error. A document-start script notices the
//  request and the sign-in sheet explains it, pointing to the page's other
//  ways to sign in.
//

import SwiftUI
import UIKit
import WebKit

/// Notices a sign-in page asking for a passkey.
///
/// Two document-start scripts, in every frame (an identity provider's page
/// can be framed):
/// - In the page's own world, the only one that sees the page's
///   `navigator.credentials`, a wrapper around `get` on the container's
///   prototype. WebKit can drop and recreate the `navigator.credentials`
///   object a few seconds after the page loads, which loses anything set on
///   the object itself. Each call goes on to the original with the same
///   arguments and `this`, and returns its promise untouched. A call whose
///   options have a `publicKey` member and aren't conditional mediation
///   (passkey autofill, which a page starts on load without the user
///   asking) first fires a DOM event on the document. Those two members are
///   all it reads; the options, the credential and the page's data are
///   never sent anywhere.
/// - In Conduit's isolated world, a listener for that event that posts a
///   fixed string to Conduit. The page world gets no message handler, so a
///   page sees no `window.webkit` it didn't have before.
///
/// The wrapper looks like the browser's method to a page that inspects it,
/// as anti-bot checks such as Cloudflare Turnstile may: the same name and
/// `length`, no `prototype`, not constructible, and `toString` gives the
/// original's `[native code]` text. That last part replaces
/// `Function.prototype.toString` with a method that answers for the
/// wrapper and for itself from a WeakMap and passes every other call to
/// the original, so other functions read as before. What still shows:
/// the extra frame in an error's stack, and the wrapper's source to the
/// `toString` of a realm the script didn't run in (for example a fresh
/// `about:blank` frame's).
///
/// The page can fire the event itself; all that does is show the notice.
/// A page that redefines `get` after document start, or calls
/// `document.open()` (which clears the document's listeners), gets no
/// notice after that; sign-in pages do neither. Only `get` is wrapped:
/// `create` registers a passkey, which isn't the sign-in this notice is
/// about.
@MainActor
enum AuthWebPasskeyDetector {
    static let messageName = "passkeyRequest"
    static let messageBody = "passkey"
    static let eventName = "conduit-passkey-request"

    static let pageScriptSource = """
    (function () {
      'use strict';
      var credentials = window.navigator && window.navigator.credentials;
      var container = credentials && Object.getPrototypeOf(credentials);
      var descriptor = container && Object.getOwnPropertyDescriptor(container, 'get');
      if (!descriptor || typeof descriptor.value !== 'function' || !descriptor.configurable) { return; }
      var original = descriptor.value;
      var root = document;
      var dispatch = EventTarget.prototype.dispatchEvent;
      var NoticeEvent = window.Event;
      var apply = Reflect.apply;
      var defineProperty = Object.defineProperty;
      var nativeToString = Function.prototype.toString;
      var toStringDescriptor = Object.getOwnPropertyDescriptor(Function.prototype, 'toString');
      var lookUp = WeakMap.prototype.get;
      var disguises = new WeakMap();
      var wrapper = {
        get(options) {
          try {
            if (options && typeof options === 'object' && options.publicKey
                && options.mediation !== 'conditional') {
              apply(dispatch, root, [new NoticeEvent('\(eventName)')]);
            }
          } catch (error) {}
          return apply(original, this, arguments);
        }
      }.get;
      var toString = {
        toString() {
          var disguise = (typeof this === 'function') ? apply(lookUp, disguises, [this]) : undefined;
          return disguise !== undefined ? disguise : apply(nativeToString, this, arguments);
        }
      }.toString;
      try {
        defineProperty(wrapper, 'length', { value: original.length });
        disguises.set(wrapper, apply(nativeToString, original, []));
        disguises.set(toString, apply(nativeToString, nativeToString, []));
        if (toStringDescriptor && toStringDescriptor.configurable) {
          toStringDescriptor.value = toString;
          defineProperty(Function.prototype, 'toString', toStringDescriptor);
        }
        descriptor.value = wrapper;
        defineProperty(container, 'get', descriptor);
      } catch (error) {}
    })();
    """

    static let listenerScriptSource = """
    (function () {
      'use strict';
      var handlers = window.webkit && window.webkit.messageHandlers;
      var handler = handlers && handlers.\(messageName);
      if (!handler) { return; }
      document.addEventListener('\(eventName)', function () {
        try { handler.postMessage('\(messageBody)'); } catch (error) {}
      });
    })();
    """

    static func install(into controller: WKUserContentController, handler: WKScriptMessageHandler) {
        controller.add(handler, contentWorld: DashboardScriptWorld.world, name: messageName)
        controller.addUserScript(
            WKUserScript(source: listenerScriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: DashboardScriptWorld.world)
        )
        controller.addUserScript(
            WKUserScript(source: pageScriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        )
    }

    static func uninstall(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: messageName, contentWorld: DashboardScriptWorld.world)
    }

    /// Whether a script message is the listener's: its name and fixed body,
    /// from Conduit's isolated world.
    static func isPasskeyRequest(name: String, worldName: String?, body: Any) -> Bool {
        name == messageName
            && worldName == DashboardScriptWorld.world.name
            && body as? String == messageBody
    }
}

extension AuthWebView {
    /// The sign-in page, with the passkey notice under it once the page
    /// asks for a passkey.
    func explainingPasskeys() -> some View {
        AuthWebPasskeySignIn(webView: self)
    }
}

/// The sign-in WebView with the notice inset at the bottom, so the page
/// stays whole above it rather than under it. The notice takes at most
/// part of the sheet, and steps aside while the keyboard is up (by then
/// the user is typing the code it suggested), coming back when it goes.
private struct AuthWebPasskeySignIn: View {
    let webView: AuthWebView
    @State private var showsNotice = false
    @State private var keyboardIsUp = false
    @State private var announcement: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            webView
                .onPasskeyRequest(showNotice)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if showsNotice, !keyboardIsUp {
                        AuthWebPasskeyNotice(maxTextHeight: proxy.size.height * 0.35, onDismiss: hideNotice)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 8)
                            .frame(maxWidth: 560)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            withAnimation(.spring(duration: 0.3)) { keyboardIsUp = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.spring(duration: 0.3)) { keyboardIsUp = false }
        }
        .onDisappear {
            announcement?.cancel()
            keyboardIsUp = false
        }
    }

    private func showNotice() {
        guard !showsNotice else { return }
        withAnimation(.spring(duration: 0.3)) { showsNotice = true }
        // After the page's own error, which VoiceOver may be reading.
        announcement?.cancel()
        announcement = Task { @MainActor in
            try? await Task.sleep(for: AuthWebPasskeyNotice.announcementDelay)
            guard !Task.isCancelled, showsNotice else { return }
            AccessibilityNotification.Announcement("\(AuthWebPasskeyNotice.title)\n\(AuthWebPasskeyNotice.message)").post()
        }
    }

    private func hideNotice() {
        guard showsNotice else { return }
        announcement?.cancel()
        withAnimation(.spring(duration: 0.3)) { showsNotice = false }
    }
}

/// Why the page's passkey failed, and what to do instead.
struct AuthWebPasskeyNotice: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    /// Past this the text scrolls, so at the largest text sizes the page
    /// keeps most of the sheet and the close button stays in reach.
    var maxTextHeight: CGFloat
    let onDismiss: () -> Void

    /// How long VoiceOver waits before reading the notice, so it comes
    /// after the page's own error.
    static let announcementDelay: Duration = .milliseconds(600)

    static var title: String { AppLocalization.string("Passkeys don't work here") }
    static var message: String {
        AppLocalization.string("iOS doesn't let apps use passkeys on a sign-in page like this one. Choose another way to sign in on this page, such as with another device or a code. You can approve that sign-in in Safari on this iPhone, where your passkeys work.")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.badge.key.fill")
                .scaledFont(.callout)
                .foregroundStyle(Color.conduitAccent)
                .padding(.top, 1)
                .accessibilityHidden(true)
            CappedHeight(maxHeight: max(maxTextHeight, 80)) {
                ScrollView { text }
                    .scrollBounceBehavior(.basedOnSize)
            }
            Button {
                Haptics.selection()
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .scaledFont(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.08), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .conduitFixedGlyph()
            }
            .buttonStyle(.plain)
            .padding(.top, -10)
            .padding(.trailing, -10)
            .accessibilityLabel(AppLocalization.string("Dismiss"))
            .accessibilityIdentifier("login.passkey-notice.dismiss")
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.conduitAccent.opacity(0.28), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("login.passkey-notice")
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: Self.title)
                .scaledFont(.callout.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: Self.message)
                .scaledFont(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .multilineTextAlignment(.leading)
    }
}

/// Its one child at its own height, up to `maxHeight`: a scroll view that
/// hugs short content and scrolls long content, sized in the same layout
/// pass rather than after a measurement.
private struct CappedHeight: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
