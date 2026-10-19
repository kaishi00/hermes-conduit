import XCTest
@testable import Conduit

/// Errors logged with `privacy: .public` go through LogRedaction, so the
/// addresses inside them never reach the system log.
final class LogRedactionTests: XCTestCase {
    func testURLErrorDescriptionKeepsItsCodeAndDropsTheAddress() {
        let url = URL(string: "https://dash.example.com:9119/api/sessions?token=secret")!
        let error = URLError(.cannotConnectToHost, userInfo: [
            NSURLErrorFailingURLErrorKey: url,
            NSURLErrorFailingURLStringErrorKey: url.absoluteString,
        ])
        let text = LogRedaction.describing(error)
        XCTAssertTrue(text.contains("-1004"), text)
        XCTAssertFalse(text.contains("dash.example.com"), text)
        XCTAssertFalse(text.contains("secret"), text)
        XCTAssertTrue(text.contains("<url>"), text)
    }

    func testMessageRedactsAnAddressInTheLocalizedDescription() {
        let error = NSError(domain: "Test", code: 7, userInfo: [
            NSLocalizedDescriptionKey: "Couldn't reach ws://192.168.1.20:8765/v1/realtime, giving up",
        ])
        XCTAssertEqual(LogRedaction.message(error), "Couldn't reach <url>, giving up")
    }

    func testEverySchemeIsRedactedAndPlainTextIsKept() {
        XCTAssertEqual(
            LogRedaction.redactingURLs("a http://h/x b wss://h:1/y?z=1 c conduit://connect?url=u d"),
            "a <url> b <url> c <url> d"
        )
        XCTAssertEqual(LogRedaction.redactingURLs("The operation couldn’t be completed. (Code 3)"),
                       "The operation couldn’t be completed. (Code 3)")
    }

    func testAnAbsentErrorReadsNil() {
        let none: Error? = nil
        XCTAssertEqual(LogRedaction.describing(none), "nil")
        let some: Error? = URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://h/p"])
        XCTAssertFalse(LogRedaction.describing(some).contains("https://"))
    }

    func testPunctuationInsideAURLIsRedactedButNotAfterIt() {
        XCTAssertEqual(
            LogRedaction.redactingURLs("see https://h/api/a,b;c?token=secret (retry)."),
            "see <url> (retry)."
        )
        XCTAssertEqual(
            LogRedaction.redactingURLs("(at https://h/p). Next: http://[fe80::1%25en0]:9119/api?token=x]"),
            "(at <url>). Next: <url>]"
        )
    }

    func testUserInfoEntriesStaySeparated() {
        XCTAssertEqual(
            LogRedaction.redactingURLs("{NSErrorFailingURLStringKey=https://h/a, NSErrorFailingURLKey=https://h/a}"),
            "{NSErrorFailingURLStringKey=<url>, NSErrorFailingURLKey=<url>}"
        )
    }

    /// Static source contract: nothing named like a session id is logged
    /// .public, and every logger uses the app's one subsystem.
    func testSourcesLogSessionIdsHashedOnOneSubsystem() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ConduitTests
            .deletingLastPathComponent() // repo root
        let publicSessionID = try NSRegularExpression(
            pattern: #"(?i)session_?id[^,)\n]*, privacy: \.public\)"#
        )
        var offenders: [String] = []
        var scanned = 0
        for folder in ["Conduit", "Shared", "ConduitWatch", "ConduitNotificationService", "ConduitLocationPush"] {
            let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            while let file = enumerator?.nextObject() as? URL {
                guard file.pathExtension == "swift" else { continue }
                let source = try String(contentsOf: file, encoding: .utf8)
                scanned += 1
                let range = NSRange(source.startIndex..., in: source)
                if publicSessionID.firstMatch(in: source, range: range) != nil {
                    offenders.append("\(file.lastPathComponent): a session id logged .public")
                }
                if source.contains(#"subsystem: "com.milim.conduit""#) {
                    offenders.append("\(file.lastPathComponent): subsystem com.milim.conduit")
                }
            }
        }
        XCTAssertGreaterThan(scanned, 100, "the sources were not found from \(root.path)")
        XCTAssertEqual(offenders, [])
    }
}
