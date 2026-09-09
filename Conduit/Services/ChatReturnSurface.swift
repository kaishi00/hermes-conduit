import Foundation

/// The surface Conduit presents first when returning to the app.
///
/// This is a presentation-layer preference only: it decides what the user
/// sees on top, while `ChatResumeBehavior` independently decides which
/// conversation is active underneath. Choosing `.sessions` (Bots view) still
/// performs the normal chat resume behind the home surface; dismissing Bots
/// without picking another conversation reveals the restored chat.
///
/// Raw values stay `conversation` / `sessions` for persistence compatibility.
/// The displayed title for `.sessions` is Bots.
enum ChatReturnSurface: String, CaseIterable, Hashable {
    case conversation
    case sessions

    var title: String {
        switch self {
        case .conversation: "Conversation"
        case .sessions: "Bots"
        }
    }
}
