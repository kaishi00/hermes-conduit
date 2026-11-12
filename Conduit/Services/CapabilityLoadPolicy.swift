//
//  CapabilityLoadPolicy.swift
//  Conduit
//
//  Who a capability read belongs to, and the rules that drop a read a
//  profile switch overtook. Moved out of AppState.swift (issue 828).
//

import SwiftUI
import Combine
import CryptoKit
import OSLog
import UIKit
import WebKit

/// Whose installed skills and toolsets a capability read holds: the
/// dashboard, the bridge it went through (as Capabilities' own scope) and
/// the profile.
struct CapabilitySnapshotOwner: Equatable {
    let dashboardID: UUID?
    /// Only meaningful with `dashboardID`: an identifier can be reused once
    /// its bridge is gone, which is why a dashboard switch also clears the
    /// snapshot (`retireCapabilitySnapshot`).
    let bridge: ObjectIdentifier?
    let profile: String
}

/// What a capability detail page reads for: the owner, and whether the
/// store already serves it.
struct CapabilityDetailScope: Equatable {
    let owner: CapabilitySnapshotOwner
    let ready: Bool
}

/// Pure ownership rules for capability loads, extracted for deterministic
/// testing of the rapid-profile-switch races.
enum CapabilityLoadPolicy {
    /// A finished request may commit only while it is still the newest load
    /// AND its dashboard and profile are still active (A -> B -> A stale
    /// commits rejected, and so is one from a dashboard switched away from
    /// that has a profile of the same name).
    static func canCommit(
        generation: UInt64,
        latestGeneration: UInt64,
        requested: CapabilitySnapshotOwner,
        active: CapabilitySnapshotOwner
    ) -> Bool {
        generation == latestGeneration && requested == active
    }

    /// Rows may render only when the snapshot belongs to the active
    /// dashboard and profile.
    static func shouldPresentRows(snapshot: CapabilitySnapshotOwner?, active: CapabilitySnapshotOwner) -> Bool {
        snapshot == active
    }

    /// Final rendering boundary for the Capabilities screen. Foreign or absent
    /// snapshots can never resolve to a row-bearing state - toggles must never
    /// appear under a profile they do not belong to.
    enum PresentationState: Equatable {
        case loading
        case failure(String)
        case emptySuccess
        case list(banner: String?)
    }

    static func resolvePresentation(
        snapshot: CapabilitySnapshotOwner?,
        active: CapabilitySnapshotOwner,
        isLoading: Bool,
        loadError: String?,
        hasRows: Bool
    ) -> PresentationState {
        let ownsSnapshot = shouldPresentRows(snapshot: snapshot, active: active)

        // The view's request token guarantees a settled error belongs to the
        // CURRENT request/profile - never to a foreign one. So errors surface
        // before any snapshot-ownership masking; otherwise a failed first
        // load (no snapshot yet) would hide behind an eternal spinner.
        if isLoading {
            return .loading
        }

        if let loadError {
            if ownsSnapshot && hasRows {
                return .list(banner: loadError)
            }
            return .failure(loadError)
        }

        guard ownsSnapshot else {
            // No settled result for this profile yet: never render rows that
            // belong to another profile while the current one is pending.
            return .loading
        }

        return hasRows ? .list(banner: nil) : .emptySuccess
    }
}
