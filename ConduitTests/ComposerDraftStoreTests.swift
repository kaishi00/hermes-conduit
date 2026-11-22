import Combine
import XCTest
@testable import Conduit

@MainActor
final class ComposerDraftStoreTests: XCTestCase {
    func testProgrammaticRestoredSlashDraftKeepsSuggestionsHidden() {
        XCTAssertFalse(
            ComposerBar.shouldShowSlashSuggestions(
                for: "/status",
                isProgrammaticDraftRestore: true
            )
        )
        XCTAssertTrue(
            ComposerBar.shouldShowSlashSuggestions(
                for: "/status",
                isProgrammaticDraftRestore: false
            )
        )
    }

    func testPrefillForANewChatWaitsForThatChatsDraft() {
        let leaving = ComposerBar.composerDraftKey(for: "open-chat", profile: "default", dashboard: nil)
        let opened = ComposerBar.composerDraftKey(for: "new-chat", profile: "default", dashboard: nil)
        let identity = ChatScrollSessionIdentity(
            profile: "default",
            canonicalSessionID: "new-chat",
            equivalentSessionIDs: ["new-chat-runtime"],
            isReconciling: false,
            settledRevision: 1
        )

        // The new chat and its prefill arrive in one update: until the new
        // chat's draft is loaded, the prefill stays out of the one being left.
        XCTAssertFalse(ComposerBar.shouldApplyPrefill(for: opened, loaded: leaving, identity: identity))
        XCTAssertTrue(ComposerBar.shouldApplyPrefill(for: opened, loaded: opened, identity: identity))
        XCTAssertTrue(
            ComposerBar.shouldApplyPrefill(
                for: ComposerBar.composerDraftKey(for: "new-chat-runtime", profile: "default", dashboard: nil),
                loaded: opened,
                identity: identity
            ),
            "The same chat under its runtime id"
        )
        XCTAssertFalse(ComposerBar.shouldApplyPrefill(for: nil, loaded: opened, identity: identity), "Nothing waiting")
        XCTAssertFalse(ComposerBar.shouldApplyPrefill(for: opened, loaded: nil, identity: identity), "No draft loaded yet")
        XCTAssertFalse(
            ComposerBar.shouldApplyPrefill(
                for: opened,
                loaded: ComposerBar.composerDraftKey(for: "new-chat", profile: "work", dashboard: nil),
                identity: identity
            ),
            "Another profile's chat with the same id"
        )
    }

    func testComposerRedrawsOnlyWhenWhatItShowsChanges() {
        let suite = "ComposerDraftStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("No test defaults") }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        let updates = ComposerUpdates(appState)
        var sends = 0
        let subscription = updates.objectWillChange.sink { sends += 1 }
        defer { subscription.cancel() }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        // Hosted runners can stall the main queue past a fixed settle: wait
        // for the redraw itself, capped at 10 s, then settle once more so an
        // extra one would still show.
        func settle(until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            settle()
        }

        appState.objectWillChange.send()
        appState.objectWillChange.send()
        settle()
        XCTAssertEqual(sends, 0, "a publish that changes nothing the composer shows")

        appState.composerNotice = "Reconnecting"
        appState.activeAgents = 2
        settle(until: { sends >= 1 })
        XCTAssertEqual(sends, 1, "changes in one turn redraw it once")

        appState.showModelPicker = true
        settle(until: { sends >= 2 })
        XCTAssertEqual(sends, 2)
    }

    func testPrefillIsForTheOpenChatUntilTheComposerTakesIt() {
        let suite = "ComposerDraftStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return XCTFail("No test defaults") }
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let appState = AppState(defaults: defaults, loadSavedConnection: false)
        appState.activeSessionId = "new-chat"

        appState.prefillComposer("Set up a scheduled check")
        let token = appState.composerPrefillToken

        XCTAssertEqual(
            appState.composerPrefillDraftKey,
            ComposerBar.composerDraftKey(for: "new-chat", profile: appState.activeProfile, dashboard: appState.activeDashboardID)
        )
        appState.consumeComposerPrefill(UUID())
        XCTAssertNotNil(appState.composerPrefillDraftKey, "An older prefill's token doesn't take a newer one")
        appState.consumeComposerPrefill(token)
        XCTAssertNil(appState.composerPrefillDraftKey)
        XCTAssertEqual(appState.composerPrefillText, "Set up a scheduled check")
    }

