import Foundation

/// The surface Conduit presents first when returning to the app.
///
/// This is a presentation-layer preference only: it decides what the user
/// sees on top, while `ChatResumeBehavior` independently decides which
/// conversation is active underneath. Choosing `.sessions` still performs
/// the normal chat resume behind the drawer; dismissing the drawer without
/// picking another conversation reveals the restored chat.
enum ChatReturnSurface: String, CaseIterable {
    case conversation
    case sessions

    var title: String {
        switch self {
        case .conversation: "Conversation"
        case .sessions: "Sessions"
        }
    }
}
