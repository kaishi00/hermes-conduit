import XCTest

@testable import Conduit

/// Posting in rooms other people host (designs/cross-owner-agents, C5a):
/// the room's composer in a copy posts through your own Hermes
/// (`POST /rooms/copies/messages`, notifier 0.115), and the room screen
/// says whose each message is. An extension, so no new class to plan.
extension GroupChatModelsTests {
    /// The plugin's answer once it takes posts too.
    var postsPluginReport: [String: Any] {
        ["ok": true, "version": "0.115.0", "capabilities": [
            RoomInvitesClient.capability, RoomApprovalsClient.capability,
            RoomCopiesClient.capability, RoomCopiesClient.forgetCapability, RoomPostsClient.capability,
        ]]
    }

    /// A copy opened on an AppState whose plugin takes posts.
    @MainActor
    func postsOpenCopy(_ routes: CopiesRoutes, report: [String: Any]? = nil) async throws -> AppState {
        let appState = try copiesAppState(routes)
        copiesConnect(appState)
        appState.applyNotifierPluginReport(report ?? postsPluginReport)
        await appState.refreshGroupChatSupport()
        await appState.openRoomCopy(try XCTUnwrap(appState.linkedRoomCopyRows.first))
        return appState
    }

    /// A post as `GET /rooms/copies/messages` lists it.
    func postsListed(_ eventID: String, text: String = "hello", status: String, seq: Int? = nil,
                     error: String? = nil) -> [String: Any] {
        ["event_id": eventID, "text": text, "status": status, "seq": seq.map { $0 as Any } ?? NSNull(),
         "error": error ?? NSNull(), "created_at": 1_790_000_200.0]
    }

    @MainActor
    func testACopyStillGoingTakesPostsWithThePlugin() async throws {
        // A plugin before 0.115 doesn't take posts: the room is read only.
        let older = try await postsOpenCopy(CopiesRoutes(copies: [copiesCopy()]), report: copiesPluginReport)
        XCTAssertFalse(older.activeRoomCopyTakesPosts)
        XCTAssertFalse(older.canQuoteIntoRoom())
        let sent = await older.sendGroupRoomMessage("hello")
        XCTAssertFalse(sent)

        let routes = CopiesRoutes(copies: [copiesCopy()])
        let appState = try await postsOpenCopy(routes)
        XCTAssertTrue(appState.activeRoomCopyTakesPosts)
        XCTAssertTrue(appState.canQuoteIntoRoom(), "quotes and replies go into its composer")

        // One that ended, or that your agents left, can't be posted in.
        let ended = try await postsOpenCopy(CopiesRoutes(copies: [copiesCopy(status: "ended", reason: "disbanded")]))
        XCTAssertFalse(ended.activeRoomCopyTakesPosts)
        let left = try await postsOpenCopy(CopiesRoutes(copies: [copiesCopy(status: "left", yours: [])]))
        XCTAssertFalse(left.activeRoomCopyTakesPosts)
        let leftCopy = try XCTUnwrap(left.activeRoomSurface?.copy)
        XCTAssertEqual(RoomCopyText.readOnly(for: leftCopy, canPost: true),
                       AppLocalization.string("Hosted by \("Furina"). You can read it here."))
        let unnamed = try XCTUnwrap(RoomCopiesClient.copy(copiesCopy(from: "")))
        XCTAssertEqual(RoomCopyText.readOnly(for: unnamed, canPost: true),
                       AppLocalization.string("Hosted elsewhere. You can read it here."))
        XCTAssertEqual(RoomCopyText.readOnly(for: unnamed, canPost: false),
                       AppLocalization.string("Hosted elsewhere. Update the Conduit plugin on your Hermes to post in it."))
    }

