//
//  PhoneShortcutRunner.swift
//  Conduit
//
//  Runs a shortcut from the user's Shortcuts app that Hermes asked for, and
//  waits for what it gives back. iOS lets one app run another's shortcut
//  only by opening the Shortcuts app (its x-callback-url), and only while
//  that app is on screen, so a run takes Conduit being in front: the user's
//  tap on the card, or "Run without asking" while Conduit is open. The
//  Shortcuts app opens Conduit again when the shortcut ends, with its text
//  (`conduit://shortcut-result/done?token=…&result=…`), or says it failed or
//  was cancelled.
//

import Foundation
import UIKit

enum PhoneShortcutError: LocalizedError, Equatable {
    /// Conduit wasn't on screen, so iOS wouldn't open Shortcuts.
    case notOnScreen
    case couldNotOpen
    case failed(String?)
    case cancelled
    case noAnswer

    var errorDescription: String? {
        switch self {
        case .notOnScreen: return AppLocalization.string("Open Conduit to run this shortcut.")
        case .couldNotOpen: return AppLocalization.string("The Shortcuts app couldn't be opened.")
        case .failed(let message):
            guard let message, !message.isEmpty else { return AppLocalization.string("The shortcut stopped with an error.") }
            return AppLocalization.string("The shortcut stopped with an error: \(message)")
        case .cancelled: return AppLocalization.string("The shortcut was cancelled.")
        case .noAnswer: return AppLocalization.string("The Shortcuts app didn't say how the shortcut went.")
        }
    }
}

/// Runs a shortcut by name with optional text, returning the text it gave back.
@MainActor
protocol PhoneShortcutRunning: AnyObject {
    /// Whether a run can start now (Conduit is in front).
    var canRun: Bool { get }
    func run(name: String, input: String?) async throws -> String?
}

@MainActor
final class PhoneShortcutRunner: PhoneShortcutRunning {
    static let shared = PhoneShortcutRunner()

    /// The longest a run is waited for: a shortcut can ask the user things.
    static let timeout: TimeInterval = 10 * 60
    static let resultHost = "shortcut-result"

    private var waiting: [String: CheckedContinuation<String?, Error>] = [:]
    private let open: @MainActor (URL) async -> Bool
    private let isActive: @MainActor () -> Bool
    private let scheme: String

    init(open: @escaping @MainActor (URL) async -> Bool = { await UIApplication.shared.open($0) },
         isActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
         scheme: String = PhoneShortcutRunner.appScheme) {
        self.open = open
        self.isActive = isActive
        self.scheme = scheme
    }

    var canRun: Bool { isActive() }

    func run(name: String, input: String?) async throws -> String? {
        guard canRun else { throw PhoneShortcutError.notOnScreen }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard let url = Self.runURL(name: name, input: input, scheme: scheme, token: token) else {
            throw PhoneShortcutError.couldNotOpen
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiting[token] = continuation
            Task { @MainActor in
                guard await self.open(url) else {
                    self.finish(token: token, with: .failure(PhoneShortcutError.couldNotOpen))
                    return
                }
                try? await Task.sleep(for: .seconds(Self.timeout))
                self.finish(token: token, with: .failure(PhoneShortcutError.noAnswer))
            }
        }
    }

    /// The Shortcuts app's answer. True when `url` was one (whether or not
    /// a run still waits for it), so nothing else routes it.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == scheme.lowercased(), url.host?.lowercased() == Self.resultHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let token = value("token") else { return true }
        switch components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "done": finish(token: token, with: .success(value("result")))
        case "cancelled": finish(token: token, with: .failure(PhoneShortcutError.cancelled))
        default: finish(token: token, with: .failure(PhoneShortcutError.failed(value("errorMessage"))))
        }
        return true
    }

    private func finish(token: String, with result: Result<String?, Error>) {
        waiting.removeValue(forKey: token)?.resume(with: result)
    }

    /// `shortcuts://x-callback-url/run-shortcut`, with the text as input
    /// and the three answers coming back to this app with `token`.
    nonisolated static func runURL(name: String, input: String?, scheme: String, token: String) -> URL? {
        func callback(_ outcome: String) -> String { "\(scheme)://\(resultHost)/\(outcome)?token=\(token)" }
        var pairs = [("name", name)]
        if let input, !input.isEmpty { pairs += [("input", "text"), ("text", input)] }
        pairs += [("x-success", callback("done")), ("x-cancel", callback("cancelled")), ("x-error", callback("failed"))]
        // Every value encoded but the unreserved ASCII, so a callback's own
        // `?`, `&` and `=` reach Shortcuts whole.
        let query = pairs.compactMap { key, value in
            value.addingPercentEncoding(withAllowedCharacters: unreserved).map { "\(key)=\($0)" }
        }
        guard query.count == pairs.count else { return nil }
        return URL(string: "shortcuts://x-callback-url/run-shortcut?" + query.joined(separator: "&"))
    }

    nonisolated private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The scheme this build opens with (conduit, or conduit-dev).
    nonisolated static var appScheme: String {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let schemes = types?.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] } ?? []
        return schemes.first { !$0.isEmpty && !$0.hasPrefix("$(") } ?? ConduitAppLink.scheme
    }
}
