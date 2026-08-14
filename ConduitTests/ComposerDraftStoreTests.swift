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

    func testFailedSubmissionDoesNotClobberNewerSavedDraftForOriginalKey() {
        let store = ComposerDraftStore(capacity: 12)
        let key = ComposerBar.composerDraftKey(for: "session-a", profile: "default")
        let originalSubmittedDraft = ComposerDraft(text: "old submitted draft", attachments: [])
        let newerDraft = ComposerDraft(text: "newer saved draft", attachments: [
            Attachment(
                id: "newer-attachment",
                name: "newer.png",
                uri: "file:///tmp/newer.png",
                mimeType: "image/png",
                kind: .image
            )
        ])

        store.save(newerDraft, for: key)

        store.saveIfMissing(originalSubmittedDraft, for: key)

        XCTAssertEqual(store.draft(for: key), newerDraft)
    }

    func testSuccessfulSubmissionRemovesOnlyUnchangedSubmittedDraft() {
        let store = ComposerDraftStore(capacity: 12)
        let key = ComposerBar.composerDraftKey(for: "session-a", profile: "default")
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
        let key = ComposerBar.composerDraftKey(for: "session-a", profile: "default")
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
            profile: "default"
        )
        let runtimeKey = ComposerBar.composerDraftKey(
            for: "runtime-session",
            profile: "default"
        )
        let unrelatedKey = ComposerBar.composerDraftKey(
            for: "other-session",
            profile: "default"
        )

        XCTAssertTrue(ComposerBar.draftKeysAreEquivalent(storedKey, runtimeKey, identity: identity))
        XCTAssertFalse(ComposerBar.draftKeysAreEquivalent(storedKey, unrelatedKey, identity: identity))
    }

    func testDraftMigrationPreservesTextAndAttachmentsAcrossRuntimeAlias() {
        let store = ComposerDraftStore(capacity: 12)
        let runtimeKey = ComposerBar.composerDraftKey(
            for: "runtime-session",
            profile: "default"
        )
        let storedKey = ComposerBar.composerDraftKey(
            for: "stored-session",
            profile: "default"
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
        let originKey = ComposerBar.composerDraftKey(for: "session-a", profile: "default")
        let destinationKey = ComposerBar.composerDraftKey(for: "session-b", profile: "default")
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
        let key = ComposerBar.composerDraftKey(for: "session-a", profile: "default")
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
        let sessionA = ComposerBar.composerDraftKey(for: "session-a", profile: "default")
        let sessionB = ComposerBar.composerDraftKey(for: "session-b", profile: "default")
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
        let sessionA = ComposerBar.composerDraftKey(for: "session-a", profile: "default")
        let sessionB = ComposerBar.composerDraftKey(for: "session-b", profile: "default")
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
        let originKey = ComposerBar.composerDraftKey(for: "session-a", profile: "default")
        let sameSessionOtherProfileKey = ComposerBar.composerDraftKey(for: "session-a", profile: "work")
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
        let sessionA = ComposerBar.composerDraftKey(for: "session-a", profile: "default")
        let sessionB = ComposerBar.composerDraftKey(for: "session-b", profile: "default")
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
        let defaultKey = ComposerBar.composerDraftKey(for: "same-session", profile: "default")
        let workKey = ComposerBar.composerDraftKey(for: "same-session", profile: "work")

        XCTAssertEqual(defaultKey, ComposerDraftKey(profile: "default", sessionID: "same-session"))
        XCTAssertEqual(workKey, ComposerDraftKey(profile: "work", sessionID: "same-session"))
        XCTAssertNotEqual(defaultKey, workKey)
    }

    func testDraftsAreIsolatedByProfileAndSession() {
        let store = ComposerDraftStore(capacity: 12)
        let first = ComposerDraftKey(profile: "default", sessionID: "one")
        let second = ComposerDraftKey(profile: "default", sessionID: "two")
        let otherProfile = ComposerDraftKey(profile: "work", sessionID: "one")
        let draft = ComposerDraft(text: "draft one", attachments: [])

        store.save(draft, for: first)

        XCTAssertEqual(store.draft(for: first), draft)
        XCTAssertEqual(store.draft(for: second), ComposerDraft.empty)
        XCTAssertEqual(store.draft(for: otherProfile), ComposerDraft.empty)
    }

    func testSavingEmptyDraftRemovesTheBucket() {
        let store = ComposerDraftStore()
        let key = ComposerDraftKey(profile: "default", sessionID: "one")
        store.save(ComposerDraft(text: "text", attachments: []), for: key)
        store.save(.empty, for: key)

        XCTAssertEqual(store.draft(for: key), .empty)
    }

    func testStoreEvictsTheOldestBucketWhenCapacityIsExceeded() {
        let store = ComposerDraftStore(capacity: 1)
        let first = ComposerDraftKey(profile: "default", sessionID: "one")
        let second = ComposerDraftKey(profile: "default", sessionID: "two")
        store.save(ComposerDraft(text: "one", attachments: []), for: first)
        store.save(ComposerDraft(text: "two", attachments: []), for: second)

        XCTAssertEqual(store.draft(for: first), .empty)
        XCTAssertEqual(store.draft(for: second).text, "two")
    }

    func testGenerationMetadataDoesNotOutliveBoundedDraftBuckets() {
        let store = ComposerDraftStore(capacity: 2)

        for index in 0..<5 {
            let key = ComposerDraftKey(profile: "default", sessionID: "session-\(index)")
            store.save(ComposerDraft(text: "draft \(index)", attachments: []), for: key)
        }

        XCTAssertLessThanOrEqual(generationMetadataCount(in: store), 2)

        store.save(.empty, for: ComposerDraftKey(profile: "default", sessionID: "session-4"))
        XCTAssertLessThanOrEqual(generationMetadataCount(in: store), 1)

        for index in 0..<5 {
            let key = ComposerDraftKey(profile: "default", sessionID: "empty-\(index)")
            store.save(.empty, for: key)
        }

        XCTAssertLessThanOrEqual(generationMetadataCount(in: store), 1)

        store.removeAll()
        XCTAssertEqual(generationMetadataCount(in: store), 0)
    }

    func testEvictedGenerationBucketDoesNotDeleteNewerDraft() {
        let store = ComposerDraftStore(capacity: 1)
        let submittedKey = ComposerDraftKey(profile: "default", sessionID: "submitted")
        let otherKey = ComposerDraftKey(profile: "default", sessionID: "other")
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