    func testAFailedSubmissionJoinsWhatWasTypedSinceInsteadOfBeingLost() {
        let store = ComposerDraftStore(capacity: 12)
        let key = ComposerBar.composerDraftKey(for: "session-a", profile: "default", dashboard: nil)
        let reply = ComposerReplyReference(authorName: "Hermes", text: "Earlier answer")
        let submittedPhoto = Attachment(
            id: "submitted-attachment",
            name: "submitted.png",
            uri: "file:///tmp/submitted.png",
            mimeType: "image/png",
            kind: .image
        )
        let newerPhoto = Attachment(
            id: "newer-attachment",
            name: "newer.png",
            uri: "file:///tmp/newer.png",
            mimeType: "image/png",
            kind: .image
        )
        let failedSubmission = ComposerDraft(text: "old submitted draft", attachments: [submittedPhoto], replyReference: reply)
        store.save(ComposerDraft(text: "newer saved draft", attachments: [newerPhoto]), for: key)

        store.restoreFailedSubmission(failedSubmission, for: key)

        // Nothing is lost: the failed message first, then what was typed
        // since, with both photos and the reply it quoted.
        XCTAssertEqual(store.draft(for: key), ComposerDraft(
            text: "old submitted draft\n\nnewer saved draft",
            attachments: [newerPhoto, submittedPhoto],
            replyReference: reply
        ))
    }

    func testAFailedSubmissionComesBackWhole() {
        let store = ComposerDraftStore(capacity: 12)
        let key = ComposerBar.composerDraftKey(for: "session-a", profile: "default", dashboard: nil)
        let failedSubmission = ComposerDraft(text: "old submitted draft", attachments: [])

        store.restoreFailedSubmission(failedSubmission, for: key)

        XCTAssertEqual(store.draft(for: key), failedSubmission)
    }

    /// Issue 2819: a failed send on an unsaved connection came back with no
    /// owner, so the reused-id sweep couldn't send it home. With its owner
    /// it goes back to its own chat when Hermes hands the id on.
    func testAFailedSubmissionKeepsItsChatsOwner() {
        let store = ComposerDraftStore(capacity: 12)
        let runtime = ComposerBar.composerDraftKey(for: "runtime-x", profile: "default", dashboard: nil)
        let storedA = ComposerBar.composerDraftKey(for: "stored-a", profile: "default", dashboard: nil)
        store.restoreFailedSubmission(ComposerDraft(text: "For A", attachments: []), for: runtime, owner: "stored-a")
        XCTAssertEqual(store.owner(of: runtime), "stored-a")

        store.returnDraft(from: runtime, toOwner: "stored-a")
        XCTAssertFalse(store.hasDraft(for: runtime), "The chat taking runtime-x next starts empty")
        XCTAssertEqual(store.draft(for: storedA).text, "For A")
    }

    func testSuccessfulSubmissionRemovesOnlyUnchangedSubmittedDraft() {
        let store = ComposerDraftStore(capacity: 12)
        let key = ComposerBar.composerDraftKey(for: "session-a", profile: "default", dashboard: nil)
        let submittedDraft = ComposerDraft(text: "submitted draft", attachments: [
            Attachment(
                id: "submitted-attachment",
                name: "submitted.txt",
                uri: "file:///tmp/submitted.txt",
                mimeType: "text/plain",
                kind: .document
            )
        ])

        store.save(submittedDraft, for: key)
        let submittedBucket = store.submissionBucket(for: key)

        store.removeDraft(for: submittedBucket)

        XCTAssertEqual(store.draft(for: key), .empty)
    }

    func testSuccessfulSubmissionDoesNotDeleteNewerSavedDraftForOriginalKey() {
        let store = ComposerDraftStore(capacity: 12)
        let key = ComposerBar.composerDraftKey(for: "session-a", profile: "default", dashboard: nil)
        let submittedDraft = ComposerDraft(text: "submitted draft", attachments: [
            Attachment(
                id: "submitted-attachment",
                name: "submitted.txt",
                uri: "file:///tmp/submitted.txt",
                mimeType: "text/plain",
                kind: .document
            )
        ])
        let newerDraftWithSameContent = submittedDraft

        store.save(submittedDraft, for: key)
        let submittedBucket = store.submissionBucket(for: key)
        store.save(newerDraftWithSameContent, for: key)

        store.removeDraft(for: submittedBucket)

        XCTAssertEqual(store.draft(for: key), newerDraftWithSameContent)
    }

