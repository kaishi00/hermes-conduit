//
//  ConnectionSetupApplication.swift
//  Conduit
//
//  Round 5: the persisted-configuration effect of applying a tested
//  ConnectionSetupResult from the Settings current-connection entry.
//  Deliberately a pure plan: the policy — update the saved/login
//  configuration WITHOUT touching the active connection, never create
//  credentials that were never saved, never copy a Cloudflare service
//  token across origins — is unit-testable without Keychain, AppState, or
//  a live session. The Settings view performs the writes via perform(_:);
//  the plan itself has no side effects, so a failed experiment in the
//  wizard can never mutate anything (nothing is planned until Review
//  hands off a tested result).
//

import Foundation

struct ConnectionSetupApplication: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The dashboard URL to hand to `AppState.rememberDashboardURL`. Nil when
    /// the tested URL already equals the current one.
    let dashboardURLToRemember: String?
    /// The normalized address the plan's writes belong to — the saved
    /// dashboard whose scoped secure records this plan updates (#148).
    /// Always present, even when nothing moves, so `perform` can resolve the
    /// right dashboard without re-deriving it.
    let targetDashboardURL: String
    /// Replacement saved credentials. Non-nil only when credentials were
    /// already saved for the current connection AND the tested values differ:
    /// an explicit apply updates an existing saved configuration, it never
    /// starts persisting credentials the user chose not to save.
    let credentialsToSave: DashboardCredentials?
    /// Set only when the applied result carries no credentials, saved
    /// credentials DO exist, and the tested URL moved: the applied
    /// configuration cannot use them, and keeping them would send a stale
    /// password to the next reconnect against the new address. The live
    /// session is untouched either way. A credential-less apply to the SAME
    /// URL deliberately keeps the saved record: that shape is the interactive
    /// sign-in outcome for the current dashboard, which is not a verified
    /// replacement for the working native credentials — deleting them here
    /// would strand the still-connected configuration (Round-5 acceptance:
    /// a failed or inconclusive experiment must be harmless).
    let clearsSavedCredentials: Bool
    /// Same-origin rewrite of the inherited Cloudflare Access token to the
    /// new normalized URL string (path-only moves). A cross-origin apply
    /// never appears here: the token is neither copied to the new origin nor
    /// deleted from the old one.
    let cloudflareTokenRewrite: CloudflareAccessRewrite?

    struct CloudflareAccessRewrite: Equatable {
        let access: CloudflareAccessCredentials
        let origin: String
    }

    /// True when applying changes nothing — a successfully tested but
    /// unchanged configuration needs no writes and no confirmation.
    var isEmpty: Bool {
        dashboardURLToRemember == nil
            && credentialsToSave == nil
            && !clearsSavedCredentials
            && cloudflareTokenRewrite == nil
    }

    // Never let ordinary diagnostic interpolation disclose credentials or an
    // unvalidated URL.
    var description: String { "ConnectionSetupApplication(redacted)" }
    var debugDescription: String { description }
}

extension ConnectionSetupApplication {
    /// Plans the persisted-configuration effect of an applied wizard result.
    /// `currentDashboardURL` is the ACTIVE connection's base URL (or the last
    /// configured one when signed out); `savedCredentials` is the Keychain
    /// record for that address, and `savedCloudflareAccess` is the origin-
    /// matched token for it (both as loaded by `KeychainHelper`).
    static func plan(
        result: ConnectionSetupResult,
        currentDashboardURL: String,
        savedCredentials: DashboardCredentials?,
        savedCloudflareAccess: CloudflareAccessCredentials?
    ) -> ConnectionSetupApplication {
        // Normalize both sides before comparing so a non-canonical spelling
        // of an unchanged address can never plan a spurious rewrite.
        let newURL = (try? ConnectionURLPolicy.normalizedBaseURL(result.serverURL))
            ?? result.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentURL = (try? ConnectionURLPolicy.normalizedBaseURL(currentDashboardURL))
            ?? currentDashboardURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlChanged = newURL != currentURL

        let hasResultCredentials =
            !result.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !result.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var credentialsToSave: DashboardCredentials?
        var clearsSavedCredentials = false
        if let saved = savedCredentials {
            if hasResultCredentials {
                let replacement = DashboardCredentials(
                    baseURL: newURL,
                    username: result.username,
                    password: result.password,
                    requiresFaceID: saved.requiresFaceID
                )
                credentialsToSave = replacement != saved ? replacement : nil
            } else if urlChanged {
                clearsSavedCredentials = true
            }
        }

        var rewrite: CloudflareAccessRewrite?
        if let access = savedCloudflareAccess, access.isConfigured,
           LoginCloudflareHandoff.sameOrigin(currentURL, newURL) {
            let currentOrigin = (try? ConnectionURLPolicy.normalizedBaseURL(currentURL)) ?? currentURL
            let newOrigin = (try? ConnectionURLPolicy.normalizedBaseURL(newURL)) ?? newURL
            if newOrigin != currentOrigin {
                rewrite = CloudflareAccessRewrite(access: access, origin: newOrigin)
            }
        }

        return ConnectionSetupApplication(
            dashboardURLToRemember: urlChanged ? newURL : nil,
            targetDashboardURL: newURL,
            credentialsToSave: credentialsToSave,
            clearsSavedCredentials: clearsSavedCredentials,
            cloudflareTokenRewrite: rewrite
        )
    }

    /// Performs the plan's writes. The live connection — AppState's
    /// `connection`, `client`, session, and chat state — is never touched:
    /// only the saved/login configuration moves, so the current session keeps
    /// running and the new settings take effect on the next explicit
    /// reconnect (an app relaunch, or signing in again). Every write is
    /// scoped to the saved dashboard the plan's target address belongs to
    /// (registering the entry when new); the active selection never moves.
    @MainActor
    func perform(appState: AppState) {
        if let dashboardID = appState.resolveDashboardID(forURL: targetDashboardURL, registerIfMissing: true) {
            if let credentials = credentialsToSave {
                KeychainHelper.saveCredentials(credentials, dashboardID: dashboardID)
            }
            if clearsSavedCredentials {
                KeychainHelper.clearCredentials(dashboardID: dashboardID)
            }
            if let rewrite = cloudflareTokenRewrite {
                KeychainHelper.saveCloudflareAccess(rewrite.access, origin: rewrite.origin, dashboardID: dashboardID)
            }
        }
        if let url = dashboardURLToRemember { appState.rememberDashboardURL(url) }
    }
}

/// Picks the saved credentials that may seed the Settings wizard for a
/// dashboard address. Only a record saved for exactly this normalized URL
/// qualifies — credentials for another server never leak into the draft — and
/// a Face ID-protected record surrenders its username only: reusing the saved
/// password must never bypass the biometric gate that saved it, so the wizard
/// asks for that password again.
enum ConnectionSetupSeeding {
    static func wizardCredentials(
        for dashboardURL: String,
        saved: DashboardCredentials?
    ) -> (username: String, password: String)? {
        guard let saved else { return nil }
        // Both sides compare policy-normalized, so a trailing-slash or
        // default-port spelling of the same address still seeds. Anything
        // that fails normalization compares trimmed-raw (fail closed).
        let wanted = (try? ConnectionURLPolicy.normalizedBaseURL(dashboardURL))
            ?? dashboardURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = (try? ConnectionURLPolicy.normalizedBaseURL(saved.baseURL))
            ?? saved.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stored == wanted else { return nil }
        return (saved.username, saved.requiresFaceID ? "" : saved.password)
    }
}
