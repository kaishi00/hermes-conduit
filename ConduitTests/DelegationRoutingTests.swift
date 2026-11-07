//
//  DelegationRoutingTests.swift
//  ConduitTests
//
//  Settings > Memory & delegation > Subagent routing and the subagents'
//  own fallbacks: what Conduit reads from Hermes and sends back.
//

import XCTest
@testable import Conduit

final class DelegationRoutingTests: XCTestCase {
    private static let answer: [String: Any] = [
        "configured": "model_map",
        "blocked_reason": NSNull(),
        "backends": [
            ["name": "default", "label": "Default", "description": "", "available": true, "reason": "", "builtin": true],
            ["name": "model_map", "label": "Model routes", "description": "", "available": true, "reason": "", "builtin": false, "route_keys": ["daybreak"]],
            ["name": "profile_routes", "label": "Profile routes", "description": "", "available": false, "reason": "off", "builtin": false],
            ["name": "swarm", "label": "Swarm", "description": "Many at once", "available": true, "reason": "", "builtin": false],
        ],
        "model_map": [
            "options": [
                ["name": "fast", "description": "Quick lookups", "provider": "openrouter", "model": "m-fast",
                 "api_key": "sk-...abcd", "fallback_providers": [["provider": "nous", "model": "h"]], "daybreak": true],
                ["name": "deep", "description": "Hard problems", "base_url": "http://box:8000/v1", "model": "local"],
            ],
            "default": "fast",
        ],
        "profile_routes": ["profiles": [["name": "work", "description": "Office things"]], "default": "work"],
        "profiles": ["default", "work", "home"],
    ]

    func testTheRoutingReadsAsHermesSendsIt() throws {
        let routing = try XCTUnwrap(DelegationRouting(json: Self.answer))
        XCTAssertEqual(routing.configured, "model_map")
        XCTAssertNil(routing.blockedReason)
        XCTAssertEqual(routing.modelRoutes.map(\.name), ["fast", "deep"])
        XCTAssertEqual(routing.defaultModelRoute, "fast")
        XCTAssertEqual(routing.modelRoutes[1].baseURL, "http://box:8000/v1")
        XCTAssertEqual(routing.profileRoutes, [DelegationRouting.ProfileRoute(name: "work", description: "Office things")])
        XCTAssertEqual(routing.profiles, ["default", "work", "home"])
        XCTAssertTrue(routing.routesOwnSubagentModel)
        // A plugin's own mode is listed after the three, and a mode that
        // can't run isn't offered.
        XCTAssertEqual(routing.modeChoices, ["default", "model_map", "profile_routes", "swarm"])
        XCTAssertFalse(routing.isAvailable("profile_routes"))
        XCTAssertTrue(routing.isAvailable("default"))
        XCTAssertNil(DelegationRouting(json: ["model_map": [:]]))
    }

    func testASavedModeNothingRegistersStaysOnScreen() throws {
        var answer = Self.answer
        answer["configured"] = "gone"
        answer["blocked_reason"] = "No plugin provides gone."
        let routing = try XCTUnwrap(DelegationRouting(json: answer))
        XCTAssertEqual(routing.modeChoices.last, "gone")
        XCTAssertEqual(routing.blockedReason, "No plugin provides gone.")
        XCTAssertFalse(routing.isAvailable("gone"))
    }

    func testAnEditedRouteKeepsWhatTheSheetDoesntShow() throws {
        let routing = try XCTUnwrap(DelegationRouting(json: Self.answer))
        let fast = routing.modelRoutes[0]
        var draft = DelegationModelRouteDraft(route: fast)
        draft.name = "quick"
        draft.reasoningEffort = "low"
        let edited = try draft.route(taken: ["deep"], editing: fast).get()
        XCTAssertEqual(edited.name, "quick")
        XCTAssertEqual(edited.reasoningEffort, "low")
        // Hermes keeps the stored key from the preview and the route it
        // came from; fallbacks and the plugin's own keys go back as sent.
        XCTAssertEqual(edited.fields["original_name"], .string("fast"))
        XCTAssertEqual(edited.fields["api_key"], .string("sk-...abcd"))
        XCTAssertEqual(edited.fields["daybreak"], .bool(true))
        XCTAssertNotNil(edited.fields["fallback_providers"])

        // The default follows a rename.
        let next = routing.upsertingModelRoute(edited, replacing: "fast")
        XCTAssertEqual(next.modelRoutes.map(\.name), ["quick", "deep"])
        XCTAssertEqual(next.defaultModelRoute, "quick")
        let body = next.modelMapBody
        XCTAssertEqual(body["default"] as? String, "quick")
        let options = try XCTUnwrap(body["options"] as? [[String: Any]])
        XCTAssertEqual(options[0]["api_key"] as? String, "sk-...abcd")
        XCTAssertEqual(options[0]["reasoning_effort"] as? String, "low")
    }