    func testConfirmedRuntimeAliasUsesOneDraftIdentity() {
        let identity = ChatScrollSessionIdentity(
            profile: "default",
            canonicalSessionID: "stored-session",
            equivalentSessionIDs: ["runtime-session"],
            isReconciling: false,
            settledRevision: 1
        )
        let storedKey = ComposerBar.composerDraftKey(
            for: "stored-session",
            profile: "default",
            dashboard: nil
        )
        let runtimeKey = ComposerBar.composerDraftKey(
            for: "runtime-session",
            profile: "default",
            dashboard: nil
        )
        let unrelatedKey = ComposerBar.composerDraftKey(
            for: "other-session",
            profile: "default",
            dashboard: nil
        )

        XCTAssertTrue(ComposerBar.draftKeysAreEquivalent(storedKey, runtimeKey, identity: identity))
        XCTAssertFalse(ComposerBar.draftKeysAreEquivalent(storedKey, unrelatedKey, identity: identity))
    }

    /// A far chat's refused words go to its stored draft from any composer;
    /// words kept in a file wait for their own dashboard (#3085 review).
    func testARestoreForAnotherDashboardIsTakenOnlyWhenItLivesInMemory() {
        let screen = UUID(), far = UUID(), other = UUID()
        let farKey = ComposerBar.composerDraftKey(for: "far-1", profile: "default", dashboard: far)
        func request(_ dashboard: UUID, key: ComposerDraftKey, share: UUID? = nil, clip: UUID? = nil) -> ComposerRestoreRequest {
            ComposerRestoreRequest(dashboardID: dashboard, key: key, draft: ComposerDraft(text: "words", attachments: []),
                                   focuses: false, pending: nil, sharedDraftID: share, dictationClipID: clip)
        }
        XCTAssertTrue(ComposerBar.handlesRestoreRequest(request(far, key: farKey), draftDashboard: screen, activeDashboard: screen),
                      "a far chat's refused words go to its stored draft")
        XCTAssertFalse(ComposerBar.handlesRestoreRequest(request(far, key: farKey, share: UUID()), draftDashboard: screen, activeDashboard: screen),
                       "a share keeps its file until its dashboard's composer")
        XCTAssertFalse(ComposerBar.handlesRestoreRequest(request(far, key: farKey, clip: UUID()), draftDashboard: screen, activeDashboard: screen),
                       "a dictation retry keeps its recording until then too")
        XCTAssertTrue(ComposerBar.handlesRestoreRequest(request(far, key: farKey, share: UUID()), draftDashboard: far, activeDashboard: screen),
                      "the far chat's own composer takes it")
        let screenKey = ComposerBar.composerDraftKey(for: "here-1", profile: "default", dashboard: screen)
        XCTAssertFalse(ComposerBar.handlesRestoreRequest(request(screen, key: screenKey, clip: UUID()), draftDashboard: far, activeDashboard: screen),
                       "the screen's filed restore waits while a far chat's draft is loaded")
        XCTAssertTrue(ComposerBar.handlesRestoreRequest(request(screen, key: screenKey), draftDashboard: far, activeDashboard: screen),
                      "its refused words still go to their stored draft")
        XCTAssertTrue(ComposerBar.handlesRestoreRequest(request(screen, key: screenKey, clip: UUID()), draftDashboard: screen, activeDashboard: screen),
                      "and its own composer takes the filed one")
        XCTAssertFalse(ComposerBar.handlesRestoreRequest(request(other, key: farKey), draftDashboard: screen, activeDashboard: screen),
                       "named for one dashboard but kept for another: left alone")
    }

