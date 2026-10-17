//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import KidsDomain
import KidsParentControl
@testable import KidsViewingControl
import Testing

private let server = "10000000-0000-4000-8000-000000000001"
private let child = "10000000-0000-4000-8000-000000000003"
private let device = UUID(uuidString: "10000000-0000-4000-8000-000000000004")!
private let binding = KidsBinding(serverID: server, userID: child, showsID: "shows", moviesID: "movies")
private let episode = KidsItem(id: "episode", name: "Snow", kind: .episode, libraryID: "shows", seriesID: "bear", season: 1, episode: 1)

// Semantic copy of server fixture receiver-policy-initial.json. The source bundle
// digest is recorded in docs/engineering/parents-receiver-integration.md.
private let baseJSON = #"{"birdItemID":null,"blockedEpisodeIDs":[],"blockedShowIDs":[],"childUserID":"10000000-0000-4000-8000-000000000003","commands":[],"deadline":"2026-10-17T12:02:00.000Z","deviceID":"10000000-0000-4000-8000-000000000004","finishPlaybackSessionID":null,"revision":2,"serverID":"10000000-0000-4000-8000-000000000001","serverTime":"2026-10-17T12:00:00.000Z","shuffle":{"preferUnwatched":false,"preferredShowIDs":[],"repeatCooldownDays":0},"validUntil":"2026-10-17T12:00:30.000Z","viewingAllowed":true}"#

private func policy(_ changes: [String: Any] = [:], omitting keys: [String] = []) throws -> ReceiverPolicy {
    var json = try JSONSerialization.jsonObject(with: Data(baseJSON.utf8)) as! [String: Any]
    changes.forEach { json[$0.key] = $0.value }
    keys.forEach { json.removeValue(forKey: $0) }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { value in
        let text = try value.singleValueContainer().decode(String.self)
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try #require(parser.date(from: text))
    }
    return try decoder.decode(ReceiverPolicy.self, from: JSONSerialization.data(withJSONObject: json))
}

private func lease(_ changes: [String: Any] = [:]) throws -> ViewingLease {
    var value = ViewingLease(serverID: server, childUserID: child, deviceID: device)
    try value.accept(policy(changes), requestStartedNS: 0, receivedNS: 1_000_000_000)
    return value
}

@Test
func `initial paired lease is closed and restarts cannot mint time`() {
    let value = ViewingLease(serverID: server, childUserID: child, deviceID: device)
    #expect(!value.allowsNormalViewing(at: 0))
    #expect(!value.permits(episode, binding: binding, at: 1_000_000_000))
}

@Test
func `network delay is subtracted and expiry uses monotonic time`() throws {
    var value = ViewingLease(serverID: server, childUserID: child, deviceID: device)
    try value.accept(policy(), requestStartedNS: 0, receivedNS: 10_000_000_000)
    #expect(value.allowsNormalViewing(at: 29_999_999_999))
    #expect(!value.allowsNormalViewing(at: 30_000_000_000))
    #expect(!value.allowsNormalViewing(at: 9_000_000_000))
}

@Test
func `overly long lease and cross identity are rejected`() throws {
    for change: [String: Any] in [["validUntil": "2026-10-17T12:00:31.000Z"], ["deviceID": "tvOS_\(device)"], ["childUserID": "other"]] {
        var value = ViewingLease(serverID: server, childUserID: child, deviceID: device)
        #expect(throws: (any Error).self) { try value.accept(policy(change), requestStartedNS: 0, receivedNS: 0) }
        #expect(!value.allowsNormalViewing(at: 0))
    }
}

@Test
func `stale responses cannot replace an accepted policy`() throws {
    var value = try lease()
    #expect(throws: ParentControlError.serverMismatch) { try value.accept(
        policy(["revision": 1]),
        requestStartedNS: 2_000_000_000,
        receivedNS: 3_000_000_000
    ) }
    #expect(throws: ParentControlError.serverMismatch) { try value.accept(policy(), requestStartedNS: 0, receivedNS: 3_000_000_000) }
}

private func intentPolicy(_ changes: [String: Any] = [:], omitting keys: [String] = []) throws -> ReceiverPolicy {
    var fields: [String: Any] = [
        "playbackIntentRequired": true, "playbackIntentAvailable": true,
        "playbackIntentID": "20000000-0000-4000-8000-000000000001",
        "leasePlaybackSessionID": "Prepared-Controller", "leaseItemID": episode.id
    ]
    changes.forEach { fields[$0.key] = $0.value }
    return try policy(fields, omitting: keys)
}