    func testARouteNeedsANameADescriptionAProviderAndAModel() throws {
        let routing = try XCTUnwrap(DelegationRouting(json: Self.answer))
        var draft = DelegationModelRouteDraft()
        XCTAssertEqual(draft.route(taken: [], editing: nil), .failure(.name))
        draft.name = "two words"
        XCTAssertEqual(draft.route(taken: [], editing: nil), .failure(.nameSpaces))
        draft.name = "deep"
        XCTAssertEqual(draft.route(taken: ["deep"], editing: nil), .failure(.nameTaken))
        draft.name = "new"
        XCTAssertEqual(draft.route(taken: [], editing: nil), .failure(.description))
        draft.description = "Anything"
        XCTAssertEqual(draft.route(taken: [], editing: nil), .failure(.provider))
        draft.provider = "nous"
        XCTAssertEqual(draft.route(taken: [], editing: nil), .failure(.model))
        draft.model = "hermes"
        let route = try draft.route(taken: [], editing: nil).get()
        XCTAssertNil(route.fields["original_name"])
        XCTAssertNil(route.fields["reasoning_effort"], "A blank optional field isn't sent")

        // A hand-written route on an endpoint needs no provider.
        var endpoint = DelegationModelRouteDraft(route: routing.modelRoutes[1])
        endpoint.description = "Still hard problems"
        XCTAssertEqual(try endpoint.route(taken: ["fast"], editing: routing.modelRoutes[1]).get().baseURL, "http://box:8000/v1")
    }

    func testRemovingTheDefaultRouteMovesTheDefault() throws {
        let routing = try XCTUnwrap(DelegationRouting(json: Self.answer))
        let next = routing.removingModelRoute("fast")
        XCTAssertEqual(next.modelRoutes.map(\.name), ["deep"])
        XCTAssertEqual(next.defaultModelRoute, "deep")
        XCTAssertNil(next.removingModelRoute("deep").defaultModelRoute)
        XCTAssertTrue(next.removingModelRoute("deep").modelMapBody["default"] is NSNull)
        XCTAssertEqual(routing.defaultingModelRoute("deep").defaultModelRoute, "deep")
    }

    func testProfileRoutesKeepADefaultWhileAnyIsOn() throws {
        let routing = try XCTUnwrap(DelegationRouting(json: Self.answer))
        let added = routing.togglingProfileRoute("home", on: true)
        XCTAssertEqual(added.profileRoutes.map(\.name), ["work", "home"])
        XCTAssertEqual(added.defaultProfileRoute, "work")
        let removed = added.togglingProfileRoute("work", on: false)
        XCTAssertEqual(removed.defaultProfileRoute, "home")
        let described = removed.describingProfileRoute("home", "  Errands  ")
        let body = described.profileRoutesBody
        XCTAssertEqual(body["profiles"] as? [[String: String]], [["name": "home", "description": "Errands"]])
        XCTAssertEqual(body["default"] as? String, "home")
        XCTAssertEqual(described.describingProfileRoute("home", " ").profileRoutesBody["profiles"] as? [[String: String]], [["name": "home"]])
    }

    /// The section opens on the kept routing, which never holds a route's
    /// key preview: editing waits for Hermes' answer.
    func testTheKeptRoutingHasNoKey() throws {
        let kept = OfflineChatCacheStore.withoutCredentials(Self.answer)
        let routing = try XCTUnwrap(DelegationRouting(json: kept))
        XCTAssertNil(routing.modelRoutes[0].fields["api_key"])
        XCTAssertEqual(routing.modelRoutes.map(\.name), ["fast", "deep"])
        XCTAssertEqual(routing.profileRoutes.map(\.name), ["work"])
    }

    func testTheSubagentsFallbacksFollowTheChatsUntilTheyHaveTheirOwn() {
        XCTAssertTrue(ProfileFallbackChain(delegationIn: [:]).inherits)
        XCTAssertTrue(ProfileFallbackChain(delegationIn: ["delegation": ["fallback_providers": NSNull()]]).inherits)
        let none = ProfileFallbackChain(delegationIn: ["delegation": ["fallback_providers": [Any]()]])
        XCTAssertFalse(none.inherits)
        XCTAssertTrue(none.entries.isEmpty)
        let own = ProfileFallbackChain(delegationIn: ["delegation": ["fallback_providers": [["provider": "nous", "model": "h"]]]])
        XCTAssertFalse(own.inherits)
        XCTAssertEqual(own.entries.map(\.model), ["h"])
    }
}