    func testDraftMigrationPreservesTextAndAttachmentsAcrossRuntimeAlias() {
        let store = ComposerDraftStore(capacity: 12)
        let runtimeKey = ComposerBar.composerDraftKey(
            for: "runtime-session",
            profile: "default",
            dashboard: nil
        )
        let storedKey = ComposerBar.composerDraftKey(
            for: "stored-session",
            profile: "default",
            dashboard: nil
        )
        let draft = ComposerDraft(
            text: "keep this while Hermes rotates IDs",
            attachments: [Attachment(
                id: "attachment",
                name: "notes.txt",
                uri: "file:///tmp/notes.txt",
                mimeType: "text/plain",
                kind: .document
            )]
        )

        store.save(draft, for: runtimeKey)
        store.migrateDraft(from: runtimeKey, to: storedKey)

        XCTAssertEqual(store.draft(for: storedKey), draft)
        XCTAssertEqual(store.draft(for: runtimeKey), .empty)
    }

    func testPhotosPickerCompletionRequiresSameEditorAndDraftKey() {
        let editorIdentity = UUID()
        let originKey = ComposerBar.composerDraftKey(for: "session-a", profile: "default", dashboard: nil)
        let destinationKey = ComposerBar.composerDraftKey(for: "session-b", profile: "default", dashboard: nil)
        let origin = ComposerBar.AsyncAttachmentContext(
            editorIdentity: editorIdentity,
            draftKey: originKey,
            attachmentGeneration: 4
        )

        XCTAssertTrue(
            ComposerBar.shouldAcceptAsyncAttachmentCompletion(
                startedIn: origin,
                currentEditorIdentity: editorIdentity,
                currentDraftKey: originKey,
                currentAttachmentGeneration: 4
            )
        )
        XCTAssertFalse(
            ComposerBar.shouldAcceptAsyncAttachmentCompletion(
                startedIn: origin,
                currentEditorIdentity: UUID(),
                currentDraftKey: originKey,
                currentAttachmentGeneration: 4
            )
        )
        XCTAssertFalse(
            ComposerBar.shouldAcceptAsyncAttachmentCompletion(
                startedIn: origin,
                currentEditorIdentity: editorIdentity,
                currentDraftKey: destinationKey,
                currentAttachmentGeneration: 4
            )
        )
        XCTAssertFalse(
            ComposerBar.shouldAcceptAsyncAttachmentCompletion(
                startedIn: origin,
                currentEditorIdentity: editorIdentity,
                currentDraftKey: originKey,
                currentAttachmentGeneration: 5
            )
        )
    }

    func testLateAttachmentCompletionIsRejectedAfterSameSessionSubmission() {
        let editorIdentity = UUID()
        let key = ComposerBar.composerDraftKey(for: "session-a", profile: "default", dashboard: nil)
        let openedBeforeSubmission = ComposerBar.photoImportContext(
            editorIdentity: editorIdentity,
            draftKey: key,
            attachmentGeneration: 11
        )

        XCTAssertFalse(
            ComposerBar.shouldAcceptPhotoPickerCompletion(
                openedIn: openedBeforeSubmission,
                currentEditorIdentity: editorIdentity,
                currentDraftKey: key,
                currentAttachmentGeneration: 12
            )
        )
    }

    func testPhotosPickerCompletionUsesContextCapturedWhenPickerOpened() {
        let editorA = UUID()
        let editorB = UUID()
        let sessionA = ComposerBar.composerDraftKey(for: "session-a", profile: "default", dashboard: nil)
        let sessionB = ComposerBar.composerDraftKey(for: "session-b", profile: "default", dashboard: nil)
        let openedInA = ComposerBar.photoImportContext(
            editorIdentity: editorA,
            draftKey: sessionA,
            attachmentGeneration: 3
        )

        XCTAssertFalse(
            ComposerBar.shouldAcceptPhotoPickerCompletion(
                openedIn: openedInA,
                currentEditorIdentity: editorB,
                currentDraftKey: sessionB,
                currentAttachmentGeneration: 3
            )
        )
        XCTAssertTrue(
            ComposerBar.shouldAcceptPhotoPickerCompletion(
                openedIn: openedInA,
                currentEditorIdentity: editorA,
                currentDraftKey: sessionA,
                currentAttachmentGeneration: 3
            )
        )
    }

