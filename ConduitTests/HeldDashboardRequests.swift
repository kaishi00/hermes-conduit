//
//  HeldDashboardRequests.swift
//  ConduitTests
//
//  A dashboard bridge whose requests wait for the test to answer them. They
//  go out the way they do while the phone app is in the background (without
//  the page, #378), which is the one path that doesn't depend on WebKit's
//  nondeterministic page callbacks in the test host.
//

import Foundation
import XCTest
@testable import Conduit

@MainActor
final class HeldDashboardRequests {
    struct Sent {
        let method: String
        let path: String
        var query: String? = nil
    }

    let bridge: DashboardTicketBridge
    /// Every request sent, oldest first, answered or not.
    private(set) var sent: [Sent] = []
    private var waiting: [(url: URL, continuation: CheckedContinuation<(Data, URLResponse), Error>)] = []

    init(baseURL: String, dashboardID: UUID? = nil) {
        bridge = DashboardTicketBridge(baseURL: baseURL, dashboardID: dashboardID)
        bridge.webViewCanRun = { false }
        if let host = URL(string: baseURL)?.host,
           let cookie = HTTPCookie(properties: [.name: "session", .value: "held", .domain: host, .path: "/"]) {
            bridge.backgroundIssuedCookies = [cookie]
        }
        // Weak: a request a test left running (an early read it didn't
        // take, still in its cookie lookup) can reach here after the test.
        bridge.loadWithoutPageForTesting = { [weak self] request in
            guard let self else { throw URLError(.cancelled) }
            self.sent.append(Sent(
                method: request.httpMethod ?? "GET",
                path: request.url?.path ?? "",
                query: request.url?.query
            ))
            return try await withCheckedThrowingContinuation { continuation in
                self.waiting.append((request.url ?? URL(fileURLWithPath: "/"), continuation))
            }
        }
    }

    /// Waits until `count` requests have been sent in all.
    func waitForRequests(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        // A cap, not a timing: the cookie lookup before each request can
        // wait on WebKit's store for up to 2s.
        for _ in 0..<1_000 where sent.count < count {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThanOrEqual(sent.count, count, "requests sent", file: file, line: line)
    }

    /// Answers the oldest request still waiting, once one is, or the one
    /// `at` that place among those waiting, oldest first.
    func answer(
        _ json: Any = [String: Any](),
        status: Int = 200,
        at place: Int = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<1_000 where waiting.count <= place {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard waiting.count > place else {
            XCTFail("no request is waiting for an answer there", file: file, line: line)
            return
        }
        let (url, continuation) = waiting.remove(at: place)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        continuation.resume(returning: (data, response))
    }

    /// Answers the oldest request still waiting whose path ends in
    /// `suffix`, once one is, leaving any other request waiting.
    func answer(
        _ json: Any,
        toPathEnding suffix: String,
        status: Int = 200,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<1_000 where !waiting.contains(where: { $0.url.path.hasSuffix(suffix) }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let place = waiting.firstIndex(where: { $0.url.path.hasSuffix(suffix) }) else {
            XCTFail("no request to \(suffix) is waiting for an answer", file: file, line: line)
            return
        }
        try await answer(json, status: status, at: place, file: file, line: line)
    }

    /// Fails every request still waiting, so nothing is left suspended.
    func releaseAll() {
        let held = waiting
        waiting.removeAll()
        for (_, continuation) in held {
            continuation.resume(throwing: URLError(.cancelled))
        }
    }
}
