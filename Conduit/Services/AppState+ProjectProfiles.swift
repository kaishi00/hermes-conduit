//
//  AppState+ProjectProfiles.swift
//  Conduit
//
//  A project's page gathers every profile's chats in its folder (issue
//  1761): the same folder is a separate project in each profile's
//  projects.db, read through that profile.
//

import Foundation

/// What a project page read from the other profiles: each profile's match
/// (nil when it has none, so it isn't looked for again) and their chats.
struct ProjectOtherProfilesRead: Equatable {
    var matches: [String: String?]
    var parts: [ProjectProfileLanes]
    /// The profiles whose read failed: the page keeps what it showed of
    /// them, as All does.
    var failed: Set<String> = []
}

extension AppState {
    /// The profiles a project's page gathers besides its own: the ones All
    /// lists (Show in All), with two or more profiles on the dashboard.
    func projectPageProfiles(besides owner: String) -> [String] {
        guard AllProfilesChats.isAvailable(profiles: profiles) else { return [] }
        return allProfilesIncluded.filter { !Self.profilesMatch($0, owner) }
    }

    /// A project's chats in `owner`, the profile the page opened in, which
    /// a tap on another profile's chat switches away from.
    func loadProjectSessions(_ project: ProjectSummary, inProfile owner: String) async -> ProjectSessionDetail? {
        if Self.profilesMatch(owner, activeProfile) { return await loadProjectSessions(project) }
        guard let client, supportsProjects else { return nil }
        let detail = try? await client.projectSessions(project.id, inProfile: owner)
        // An answer through a connection since replaced shows nothing.
        guard self.client === client else { return nil }
        return detail
    }

    /// The same project in each of `others`, and its chats there. `known`
    /// holds the matches an earlier read found, so a profile's projects are
    /// read once a page; a profile without one is looked at again on each
    /// read, as the project may have been made since, and so is one whose
    /// kept project stops answering. A profile that can't answer is left out; nil when the connection changed under the read.
    func loadProject(
        _ project: ProjectSummary,
        inProfiles others: [String],
        known: [String: String?]
    ) async -> ProjectOtherProfilesRead? {
        guard let client, supportsProjects else { return nil }
        var matches = known
        var parts: [ProjectProfileLanes] = []
        var failed: Set<String> = []
        for profile in others {
            guard !Task.isCancelled else { return nil }
            let projectID: String?
            if let kept = known[profile] ?? nil {
                projectID = kept
            } else {
                guard let listed = try? await client.projects(inProfile: profile) else {
                    failed.insert(profile)
                    continue
                }
                projectID = ProjectAcrossProfiles.match(project, in: listed)?.id
                matches[profile] = .some(projectID)
            }
            guard let projectID else { continue }
            guard let detail = try? await client.projectSessions(projectID, inProfile: profile) else {
                // A kept project that no longer answers is looked for again
                // on the next read: it may have been deleted or remade.
                matches[profile] = .some(nil)
                failed.insert(profile)
                continue
            }
            guard self.client === client else { return nil }
            let lanes = detail.lanes.compactMap { lane -> ProjectSessionLane? in
                var lane = lane
                lane.sessions = otherProfileRowsShown(lane.sessions)
                return lane.sessions.isEmpty ? nil : lane
            }
            parts.append(ProjectProfileLanes(profile: profile, lanes: lanes))
        }
        guard self.client === client, !Task.isCancelled else { return nil }
        return ProjectOtherProfilesRead(matches: matches, parts: parts, failed: failed)
    }
}
