//
//  ProjectAcrossProfiles.swift
//  Conduit
//
//  A project's page gathers every profile's chats in the project's folder
//  (issue 1761). Hermes keeps each profile's projects in its own
//  projects.db, so the same folder is a separate project in each profile;
//  the page finds each one and merges their lanes.
//

import Foundation

/// One profile's part of a project's page.
struct ProjectProfileLanes: Equatable {
    let profile: String
    var lanes: [ProjectSessionLane]

    var sessionCount: Int { lanes.reduce(0) { $0 + $1.sessions.count } }
}

enum ProjectAcrossProfiles {
    /// Another profile's project that is the same as `project`: Home is
    /// Home (each profile's chats in no project), any other is the one
    /// with the same main folder. A folderless project matches nothing.
    static func match(_ project: ProjectSummary, in candidates: [ProjectSummary]) -> ProjectSummary? {
        if project.isHome { return candidates.first(where: \.isHome) }
        guard let folder = folderKey(project.primaryPath) else { return nil }
        return candidates.first { !$0.isHome && folderKey($0.primaryPath) == folder }
    }

    /// A folder as compared: trimmed, without a trailing slash (a Windows
    /// host's backslash too).
    static func folderKey(_ path: String?) -> String? {
        var folder = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while folder.count > 1, folder.hasSuffix("/") || folder.hasSuffix("\\") { folder.removeLast() }
        return folder.isEmpty ? nil : folder
    }

    /// The profiles that have chats here, in the order given.
    static func profilesWithChats(_ parts: [ProjectProfileLanes]) -> [String] {
        parts.filter { $0.sessionCount > 0 }.map(\.profile)
    }

    /// The page's lanes: `parts` in order (the page's own profile first),
    /// or only `filter`'s. Lanes on the same folder are one lane, at the
    /// place the first profile gave it, its chats newest first. A single
    /// profile's lanes come back as Hermes gave them.
    static func lanes(_ parts: [ProjectProfileLanes], filter: String? = nil) -> [ProjectSessionLane] {
        let shown = parts.filter { part in
            filter.map { AppState.profilesMatch($0, part.profile) } ?? true
        }
        guard shown.count > 1 else { return shown.first?.lanes ?? [] }
        var merged: [ProjectSessionLane] = []
        var indexByKey: [String: Int] = [:]
        for part in shown {
            for lane in part.lanes {
                let key = folderKey(lane.path) ?? folderKey(lane.title) ?? lane.id
                if let index = indexByKey[key] {
                    merged[index].sessions.append(contentsOf: lane.sessions)
                } else {
                    indexByKey[key] = merged.count
                    merged.append(lane)
                }
            }
        }
        return merged.map { lane in
            var lane = lane
            lane.sessions = AllProfilesChats.newestFirst(lane.sessions)
            return lane
        }
        .filter { !$0.sessions.isEmpty }
    }
}