@Test
func `intent playback grant requires exact intent controller and item`() throws {
    var value = ViewingLease(serverID: server, childUserID: child, deviceID: device)
    try value.accept(intentPolicy(), requestStartedNS: 0, receivedNS: 1_000_000_000)
    let id = try #require(UUID(uuidString: "20000000-0000-4000-8000-000000000001"))
    #expect(value.permitsPlayback(episode, binding: binding, intentID: id, sessionID: "Prepared-Controller", at: 2_000_000_000))
    #expect(!value.permitsPlayback(episode, binding: binding, intentID: UUID(), sessionID: "Prepared-Controller", at: 2_000_000_000))
    #expect(!value.permitsPlayback(episode, binding: binding, intentID: nil, sessionID: "Prepared-Controller", at: 2_000_000_000))
    #expect(!value.permitsPlayback(episode, binding: binding, intentID: id, sessionID: "prepared-controller", at: 2_000_000_000))
    var other = episode
    other.id = "other-episode"
    #expect(!value.permitsPlayback(other, binding: binding, intentID: id, sessionID: "Prepared-Controller", at: 2_000_000_000))
    #expect(!value.permitsPlayback(episode, binding: binding, intentID: id, sessionID: "Prepared-Controller", at: 30_000_000_000))
}

@Test
func `zero viewing lease can permit fresh catalog without permitting playback`() throws {
    var value = ViewingLease(serverID: server, childUserID: child, deviceID: device)
    try value.accept(intentPolicy([
        "viewingAllowed": false, "validUntil": "2026-10-17T12:00:00.000Z",
        "playbackIntentID": NSNull(), "leasePlaybackSessionID": NSNull(), "leaseItemID": NSNull()
    ]), requestStartedNS: 0, receivedNS: 1_000_000_000)
    #expect(value.permitsBrowsing(episode, binding: binding, at: 2_000_000_000))
    #expect(!value.allowsNormalViewing(at: 2_000_000_000))
    #expect(!value.permitsPlayback(episode, binding: binding, intentID: UUID(), sessionID: "Prepared-Controller", at: 2_000_000_000))
    #expect(!value.permitsBrowsing(episode, binding: binding, at: 30_000_000_000))
    var outside = episode
    outside.libraryID = "not-kids"
    #expect(!value.permitsBrowsing(outside, binding: binding, at: 2_000_000_000))
}

@Test
func `required intent mode rejects downgrade and partial binding without replacing policy`() throws {
    var value = ViewingLease(serverID: server, childUserID: child, deviceID: device, requiresPlaybackGrants: true)
    #expect(throws: ParentControlError.malformedResponse) { try value.accept(policy(), requestStartedNS: 0, receivedNS: 0) }
    try value.accept(intentPolicy(), requestStartedNS: 0, receivedNS: 1_000_000_000)
    let accepted = value.policy
    for fields: [String: Any] in [
        ["playbackIntentRequired": false], ["playbackIntentRequired": NSNull()],
        ["playbackIntentAvailable": NSNull()], ["playbackIntentID": NSNull()],
        ["leasePlaybackSessionID": NSNull()], ["leasePlaybackSessionID": ""], ["leaseItemID": NSNull()]
    ] {
        #expect(throws: ParentControlError.malformedResponse) {
            try value.accept(intentPolicy(fields), requestStartedNS: 2_000_000_000, receivedNS: 3_000_000_000)
        }
        #expect(value.policy == accepted)
        #expect(value.requiresPlaybackGrants)
    }
}

@Test
func `explicit parent disable never erases remembered intent mode`() throws {
    var value = ViewingLease(serverID: server, childUserID: child, deviceID: device, requiresPlaybackGrants: true)
    try value.accept(intentPolicy([
        "enforcementEnabled": false, "viewingAllowed": false, "playbackIntentAvailable": false,
        "playbackIntentID": NSNull(), "leasePlaybackSessionID": NSNull(), "leaseItemID": NSNull(),
        "validUntil": "2026-10-17T12:00:00.000Z", "policyControl": ["commandID": UUID().uuidString, "kind": "release"]
    ]), requestStartedNS: 0, receivedNS: 1_000_000_000)
    #expect(value.requiresPlaybackGrants)
    #expect(!value.allowsNormalViewing(at: 2_000_000_000))
    #expect(throws: ParentControlError.malformedResponse) {
        try value.accept(policy(["enforcementEnabled": true]), requestStartedNS: 2_000_000_000, receivedNS: 3_000_000_000)
    }
}

