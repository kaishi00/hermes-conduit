import Foundation

enum ChatTextSelectionPolicy {
    static func allowsTextSelection(for role: MessageRole) -> Bool {
        switch role {
        case .user, .assistant, .reasoning, .system,
             .partial, .tool, .clarify, .approval:
            return true
        }
    }
}
