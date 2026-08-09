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

    func testSuccessfulRenameUpdatesEveryIdentityProjection() async throws {
        let session = makeSession()
        let operationResult = try await SessionRenameOperation.perform(
            session: session,
            activeSessionID: "runtime-id",
            title: "Renamed",
            operations: .init(
                renameRuntime: { sessionID, _ in
                    XCTAssertEqual(sessionID, "runtime-id")
                },
                renameStored: { _, _ in XCTFail("Active rename must use the runtime RPC") }
            )
        )
        let result = try XCTUnwrap(operationResult)

        let storedEntry = result.updating(session)
        let runtimeEntry = result.updating(makeSession(
            id: "runtime-id",
            alternateIDs: ["stored-id"],
            title: "Old runtime title"
        ))
        let archivedEntry = result.updating(makeSession(
            id: "archived-id",
            alternateIDs: ["runtime-id"],
            title: "Old archived title"
        ))
        let unrelatedEntry = result.updating(makeSession(id: "unrelated", alternateIDs: []))

        XCTAssertEqual(storedEntry.title, "Renamed")
        XCTAssertEqual(runtimeEntry.title, "Renamed")
        XCTAssertEqual(archivedEntry.title, "Renamed")
        XCTAssertTrue(result.matches(sessionID: "runtime-id"), "The active title must receive the rename")
        XCTAssertEqual(unrelatedEntry.title, "Original")
    }

    func testContextChangeDoesNotFallBackToStoredSession() async {
        var storedRequestCount = 0

        do {
            _ = try await SessionRenameOperation.perform(
                session: makeSession(),
                activeSessionID: "runtime-id",
                title: "Renamed",
                operations: .init(
                    renameRuntime: { _, _ in throw SessionRenameOperation.ContextChanged() },
                    renameStored: { _, _ in storedRequestCount += 1 }
                )
            )
            XCTFail("Expected the context change to terminate the rename")
        } catch is SessionRenameOperation.ContextChanged {
            // Expected: a stale client or profile must not mutate stored state.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(storedRequestCount, 0)
    }

    func testInactiveRenameSurvivesAppStateCatalogRefresh() async {
        var remoteCatalog: [SessionSummary] = []
        var forcedRefresh = false
        let appState = AppState(
            sessionRenameOperations: .init(
                renameRuntime: { _, _ in XCTFail("Inactive rename must not use the runtime RPC") },
                renameStored: { sessionID, title in
                    remoteCatalog = remoteCatalog.map { session in
                        guard session.id == sessionID else { return session }
                        var updated = session
                        updated.title = title
                        return updated
                    }
                }
            ),
            sessionCatalogLoader: { forceRefresh in
                forcedRefresh = forceRefresh
                return remoteCatalog
            },
            restoreSavedConnection: false
        )
        let target = makeSession(profile: appState.activeProfile)
        let active = makeSession(
            id: "active-id",
            alternateIDs: [],
            title: "Active",
            profile: appState.activeProfile
        )
        remoteCatalog = [target, active]
        appState.sessions = remoteCatalog
        appState.activeSessionId = active.id

        let didRename = await appState.renameSession(target, to: "Renamed")
        XCTAssertTrue(didRename)
        XCTAssertEqual(appState.sessions.first { $0.id == target.id }?.title, "Renamed")

        await appState.refreshSessionCatalog()

        XCTAssertTrue(forcedRefresh)
        XCTAssertEqual(appState.sessions.first { $0.id == target.id }?.title, "Renamed")
        XCTAssertEqual(appState.sessions.first { $0.id == active.id }?.title, "Active")
    }

    func testTerminalFailurePreservesAppStateAndSurfacesExistingError() async {
        let appState = AppState(
            sessionRenameOperations: .init(
                renameRuntime: { _, _ in throw TestError.rejected },
                renameStored: { _, _ in throw TestError.rejected }
            ),
            restoreSavedConnection: false
        )
        let session = makeSession(profile: appState.activeProfile)
        appState.sessions = [session]
        appState.activeSessionId = "runtime-id"
        let previousActiveTitle = appState.activeSessionTitle

        let didRename = await appState.renameSession(session, to: "Renamed")

        XCTAssertFalse(didRename)
        XCTAssertEqual(appState.sessions.map(\.title), ["Original"])
        XCTAssertEqual(appState.activeSessionTitle, previousActiveTitle)
        XCTAssertEqual(
            appState.errorMessage,
            "Could not rename this conversation: Gateway rejected rename"
        )
    }

    func testTransportCancellationRemainsAUserVisibleFailure() async {
        do {
            _ = try await SessionRenameOperation.perform(
                session: makeSession(),
                activeSessionID: nil,
                title: "Renamed",
                operations: .init(
                    renameRuntime: nil,
                    renameStored: { _, _ in throw CancellationError() }
                )
            )
            XCTFail("Expected transport cancellation to propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
            XCTAssertTrue(SessionRenameOperation.failureMessage(error).hasPrefix(
                "Could not rename this conversation:"
            ))
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

    func testStaleRecoveryCompletionCannotRemoveReplacementTask() async {
        let tracker = SessionTitleRecoveryTracker()
        let key = "research|stored-id"
        let staleToken = UUID()
        let currentToken = UUID()
        let staleTask = Task<Void, Never> {}

        tracker.register(staleTask, token: staleToken, for: key)
        tracker.cancel(key)

        let currentTask = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        tracker.register(currentTask, token: currentToken, for: key)
        tracker.finish(staleToken, for: key)

        XCTAssertTrue(tracker.hasTask(for: key))
        XCTAssertTrue(tracker.isCurrent(currentToken, for: key))

        await tracker.cancel([key])
    }

    private func makeSession(
        id: String = "stored-id",
        alternateIDs: [String] = ["runtime-id"],
        title: String = "Original",
        profile: String? = "default"
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            alternateIds: alternateIDs,
            title: title,
            model: "test-model",
            updatedLabel: "now",
            profile: profile,
            source: .chat,
            isActive: false,
            isArchived: false
        )
    }
}