@Test
func `missing nullable binding fields are not an explicit no-grant policy`() throws {
    let idle: [String: Any] = [
        "viewingAllowed": false, "validUntil": "2026-10-17T12:00:00.000Z",
        "playbackIntentID": NSNull(), "leasePlaybackSessionID": NSNull(), "leaseItemID": NSNull()
    ]
    for key in ["playbackIntentRequired", "playbackIntentAvailable", "playbackIntentID", "leasePlaybackSessionID", "leaseItemID"] {
        var value = ViewingLease(serverID: server, childUserID: child, deviceID: device, requiresPlaybackGrants: true)
        let missing = try intentPolicy(idle, omitting: [key])
        #expect(!missing.hasPlaybackGrantFields)
        #expect(throws: ParentControlError.malformedResponse) {
            try value.accept(missing, requestStartedNS: 0, receivedNS: 1_000_000_000)
        }
        #expect(value.policy == nil)
    }
}

@Test
func `own valid reservation permits playback even when new intent is unavailable`() throws {
    var value = ViewingLease(serverID: server, childUserID: child, deviceID: device)
    try value.accept(intentPolicy(["playbackIntentAvailable": false]), requestStartedNS: 0, receivedNS: 1_000_000_000)
    let id = try #require(value.policy?.playbackIntentID)
    #expect(value.permitsPlayback(episode, binding: binding, intentID: id, sessionID: "Prepared-Controller", at: 2_000_000_000))
    #expect(value.permitsBrowsing(episode, binding: binding, at: 2_000_000_000))
    #expect(!value.permitsPlayback(episode, binding: binding, intentID: UUID(), sessionID: "Prepared-Controller", at: 2_000_000_000))
}

@Test
func `server deadline wins before lease expiry`() throws {
    let value = try lease(["deadline": "2026-10-17T12:00:10.000Z"])
    #expect(value.allowsNormalViewing(at: 9_000_000_000))
    #expect(!value.allowsNormalViewing(at: 10_000_000_000))
}

@Test
func `deny and zero length server policy end viewing immediately`() throws {
    let value = try lease(["viewingAllowed": false, "validUntil": "2026-10-17T12:00:00.000Z"])
    #expect(!value.allowsNormalViewing(at: 1_000_000_000))
}

@Test
func `restrictions never broaden original approved library boundary`() throws {
    let value = try lease()
    #expect(value.permits(episode, binding: binding, at: 2_000_000_000))
    var other = episode
    other.libraryID = "adult"
    #expect(!value.permits(other, binding: binding, at: 2_000_000_000))
    var otherBinding = binding
    otherBinding.userID = "other"
    #expect(!value.permits(episode, binding: otherBinding, at: 2_000_000_000))
    #expect(try !lease(["blockedShowIDs": ["bear"]]).permits(episode, binding: binding, at: 2_000_000_000))
    #expect(try !lease(["blockedEpisodeIDs": ["episode"]]).permits(episode, binding: binding, at: 2_000_000_000))
    #expect(try !lease(["birdItemID": "episode"]).permits(episode, binding: binding, at: 2_000_000_000))
}

@Test
func `pairing and missing flags never activate or deactivate`() throws {
    #expect(try !ViewingLease.nextActivation(current: false, policy: policy()))
    #expect(try ViewingLease.nextActivation(current: true, policy: policy()))
    #expect(try ViewingLease.nextActivation(current: false, policy: policy(["enforcementEnabled": true])))
    #expect(try ViewingLease.nextActivation(current: true, policy: policy(["enforcementEnabled": false])))
}

@Test
func `deactivation needs explicit correlated release`() throws {
    let release: [String: Any] = ["commandID": UUID().uuidString, "kind": "release"]
    #expect(try !ViewingLease.nextActivation(current: true, policy: policy(["enforcementEnabled": false, "policyControl": release])))
    #expect(try ViewingLease.nextActivation(current: true, policy: policy(["policyControl": release])))
}

@Test
func `finish EOF does not transfer to another session`() throws {
    let id = UUID().uuidString
    let value = try lease(["finishPlaybackSessionID": id, "policyControl": ["commandID": UUID().uuidString, "kind": "finishEpisode"]])
    #expect(value.endsAtEOF(playbackSessionID: id))
    #expect(!value.endsAtEOF(playbackSessionID: UUID().uuidString))
}

@Test
func `remote commands are bound to session and expire independently`() throws {
    let id = UUID().uuidString
    let value = try lease(["commands": [[
        "commandID": UUID().uuidString,
        "action": "skip",
        "playbackSessionID": id,
        "expiresAt": "2026-10-17T12:00:05.000Z"
    ]]])
    let command = try #require(value.policy?.commands.first)
    #expect(value.mayApply(command, playbackSessionID: id, at: 4_000_000_000))
    #expect(!value.mayApply(command, playbackSessionID: id, at: 5_000_000_000))
    #expect(!value.mayApply(command, playbackSessionID: "later-session", at: 4_000_000_000))
}