    func testStalePhotosPickerCompletionDoesNotClearNewerPickerContext() {
        let sessionA = ComposerBar.composerDraftKey(for: "session-a", profile: "default", dashboard: nil)
        let sessionB = ComposerBar.composerDraftKey(for: "session-b", profile: "default", dashboard: nil)
        let openedInA = ComposerBar.photoImportContext(
            editorIdentity: UUID(),
            draftKey: sessionA,
            attachmentGeneration: 1
        )
        let openedInB = ComposerBar.photoImportContext(
            editorIdentity: UUID(),
            draftKey: sessionB,
            attachmentGeneration: 2
        )

        XCTAssertFalse(
            ComposerBar.shouldClearPhotoImportContext(
                completingGeneration: 1,
                completingContext: openedInA,
                currentGeneration: 2,
                currentContext: openedInB
            )
        )
        XCTAssertTrue(
            ComposerBar.shouldClearPhotoImportContext(
                completingGeneration: 2,
                completingContext: openedInB,
                currentGeneration: 2,
                currentContext: openedInB
            )
        )
    }

    func testFileImporterCompletionRequiresSameEditorAndDraftKey() {
        let editorIdentity = UUID()
        let originKey = ComposerBar.composerDraftKey(for: "session-a", profile: "default", dashboard: nil)
        let sameSessionOtherProfileKey = ComposerBar.composerDraftKey(for: "session-a", profile: "work", dashboard: nil)
        let origin = ComposerBar.AsyncAttachmentContext(
            editorIdentity: editorIdentity,
            draftKey: originKey,
            attachmentGeneration: 8
        )

        XCTAssertTrue(
            ComposerBar.shouldAcceptAsyncAttachmentCompletion(
                startedIn: origin,
                currentEditorIdentity: editorIdentity,
                currentDraftKey: originKey,
                currentAttachmentGeneration: 8
            )
        )
        XCTAssertFalse(
            ComposerBar.shouldAcceptAsyncAttachmentCompletion(
                startedIn: origin,
                currentEditorIdentity: editorIdentity,
                currentDraftKey: sameSessionOtherProfileKey,
                currentAttachmentGeneration: 8
            )
        )
    }

    func testSessionHandoffRestoresIndependentDraftTextAndAttachments() {
        let store = ComposerDraftStore(capacity: 12)
        let sessionA = ComposerBar.composerDraftKey(for: "session-a", profile: "default", dashboard: nil)
        let sessionB = ComposerBar.composerDraftKey(for: "session-b", profile: "default", dashboard: nil)
        let attachmentA = Attachment(
            id: "attachment-a",
            name: "a.png",
            uri: "file:///tmp/a.png",
            mimeType: "image/png",
            kind: .image
        )
        let attachmentB = Attachment(
            id: "attachment-b",
            name: "b.txt",
            uri: "file:///tmp/b.txt",
            mimeType: "text/plain",
            kind: .document
        )
        let draftA = ComposerDraft(text: "draft A", attachments: [attachmentA])
        let draftB = ComposerDraft(text: "draft B", attachments: [attachmentB])

        store.save(draftA, for: sessionA)

        XCTAssertEqual(store.draft(for: sessionB), .empty)

        store.save(draftB, for: sessionB)

        XCTAssertEqual(store.draft(for: sessionA), draftA)
        XCTAssertEqual(store.draft(for: sessionB), draftB)
    }

    func testProfileSwitchUsesSeparateDraftKeyForSameSessionID() {
        let defaultKey = ComposerBar.composerDraftKey(for: "same-session", profile: "default", dashboard: nil)
        let workKey = ComposerBar.composerDraftKey(for: "same-session", profile: "work", dashboard: nil)

        XCTAssertEqual(defaultKey, ComposerDraftKey(dashboard: nil, profile: "default", sessionID: "same-session"))
        XCTAssertEqual(workKey, ComposerDraftKey(dashboard: nil, profile: "work", sessionID: "same-session"))
        XCTAssertNotEqual(defaultKey, workKey)
    }

    func testDraftsAreIsolatedByProfileAndSession() {
        let store = ComposerDraftStore(capacity: 12)
        let first = ComposerDraftKey(dashboard: nil, profile: "default", sessionID: "one")
        let second = ComposerDraftKey(dashboard: nil, profile: "default", sessionID: "two")
        let otherProfile = ComposerDraftKey(dashboard: nil, profile: "work", sessionID: "one")
        let draft = ComposerDraft(text: "draft one", attachments: [])

        store.save(draft, for: first)

        XCTAssertEqual(store.draft(for: first), draft)
        XCTAssertEqual(store.draft(for: second), ComposerDraft.empty)
        XCTAssertEqual(store.draft(for: otherProfile), ComposerDraft.empty)
    }

