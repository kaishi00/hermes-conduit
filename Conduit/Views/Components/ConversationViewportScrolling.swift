import SwiftUI
import UIKit

enum ConversationKeyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

extension View {
    func conversationKeyboardDismissal() -> some View {
        scrollDismissesKeyboard(.interactively)
            .onTapGesture {
                ConversationKeyboard.dismiss()
            }
    }
}

struct ScrollToLatestButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 44, height: 44)
        }
        .conduitGlassControl(cornerRadius: 22, tint: .conduitAccent.opacity(0.14))
        .accessibilityLabel("Scroll to latest message")
        .accessibilityIdentifier("chat.scroll-to-latest")
        .padding(.trailing, 18)
        .padding(.bottom, 14)
    }
}

enum ConversationViewportScrolling {
    @MainActor
    static func run(
        _ command: ChatViewportCommand,
        using proxy: ScrollViewProxy
    ) {
        ChatViewportTrace.shared.log(
            "scroll \(command.destination) gen=\(command.generation) animated=\(command.animated)"
        )
        var transaction = Transaction()
        transaction.animation = command.animated ? ConduitMotion.response : nil
        withTransaction(transaction) {
            switch command.destination {
            case .bottom(let anchorID):
                proxy.scrollTo(anchorID, anchor: .bottom)
            case .top(let anchorID, _):
                proxy.scrollTo(anchorID, anchor: .top)
            case .message(let id):
                proxy.scrollTo(id, anchor: .top)
            case .prependAnchor(let id):
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }
}