@Test
func `generic holds and release cannot authorize birds`() throws {
    #expect(try lease(["birdItemID": "birds"]).ambientCommandID(latchedControlID: nil, at: 130_000_000_000) == nil)
    let id = UUID()
    let released = try lease(["birdItemID": "birds", "policyControl": ["commandID": id.uuidString, "kind": "release"]])
    #expect(released.ambientCommandID(latchedControlID: id, at: 130_000_000_000) == nil)
}

@Test
func `birds require due deadline or exact completed control`() throws {
    let id = UUID()
    let countdown = try lease(["birdItemID": "birds", "policyControl": ["commandID": id.uuidString, "kind": "countdown"]])
    #expect(countdown.ambientCommandID(latchedControlID: nil, at: 31_000_000_000) == nil)
    #expect(countdown.ambientCommandID(latchedControlID: nil, at: 120_000_000_000) == id)
    let finish = try lease(["birdItemID": "birds", "policyControl": ["commandID": id.uuidString, "kind": "finishEpisode"]])
    #expect(finish.ambientCommandID(latchedControlID: UUID(), at: 2_000_000_000) == nil)
    #expect(finish.ambientCommandID(latchedControlID: id, at: 2_000_000_000) == id)
    let absentBird = try lease(["policyControl": ["commandID": id.uuidString, "kind": "countdown"]])
    #expect(absentBird.ambientCommandID(latchedControlID: id, at: 130_000_000_000) == nil)
}

@Test
func `freshness can relax but never restrictions`() throws {
    let watched = KidsItem(id: "watched", name: "Watched", kind: .episode, libraryID: "shows", seriesID: "bear", season: 1, episode: 2)
    let forbidden = KidsItem(
        id: "forbidden",
        name: "Forbidden",
        kind: .episode,
        libraryID: "shows",
        seriesID: "bear",
        season: 1,
        episode: 3
    )
    let value = try lease([
        "blockedEpisodeIDs": ["forbidden"],
        "shuffle": ["preferUnwatched": true, "repeatCooldownDays": 7, "preferredShowIDs": []],
        "shuffleContext": ["complete": true, "watchedItemIDs": ["watched"], "recentItemIDs": ["watched", "episode"]]
    ])
    #expect(value.shuffleCandidates([watched, forbidden, episode], binding: binding, at: 2_000_000_000).map(\.id) == ["episode"])
}

@Test
func `incomplete history cannot classify unwatched or fresh items`() throws {
    let watched = KidsItem(id: "watched", name: "Watched", kind: .episode, libraryID: "shows", seriesID: "bear", season: 1, episode: 2)
    let forbidden = KidsItem(
        id: "forbidden",
        name: "Forbidden",
        kind: .episode,
        libraryID: "shows",
        seriesID: "bear",
        season: 1,
        episode: 3
    )
    for completeness: Bool? in [nil, false] {
        var context: [String: Any] = ["watchedItemIDs": ["watched"], "recentItemIDs": ["watched"]]
        if let completeness {
            context["complete"] = completeness
        }
        let value = try lease([
            "blockedEpisodeIDs": ["forbidden"],
            "shuffle": ["preferUnwatched": true, "repeatCooldownDays": 7, "preferredShowIDs": []],
            "shuffleContext": context
        ])
        #expect(value.shuffleCandidates([watched, forbidden, episode], binding: binding, at: 2_000_000_000).map(\.id) == [
            "watched",
            "episode"
        ])
    }
}

@Test
func `operational playing time excludes seeks pauses and buffering`() {
    #expect(ViewingLease.playingInterval(
        previousPosition: 10,
        position: 11,
        elapsedSeconds: 1,
        playing: true,
        paused: false,
        buffering: false
    ) == 1)
    #expect(ViewingLease.playingInterval(
        previousPosition: 10,
        position: 100,
        elapsedSeconds: 1,
        playing: true,
        paused: false,
        buffering: false
    ) == 0)
    #expect(ViewingLease.playingInterval(
        previousPosition: 10,
        position: 11,
        elapsedSeconds: 1,
        playing: true,
        paused: true,
        buffering: false
    ) == 0)
    #expect(ViewingLease.playingInterval(
        previousPosition: 10,
        position: 11,
        elapsedSeconds: 1,
        playing: true,
        paused: false,
        buffering: true
    ) == 0)
    #expect(ViewingLease.playingInterval(
        previousPosition: 10,
        position: .nan,
        elapsedSeconds: 1,
        playing: true,
        paused: false,
        buffering: false
    ) == 0)
}