    func testSavingEmptyDraftRemovesTheBucket() {
        let store = ComposerDraftStore()
        let key = ComposerDraftKey(dashboard: nil, profile: "default", sessionID: "one")
        store.save(ComposerDraft(text: "text", attachments: []), for: key)
        store.save(.empty, for: key)

        XCTAssertEqual(store.draft(for: key), .empty)
    }

    func testClosingAChatKeepsTheDraftInTheFieldUnlessTheStoreWasCleared() {
        let store = ComposerDraftStore()
        let key = ComposerDraftKey(dashboard: nil, profile: "default", sessionID: "one")
        let loadedClearCount = store.clearCount

        // Back from a chat: what's in the field is kept under its draft.
        XCTAssertEqual(
            ComposerBar.draftKeyToKeep(
                loaded: key,
                loadedClearCount: loadedClearCount,
                storeClearCount: store.clearCount
            ),
            key
        )
        XCTAssertNil(
            ComposerBar.draftKeyToKeep(
                loaded: nil,
                loadedClearCount: loadedClearCount,
                storeClearCount: store.clearCount
            ),
            "Nothing loaded yet"
        )

        // A sign-out or server switch cleared the store: the composer
        // going away, or handing off to another chat, after it doesn't put
        // the draft back.
        store.removeAll()
        XCTAssertNil(
            ComposerBar.draftKeyToKeep(
                loaded: key,
                loadedClearCount: loadedClearCount,
                storeClearCount: store.clearCount
            )
        )
    }

    func testSigningOutOfADashboardNotOnScreenStopsOnlyItsWordsComingBack() {
        // #2708's review: a send from dashboard A still out when A is signed
        // out from B fails afterwards. Its words don't come back, and B's
        // composer still keeps its draft.
        let store = ComposerDraftStore()
        let a = UUID()
        let b = UUID()
        let onA = ComposerDraftKey(dashboard: a, profile: "default", sessionID: "one")
        let onB = ComposerDraftKey(dashboard: b, profile: "default", sessionID: "one")
        store.save(ComposerDraft(text: "A's words", attachments: []), for: onA)
        store.save(ComposerDraft(text: "B's words", attachments: []), for: onB)
        let sentFromA = store.clearCount(for: a)
        let loadedOnB = store.clearCount(for: b)

        store.removeDrafts(forDashboard: a)

        XCTAssertTrue(store.draft(for: onA).isEmpty)
        XCTAssertEqual(store.draft(for: onB).text, "B's words")
        XCTAssertNil(ComposerBar.draftKeyToKeep(loaded: onA, loadedClearCount: sentFromA,
                                                storeClearCount: store.clearCount(for: a)))
        XCTAssertEqual(ComposerBar.draftKeyToKeep(loaded: onB, loadedClearCount: loadedOnB,
                                                  storeClearCount: store.clearCount(for: b)), onB)
        // Dictation's Retry finishing after that sign-out asks this same
        // rule (ComposerBar.retryDictationClip), so A's words don't come back
        // from it either (issue 2744).
        // A store-wide clear still counts for every dashboard.
        store.removeAll()
        XCTAssertNil(ComposerBar.draftKeyToKeep(loaded: onB, loadedClearCount: loadedOnB,
                                                storeClearCount: store.clearCount(for: b)))
    }

    func testEachDashboardHasItsOwnDraftCap() {
        // Drafts outlive a dashboard switch (issue 2702), so one dashboard's
        // drafts never push out another's.
        let store = ComposerDraftStore(capacity: 1)
        let a = UUID()
        let b = UUID()
        let onA = ComposerDraftKey(dashboard: a, profile: "default", sessionID: "one")
        let onB = ComposerDraftKey(dashboard: b, profile: "default", sessionID: "one")
        let laterOnB = ComposerDraftKey(dashboard: b, profile: "default", sessionID: "two")
        store.save(ComposerDraft(text: "A", attachments: []), for: onA)
        store.save(ComposerDraft(text: "B", attachments: []), for: onB)
        store.save(ComposerDraft(text: "B later", attachments: []), for: laterOnB)

        XCTAssertEqual(store.draft(for: onA).text, "A")
        XCTAssertTrue(store.draft(for: onB).isEmpty, "B's oldest makes room for B's newest")
        XCTAssertEqual(store.draft(for: laterOnB).text, "B later")
    }

