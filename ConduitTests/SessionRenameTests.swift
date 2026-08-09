import XCTest
@testable import Conduit

@MainActor
final class SessionRenameTests: XCTestCase {
    private enum TestError: LocalizedError {
        case rejected

        var errorDescription: String? { "Gateway rejected rename" }
    }

    func testInvalidAndUnchangedTitlesDoNotIssueRequests() async throws {
        let session = makeSession(title: "Existing")
        var requestCount = 0
        let operations = SessionRenameOperation.Operations(
            renameRuntime: { _, _ in requestCount += 1 },
            renameStored: { _, _ in requestCount += 1 }
        )

        for title in ["", "   \n", "Existing", "  Existing  "] {
            let result = try await SessionRenameOperation.perform(
                session: session,
                activeSessionID: "runtime-id",
                title: title,
                operations: operations
            )
            XCTAssertNil(result)
        }
        XCTAssertEqual(requestCount, 0)
    }

    func testActiveSessionUsesRuntimeRPC() async throws {
        let session = makeSession()
        var runtimeRequest: (String, String)?
        var storedRequest: (String, String)?

        let result = try await SessionRenameOperation.perform(
            session: session,
            activeSessionID: "runtime-id",
            title: "  Renamed  ",
            operations: .init(
                renameRuntime: { runtimeRequest = ($0, $1) },
                renameStored: { storedRequest = ($0, $1) }
            )
        )

        XCTAssertEqual(runtimeRequest?.0, "runtime-id")
        XCTAssertEqual(runtimeRequest?.1, "Renamed")
        XCTAssertNil(storedRequest)
        XCTAssertEqual(result?.title, "Renamed")
    }

    func testInactiveSessionUsesStoredSessionPATCH() async throws {
        let session = makeSession()
        var runtimeRequest: (String, String)?
        var storedRequest: (String, String)?

        _ = try await SessionRenameOperation.perform(
            session: session,
            activeSessionID: "another-session",
            title: "Renamed",
            operations: .init(
                renameRuntime: { runtimeRequest = ($0, $1) },
                renameStored: { storedRequest = ($0, $1) }
            )
        )

        XCTAssertNil(runtimeRequest)
        XCTAssertEqual(storedRequest?.0, "stored-id")
        XCTAssertEqual(storedRequest?.1, "Renamed")
    }

    func testFailedRuntimeRPCFallsBackToStoredSessionPATCH() async throws {
        let session = makeSession()
        var storedRequest: (String, String)?

        let result = try await SessionRenameOperation.perform(
            session: session,
            activeSessionID: "runtime-id",
            title: "Renamed",
            operations: .init(
                renameRuntime: { _, _ in throw TestError.rejected },
                renameStored: { storedRequest = ($0, $1) }
            )
        )

        XCTAssertEqual(storedRequest?.0, "stored-id")
        XCTAssertEqual(storedRequest?.1, "Renamed")
        XCTAssertEqual(result?.title, "Renamed")
    }

    func testSuccessfulRenameUpdatesStoredRuntimeAndActiveCatalogEntries() async throws {
        let session = makeSession()
        var serverTitle = session.title
        let operationResult = try await SessionRenameOperation.perform(
            session: session,
            activeSessionID: "runtime-id",
            title: "Renamed",
            operations: .init(
                renameRuntime: { _, title in serverTitle = title },
                renameStored: { _, title in serverTitle = title }
            )
        )
        let result = try XCTUnwrap(operationResult)

        let storedEntry = result.updating(session)
        let runtimeEntry = result.updating(makeSession(
            id: "runtime-id",
            alternateIDs: ["stored-id"],
            title: "Old runtime title"
        ))
        let unrelatedEntry = result.updating(makeSession(id: "unrelated", alternateIDs: []))

        XCTAssertEqual(storedEntry.title, "Renamed")
        XCTAssertEqual(runtimeEntry.title, "Renamed")
        XCTAssertTrue(result.matches(runtimeEntry), "The active runtime alias must receive the title")
        XCTAssertEqual(unrelatedEntry.title, "Original")
        XCTAssertEqual(serverTitle, "Renamed", "The authoritative title used by a subsequent refresh must be renamed")
    }

    func testTerminalFailureLeavesExistingCatalogTitleUnchanged() async {
        let session = makeSession()

        do {
            _ = try await SessionRenameOperation.perform(
                session: session,
                activeSessionID: nil,
                title: "Renamed",
                operations: .init(
                    renameRuntime: nil,
                    renameStored: { _, _ in throw TestError.rejected }
                )
            )
            XCTFail("Expected the stored rename to fail")
        } catch {
            XCTAssertEqual(session.title, "Original")
            XCTAssertEqual(
                SessionRenameOperation.failureMessage(error),
                "Could not rename this conversation: Gateway rejected rename"
            )
        }
    }

    func testManualRenameCancelsAndInvalidatesPendingTitleRecovery() async {
        let tracker = SessionTitleRecoveryTracker()
        let key = "research|stored-id"
        let keys: Set = [key]
        let token = UUID()
        var title = "Original"
        var recoveryFinished = false

        let recovery = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            } catch {
                // Cancellation resumes the recovery so it can observe its stale token.
            }
            if tracker.isCurrent(token, for: key) {
                title = "Automatic title"
            }
            recoveryFinished = true
        }
        tracker.register(recovery, token: token, for: key)
        tracker.suppress(keys)

        await tracker.cancel(keys)
        title = "Manual title"

        XCTAssertTrue(recoveryFinished, "Manual rename must await pending recovery termination")
        XCTAssertFalse(tracker.isCurrent(token, for: key))
        XCTAssertEqual(title, "Manual title")
        XCTAssertTrue(tracker.isSuppressed(key))

        tracker.unsuppress(keys)
        XCTAssertFalse(tracker.isSuppressed(key))
    }

    private func makeSession(
        id: String = "stored-id",
        alternateIDs: [String] = ["runtime-id"],
        title: String = "Original"
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: alternateIDs,
            title: title,
            model: "test-model",
            updatedLabel: "now",
            profile: "default",
            source: .chat,
            isActive: false,
            isArchived: false
        )
    }
}
