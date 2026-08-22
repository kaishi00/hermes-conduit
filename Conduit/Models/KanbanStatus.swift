import SwiftUI

/// Central presentation metadata for backend workflow statuses.
/// Unknown statuses remain renderable through the fallback metadata.
struct KanbanStatusPresentation: Equatable, Identifiable {
    let rawValue: String
    let displayName: String
    let systemImage: String
    let tint: Color
    let sortOrder: Int
    let isArchived: Bool
    var id: String { rawValue }

    static let knownStatuses: [String] = [
        "triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done", "archived"
    ]

    static func forStatus(_ rawValue: String) -> KanbanStatusPresentation {
        switch rawValue {
        case "triage": return .init(rawValue: rawValue, displayName: "Triage", systemImage: "tray", tint: .secondary, sortOrder: 0, isArchived: false)
        case "todo": return .init(rawValue: rawValue, displayName: "To Do", systemImage: "circle", tint: .secondary, sortOrder: 1, isArchived: false)
        case "scheduled": return .init(rawValue: rawValue, displayName: "Scheduled", systemImage: "clock", tint: .purple, sortOrder: 2, isArchived: false)
        case "ready": return .init(rawValue: rawValue, displayName: "Ready", systemImage: "play.circle", tint: .blue, sortOrder: 3, isArchived: false)
        case "running": return .init(rawValue: rawValue, displayName: "Running", systemImage: "arrow.triangle.2.circlepath", tint: .green, sortOrder: 4, isArchived: false)
        case "blocked": return .init(rawValue: rawValue, displayName: "Blocked", systemImage: "exclamationmark.octagon", tint: .red, sortOrder: 5, isArchived: false)
        case "review": return .init(rawValue: rawValue, displayName: "Review", systemImage: "eye", tint: .orange, sortOrder: 6, isArchived: false)
        case "done": return .init(rawValue: rawValue, displayName: "Done", systemImage: "checkmark.circle", tint: .secondary, sortOrder: 7, isArchived: false)
        case "archived": return .init(rawValue: rawValue, displayName: "Archived", systemImage: "archivebox", tint: .secondary, sortOrder: 8, isArchived: true)
        default:
            let name = rawValue.replacingOccurrences(of: "_", with: " ").capitalized
            return .init(rawValue: rawValue, displayName: name.isEmpty ? "Other" : name, systemImage: "circle.dashed", tint: .secondary, sortOrder: 100, isArchived: false)
        }
    }

    static func orderedColumns(_ columns: [KanbanColumn]) -> [KanbanColumn] {
        columns.sorted {
            let lhs = forStatus($0.name)
            let rhs = forStatus($1.name)
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}