    @MainActor
    func testAPostGoesToYourHermesAndShowsSending() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy()])
        let appState = try await postsOpenCopy(routes)

        let sent = await appState.sendGroupRoomMessage("  hello  ")
        XCTAssertTrue(sent)
        let body = try XCTUnwrap(routes.postBodies.first)
        XCTAssertEqual(body["room_id"] as? String, "conduit-9")
        XCTAssertEqual(body["text"] as? String, "hello")
        let eventID = try XCTUnwrap(body["event_id"] as? String)
        XCTAssertTrue(eventID.hasPrefix("conduit-"))
        XCTAssertLessThanOrEqual(eventID.count, 64, "the plugin's event ids are at most 64")
        XCTAssertEqual(appState.pendingRoomMessage, GroupRoomOutbox.Pending(text: "hello", eventID: eventID))
        XCTAssertEqual(appState.activeRoomCopyPost?.status, .sending)
        XCTAssertFalse(appState.activeRoomSendInFlight)
        XCTAssertEqual(RoomPostText.rowState(post: appState.activeRoomCopyPost, inFlight: false), .sending)
        XCTAssertEqual(RoomPostText.rowState(post: nil, inFlight: true), .sending)

        // Another message waits for this one.
        let other = await appState.sendGroupRoomMessage("another")
        XCTAssertFalse(other)
        XCTAssertEqual(routes.postBodies.count, 1)
    }

    @MainActor
    func testAPostedPostSettlesOnceTheLogHasIt() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy(lastSeq: 3)])
        routes.events = (1...3).map { copiesEvent($0) }
        let appState = try await postsOpenCopy(routes)
        await appState.sendGroupRoomMessage("hello")
        let eventID = try XCTUnwrap(appState.pendingRoomMessage?.eventID)

        // Posted at 4, which the copy doesn't have yet: still sending.
        routes.posts = [postsListed(eventID, status: "posted", seq: 4)]
        await appState.pollActiveRoom()
        XCTAssertGreaterThan(routes.postListReads, 0, "a tick asks how a pending post stands")
        XCTAssertEqual(appState.activeRoomCopyPost?.status, .posted(seq: 4))
        XCTAssertNotNil(appState.pendingRoomMessage)
        XCTAssertEqual(RoomPostText.rowState(post: appState.activeRoomCopyPost, inFlight: false), .sending)

        // Once the log has it, the post is the room's message.
        var mine = copiesEvent(4, kind: "message.user", actor: ["kind": "user", "id": "furina"], text: "Eric: hello")
        mine["post"] = ["by": NSNull()]
        routes.events.append(mine)
        routes.copies = [copiesCopy(lastSeq: 4)]
        await appState.pollActiveRoom()
        XCTAssertNil(appState.pendingRoomMessage)
        XCTAssertNil(appState.activeRoomCopyPost)

        // Nothing pending: the ticks don't ask.
        let reads = routes.postListReads
        await appState.pollActiveRoom()
        XCTAssertEqual(routes.postListReads, reads)
    }

    @MainActor
    func testARefusedPostSaysWhyAndRetriesWithItsID() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy()])
        routes.postStatus = "refused"
        routes.postError = "unavailable"
        let appState = try await postsOpenCopy(routes)
        await appState.sendGroupRoomMessage("hello")
        let eventID = try XCTUnwrap(appState.pendingRoomMessage?.eventID)
        XCTAssertEqual(appState.activeRoomCopyPost?.status, .refused("unavailable"))
        XCTAssertEqual(
            RoomPostText.rowState(post: appState.activeRoomCopyPost, inFlight: false),
            .refused(AppLocalization.string("Not posted: the host's Hermes couldn't take it. Try again."), retry: true)
        )

        // Retry sends it again under its id.
        routes.postStatus = "sending"
        routes.postError = nil
        await appState.sendGroupRoomMessage("hello")
        XCTAssertEqual(routes.postBodies.map { $0["event_id"] as? String }, [eventID, eventID])
        XCTAssertEqual(appState.activeRoomCopyPost?.status, .sending)

        // Refusals a retry can't change offer no retry.
        for (error, words) in [
            ("ended", "Not posted: the room has ended."),
            ("not_in", "Not posted: your agents aren't in this room."),
            ("too_long", "Not posted: it's too long for this room."),
            ("bad_post", "Not posted: the host's Hermes couldn't read it."),
        ] {
            let post = RoomPost(eventID: eventID, text: "hello", status: .refused(error))
            XCTAssertEqual(RoomPostText.rowState(post: post, inFlight: false),
                           .refused(AppLocalization.string(words), retry: false), error)
        }
        let tooMany = RoomPost(eventID: eventID, text: "hello", status: .refused("too_many"))
        XCTAssertEqual(RoomPostText.rowState(post: tooMany, inFlight: false),
                       .refused(AppLocalization.string("Not posted: too many posts this hour. Try again later."), retry: true))
        let unknown = RoomPost(eventID: eventID, text: "hello", status: .refused("new_reason"))
        XCTAssertEqual(RoomPostText.rowState(post: unknown, inFlight: false),
                       .refused(AppLocalization.string("Not posted."), retry: true))

        // A request that failed may not have reached your Hermes: retried
        // under the same id, which the plugin keeps as one post.
        let failing = CopiesRoutes(copies: [copiesCopy()])
        failing.failingPosts = 1
        let other = try await postsOpenCopy(failing)
        await other.sendGroupRoomMessage("hello")
        XCTAssertNotNil(other.pendingRoomMessage)
        XCTAssertNil(other.activeRoomCopyPost)
        XCTAssertEqual(RoomPostText.rowState(post: nil, inFlight: false), .notDelivered)
        XCTAssertNotNil(other.errorMessage)
        await other.sendGroupRoomMessage("hello")
        XCTAssertEqual(failing.postBodies.count, 2)
        XCTAssertEqual(failing.postBodies[0]["event_id"] as? String, failing.postBodies[1]["event_id"] as? String)
        XCTAssertNil(other.errorMessage, "a delivered retry retires the failure")
    }

    @MainActor
    func testEditingARefusedPostHandsItsTextBack() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy()])
        routes.postStatus = "refused"
        routes.postError = "too_long"
        let appState = try await postsOpenCopy(routes)

        // Only a refused post can be taken back.
        routes.postStatus = "sending"
        routes.postError = nil
        await appState.sendGroupRoomMessage("still going")
        appState.editActiveRoomCopyPost()
        XCTAssertNotNil(appState.pendingRoomMessage)
        XCTAssertNil(appState.roomDraftHandBack)

        let refusing = CopiesRoutes(copies: [copiesCopy()])
        refusing.postStatus = "refused"
        refusing.postError = "too_long"
        let refused = try await postsOpenCopy(refusing)
        await refused.sendGroupRoomMessage("a long one")
        refused.editActiveRoomCopyPost()
        XCTAssertNil(refused.pendingRoomMessage)
        XCTAssertNil(refused.activeRoomCopyPost)
        let handBack = try XCTUnwrap(refused.roomDraftHandBack)
        XCTAssertEqual(handBack.text, "a long one")
        refused.consumeRoomDraftHandBack(handBack.id)
        XCTAssertNil(refused.roomDraftHandBack)

        // The next message is a new post.
        refusing.postStatus = "sending"
        refusing.postError = nil
        await refused.sendGroupRoomMessage("shorter")
        XCTAssertNotEqual(refusing.postBodies[0]["event_id"] as? String, refusing.postBodies[1]["event_id"] as? String)
    }

    @MainActor
    func testAPendingPostInARoomThatEndedCanBeCopiedNotEdited() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy()])
        routes.postStatus = "refused"
        routes.postError = "ended"
        let appState = try await postsOpenCopy(routes)
        await appState.sendGroupRoomMessage("bye all")
        // The room ended as it was posted: no composer to edit it in.
        routes.copies = [copiesCopy(status: "ended", reason: "disbanded")]
        await appState.pollActiveRoom()
        XCTAssertFalse(appState.activeRoomCopyTakesPosts)
        XCTAssertEqual(
            RoomPostText.rowState(post: appState.activeRoomCopyPost, inFlight: false, takesPosts: false, roomOver: true),
            .closed(AppLocalization.string("Not posted: the room has ended."))
        )
        appState.editActiveRoomCopyPost()
        XCTAssertEqual(appState.pendingRoomMessage?.text, "bye all", "Edit leaves the text where it can be copied")
        XCTAssertNil(appState.roomDraftHandBack)
        appState.dismissActiveRoomCopyPost()
        XCTAssertNil(appState.pendingRoomMessage)
        XCTAssertNil(appState.activeRoomCopyPost)

        // One that never got an answer says the room took no more; one
        // your agents left says that.
        XCTAssertEqual(RoomPostText.rowState(post: nil, inFlight: false, takesPosts: false, roomOver: true),
                       .closed(AppLocalization.string("Not posted: the room has ended.")))
        let sending = RoomPost(eventID: "conduit-1", text: "hi", status: .sending)
        XCTAssertEqual(RoomPostText.rowState(post: sending, inFlight: false, takesPosts: false),
                       .closed(AppLocalization.string("Not posted: your agents aren't in this room.")))
        XCTAssertEqual(RoomPostText.rowState(post: sending, inFlight: true, takesPosts: false), .sending)
    }

    @MainActor
    func testAPostedPostSettlesInARoomThatEnded() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy(lastSeq: 3)])
        routes.events = (1...3).map { copiesEvent($0) }
        let appState = try await postsOpenCopy(routes)
        await appState.sendGroupRoomMessage("last word")
        let eventID = try XCTUnwrap(appState.pendingRoomMessage?.eventID)
        appState.closeGroupRoom()

        // Posted at 4, but the copy ended at 3: it won't bring it.
        routes.copies = [copiesCopy(status: "ended", reason: "disbanded", lastSeq: 3)]
        routes.posts = [postsListed(eventID, text: "last word", status: "posted", seq: 4)]
        await appState.refreshGroupChatSupport()
        await appState.openRoomCopy(try XCTUnwrap(appState.linkedRoomCopyRows.first))
        XCTAssertNil(appState.pendingRoomMessage, "not left sending for good")
        XCTAssertNil(appState.activeRoomCopyPost)
    }

    @MainActor
    func testYourNameIsReadAgainWhenTheOpeningReadFailed() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy(lastSeq: 1)])
        var yours = copiesEvent(1, kind: "message.user", actor: ["kind": "user", "id": "furina"], text: "Eric: hi")
        // An empty name is yours too.
        yours["post"] = ["by": ""]
        routes.events = [yours]
        let appState = try await postsOpenCopy(routes)
        await copiesWait("the opening people read", until: { !routes.peopleReads.isEmpty })
        let first = try XCTUnwrap(appState.activeRoomReplay.events.first)
        XCTAssertEqual(appState.activeRoomPostAttribution.poster(of: first), .you)
        XCTAssertNil(appState.activeRoomPostAttribution.you)

        // The room moves on: the people are read again for your name.
        routes.people = ["ok": true, "room_id": "conduit-9", "home": "Furina", "you": "Eric", "members": [[String: Any]]()]
        routes.events.append(copiesEvent(2))
        routes.copies = [copiesCopy(lastSeq: 2)]
        await appState.pollActiveRoom()
        await copiesWait("the people read again", until: { appState.activeRoomPostAttribution.you == "Eric" })
        XCTAssertEqual(appState.activeRoomPostAttribution.text(of: first), "hi")
    }

    @MainActor
    func testAPendingPostComesBackWhenTheRoomReopens() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy()])
        let appState = try await postsOpenCopy(routes)
        await appState.sendGroupRoomMessage("hello")
        let pending = try XCTUnwrap(appState.pendingRoomMessage)

        appState.closeGroupRoom()
        XCTAssertNil(appState.pendingRoomMessage)
        // The room list read doesn't drop a copy's parked post.
        await appState.refreshGroupChatSupport()

        routes.posts = [postsListed(pending.eventID, status: "refused", error: "too_many")]
        await appState.openRoomCopy(try XCTUnwrap(appState.linkedRoomCopyRows.first))
        XCTAssertEqual(appState.pendingRoomMessage, pending)
        XCTAssertEqual(appState.activeRoomCopyPost?.status, .refused("too_many"), "read when the room opens")
    }

    @MainActor
    func testCopyEventsSayWhoPosted() async throws {
        let routes = CopiesRoutes(copies: [copiesCopy(lastSeq: 4)])
        var yours = copiesEvent(1, kind: "message.user", actor: ["kind": "user", "id": "furina"], text: "Eric: hi\nEric: all")
        yours["post"] = ["by": NSNull()]
        var mona = copiesEvent(2, kind: "message.user", actor: ["kind": "user", "id": "furina"], text: "Mona: hey")
        mona["post"] = ["by": "Mona"]
        let host = copiesEvent(3, kind: "message.user", actor: ["kind": "user", "id": "furina"], text: "Welcome")
        var monaAgain = copiesEvent(4, kind: "message.user", actor: ["kind": "user", "id": "furina"], text: "Mona: me")
        monaAgain["post"] = ["by": "Mona"]
        routes.events = [yours, mona, host, monaAgain]
        routes.people = ["ok": true, "room_id": "conduit-9", "home": "Furina", "you": "Eric", "members": [[String: Any]]()]
        let appState = try await postsOpenCopy(routes)
        await copiesWait("the people read", until: { appState.activeRoomPostAttribution.you == "Eric" })

        let events = appState.activeRoomReplay.events
        XCTAssertEqual(events.map(\.post), [GroupEventPost(by: nil), GroupEventPost(by: "Mona"), nil, GroupEventPost(by: "Mona")])
        let attribution = appState.activeRoomPostAttribution
        XCTAssertEqual(events.map { attribution.poster(of: $0) }, [.you, .person("Mona"), nil, .person("Mona")])
        XCTAssertEqual(events.map { attribution.text(of: $0) }, ["hi\nall", "hey", "Welcome", "me"])

        // A run is one speaker's only when it's the same person.
        XCTAssertFalse(GroupEventRow.sameSpeaker(events[0], events[1], attribution: attribution))
        XCTAssertFalse(GroupEventRow.sameSpeaker(events[1], events[2], attribution: attribution))
        XCTAssertFalse(GroupEventRow.sameSpeaker(events[2], events[3], attribution: attribution))
        var monaThird = events[3]
        monaThird = GroupEvent(roomID: monaThird.roomID, seq: 5, eventID: "ev-5", kind: monaThird.kind, actor: monaThird.actor,
                               authorityEpoch: 1, payload: monaThird.payload, createdAt: monaThird.createdAt,
                               post: GroupEventPost(by: "Mona"))
        XCTAssertTrue(GroupEventRow.sameSpeaker(events[3], monaThird, attribution: attribution))
        XCTAssertTrue(GroupEventRow.sameSpeaker(events[0], events[0], attribution: .none), "your own room, as before")
    }

    func testYourOwnRoomNamesLinkedPeoplesPosts() throws {
        let response: [String: Any] = [
            "ok": true, "room_id": "conduit-1", "home": NSNull(), "members": [[String: Any]](),
            "posts": [
                ["event_id": "user:aa", "seq": 4, "by": "Mona"],
                ["event_id": "user:bb", "seq": 6, "by": "Guest"],
                ["event_id": "", "seq": 7, "by": "Nobody"],
                ["event_id": "user:cc", "seq": 8, "by": NSNull()],
            ],
        ]
        XCTAssertEqual(RoomPeople.posts(response), ["user:aa": "Mona", "user:bb": "Guest"])
        XCTAssertNil(RoomPeople.you(response))
        XCTAssertEqual(RoomPeople.you(["ok": true, "you": "Eric", "members": [[String: Any]]()]), "Eric")

        let attribution = RoomPostAttribution(isCopy: false, you: nil, posts: RoomPeople.posts(response))
        func event(_ id: String, kind: String = "message.user", text: String) -> GroupEvent {
            GroupEvent(roomID: "conduit-1", seq: 1, eventID: id, kind: kind, actor: GroupActor(kind: "user", id: "eric", profile: nil, displayName: nil, connectionID: nil),
                       authorityEpoch: 1, payload: ["text": .string(text), "thread_id": .string("main")], createdAt: 0)
        }
        let monas = event("user:aa", text: "Mona: hi")
        let yours = event("user:zz", text: "Mona: not a post")
        XCTAssertEqual(attribution.poster(of: monas), .person("Mona"))
        XCTAssertEqual(attribution.text(of: monas), "hi")
        XCTAssertNil(attribution.poster(of: yours), "yours, whatever it says")
        XCTAssertEqual(attribution.text(of: yours), "Mona: not a post")
        // Even with a post's event id, a member's message is the member's.
        XCTAssertNil(attribution.poster(of: event("user:aa", kind: "message.member", text: "x")))

        // A user message the people don't name yet asks for them again.
        XCTAssertTrue(attribution.names([monas]))
        XCTAssertFalse(attribution.names([monas, yours]))
        XCTAssertTrue(attribution.names([event("m-1", kind: "message.member", text: "x")]))
        XCTAssertTrue(RoomPostAttribution(isCopy: true, you: nil, posts: [:]).names([yours]), "a copy's events say")
    }

    func testPostNamesAreTakenOffEachLine() {
        XCTAssertEqual(RoomPostText.unnamed("Mona: a\nMona: \nMona: b", name: "Mona"), "a\n\nb")
        XCTAssertEqual(RoomPostText.unnamed("Mona: a\nb", name: "Mona"), "Mona: a\nb", "only a text named on every line")
        XCTAssertEqual(RoomPostText.unnamed("Mona: a", name: nil), "Mona: a")
        XCTAssertEqual(RoomPostText.unnamed("Mona: a", name: ""), "Mona: a")
        XCTAssertEqual(RoomPostText.unnamed("Monast: a", name: "Mona"), "Monast: a")
        XCTAssertEqual(RoomPostText.unnamed("Guest: x: y", name: "Guest"), "x: y")
    }
}