    func testASwitchToASavedDashboardStopsTheUnsavedServersDraftComingBack() {
        // A server with no saved dashboard's drafts go at a switch to a saved
        // one, and its leaving composer, loaded before, can't save it back.
        let store = ComposerDraftStore()
        let saved = UUID()
        let unsaved = ComposerDraftKey(dashboard: nil, profile: "default", sessionID: "one")
        let onSaved = ComposerDraftKey(dashboard: saved, profile: "default", sessionID: "one")
        store.save(ComposerDraft(text: "unsaved", attachments: []), for: unsaved)
        store.save(ComposerDraft(text: "saved", attachments: []), for: onSaved)
        let loadedUnsaved = store.clearCount(for: nil)
        let loadedSaved = store.clearCount(for: saved)

        store.removeUnsavedServerDrafts()

        XCTAssertTrue(store.draft(for: unsaved).isEmpty)
        XCTAssertNotEqual(store.clearCount(for: nil), loadedUnsaved)
        XCTAssertEqual(store.draft(for: onSaved).text, "saved")
        XCTAssertEqual(store.clearCount(for: saved), loadedSaved)
    }

    func testStoreEvictsTheOldestBucketWhenCapacityIsExceeded() {
        let store = ComposerDraftStore(capacity: 1)
        let first = ComposerDraftKey(dashboard: nil, profile: "default", sessionID: "one")
        let second = ComposerDraftKey(dashboard: nil, profile: "default", sessionID: "two")
        store.save(ComposerDraft(text: "one", attachments: []), for: first)
        store.save(ComposerDraft(text: "two", attachments: []), for: second)

        XCTAssertEqual(store.draft(for: first), .empty)
        XCTAssertEqual(store.draft(for: second).text, "two")
    }

    func testGenerationMetadataDoesNotOutliveBoundedDraftBuckets() {
        let store = ComposerDraftStore(capacity: 2)

        for index in 0..<5 {
            let key = ComposerDraftKey(dashboard: nil, profile: "default", sessionID: "session-\(index)")
            store.save(ComposerDraft(text: "draft \(index)", attachments: []), for: key)
        }

        XCTAssertLessThanOrEqual(generationMetadataCount(in: store), 2)

        store.save(.empty, for: ComposerDraftKey(dashboard: nil, profile: "default", sessionID: "session-4"))
        XCTAssertLessThanOrEqual(generationMetadataCount(in: store), 1)

        for index in 0..<5 {
            let key = ComposerDraftKey(dashboard: nil, profile: "default", sessionID: "empty-\(index)")
            store.save(.empty, for: key)
        }

        XCTAssertLessThanOrEqual(generationMetadataCount(in: store), 1)

        store.removeAll()
        XCTAssertEqual(generationMetadataCount(in: store), 0)
    }

    func testEvictedGenerationBucketDoesNotDeleteNewerDraft() {
        let store = ComposerDraftStore(capacity: 1)
        let submittedKey = ComposerDraftKey(dashboard: nil, profile: "default", sessionID: "submitted")
        let otherKey = ComposerDraftKey(dashboard: nil, profile: "default", sessionID: "other")
        let submittedDraft = ComposerDraft(text: "submitted", attachments: [])
        let newerDraft = ComposerDraft(text: "newer", attachments: [])

        store.save(submittedDraft, for: submittedKey)
        let staleBucket = store.submissionBucket(for: submittedKey)
        store.save(ComposerDraft(text: "other", attachments: []), for: otherKey)
        store.save(newerDraft, for: submittedKey)

        store.removeDraft(for: staleBucket)

        XCTAssertEqual(store.draft(for: submittedKey), newerDraft)
    }

    private func generationMetadataCount(in store: ComposerDraftStore) -> Int {
        let storeMirror = Mirror(reflecting: store)
        guard let generations = storeMirror.children.first(where: { $0.label == "generations" })?.value else {
            XCTFail("ComposerDraftStore should expose generation metadata for this bounded-capacity regression")
            return Int.max
        }
        let generationsMirror = Mirror(reflecting: generations)
        XCTAssertEqual(generationsMirror.displayStyle, .dictionary)
        return generationsMirror.children.count
    }
}
