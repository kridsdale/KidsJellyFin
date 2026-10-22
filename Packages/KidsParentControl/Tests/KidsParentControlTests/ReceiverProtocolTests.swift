//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
@testable import KidsParentControl
import Testing

private actor ReceiverTransport: ParentHTTPTransport {
    var requests: [URLRequest] = []
    var responses: [String]
    let status: Int
    init(_ response: String, status: Int = 200) {
        responses = [response]
        self.status = status
    }

    init(responses: [String]) {
        self.responses = responses
        status = 200
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = try #require(responses.first)
        if responses.count > 1 {
            responses.removeFirst()
        }
        return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private let receiverID = "10000000-0000-4000-8000-000000000004"

@Test
func `build revision rejects malformed or ambiguous header values`() {
    let valid = String(repeating: "abcdef01", count: 8)
    #expect(ReceiverBuildRevision(rawValue: valid)?.rawValue == valid)
    for invalid in [
        "",
        String(valid.dropLast()),
        valid + "0",
        valid.uppercased(),
        valid + "\r\nHeader: value",
        String(repeating: "é", count: 32),
        String(repeating: "g", count: 64)
    ] {
        #expect(ReceiverBuildRevision(rawValue: invalid) == nil)
    }
}

@Test
func `all receiver requests declare the embedded build without changing frozen bodies`() async throws {
    let revision = try #require(ReceiverBuildRevision(rawValue: String(repeating: "abcdef01", count: 8)))
    let eventID = UUID(), intentID = UUID(), surrenderID = UUID()
    let policy = """
    {"serverID":"family","childUserID":"kid","deviceID":"\(receiverID)","revision":0,
    "serverTime":"2026-10-17T12:00:00Z","validUntil":"2026-10-17T12:00:00Z",
    "viewingAllowed":false,"blockedShowIDs":[],"blockedEpisodeIDs":[],
    "shuffle":{"preferUnwatched":false,"repeatCooldownDays":0,"preferredShowIDs":[]},"commands":[]}
    """
    let transport = ReceiverTransport(responses: [policy] + [eventID, intentID, surrenderID].map {
        "{\"commandID\":\"\($0)\",\"status\":\"persisted\"}"
    })
    let api = try KidsReceiverAPI(
        server: ParentServer("http://127.0.0.1:9"),
        serverID: "family",
        childUserID: "kid",
        deviceID: receiverID,
        token: "receiver-only",
        clientRevision: revision,
        transport: transport
    )
    _ = try await api.policy()
    try await api.send(ReceiverEvent(eventID: eventID, deviceID: receiverID, childUserID: "kid", policyRevision: 0, kind: .heartbeat))
    try await api.requestPlaybackIntent(commandID: intentID, expectedRevision: 0, playbackSessionID: "controller", itemID: "episode")
    try await api.surrenderPlayback(commandID: surrenderID, playbackIntentID: intentID, playbackSessionID: "controller", itemID: "episode")
    let requests = await transport.requests
    #expect(requests.count == 4)
    for (index, request) in requests.enumerated() {
        #expect(request.value(forHTTPHeaderField: "X-Kids-Client-Build") == revision.rawValue)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer receiver-only")
        #expect(request.url?.query == nil)
        if let data = request.httpBody {
            let decoded = try JSONSerialization.jsonObject(with: data)
            let object = try #require(decoded as? [String: Any])
            #expect(object.count == (index == 1 ? 10 : 6))
            #expect(object["clientRevision"] == nil && object["X-Kids-Client-Build"] == nil)
        } else {
            #expect(index == 0)
        }
    }
}

private func receiverAPI(_ transport: ReceiverTransport) throws -> KidsReceiverAPI {
    try KidsReceiverAPI(
        server: ParentServer("http://192.168.10.100:8097"),
        serverID: "family",
        childUserID: "kid",
        deviceID: receiverID,
        token: "receiver-only",
        transport: transport
    )
}

@Test
func `event body includes null keys and uses event ID for receipt`() async throws {
    let eventID = UUID(), commandID = UUID()
    let transport = ReceiverTransport("{\"commandID\":\"\(eventID)\",\"status\":\"persisted\"}")
    let api = try receiverAPI(transport)
    try await api.send(ReceiverEvent(
        eventID: eventID,
        deviceID: receiverID,
        childUserID: "kid",
        policyRevision: 0,
        kind: .heartbeat,
        commandID: commandID
    ))
    let request = try #require(await transport.requests.first)
    let requestData = try #require(request.httpBody)
    let decodedBody = try JSONSerialization.jsonObject(with: requestData)
    let json = try #require(decodedBody as? [String: Any])
    #expect(Set(json.keys) == Set([
        "eventID",
        "deviceID",
        "childUserID",
        "policyRevision",
        "playbackSessionID",
        "itemID",
        "kind",
        "positionSeconds",
        "elapsedPlayingSeconds",
        "commandID"
    ]))
    #expect(json["playbackSessionID"] is NSNull)
    #expect(json["itemID"] is NSNull)
    #expect(json["positionSeconds"] is NSNull)
    #expect(json["commandID"] as? String == commandID.uuidString)
    #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == eventID.uuidString)
    #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
    #expect(request.url?.path == "/api/kids/v1/events")
}

@Test
func `control ID is not an event receipt`() async throws {
    let commandID = UUID()
    let api = try receiverAPI(ReceiverTransport("{\"commandID\":\"\(commandID)\",\"status\":\"persisted\"}"))
    await #expect(throws: ParentControlError.malformedResponse) {
        try await api.send(ReceiverEvent(
            deviceID: receiverID,
            childUserID: "kid",
            policyRevision: 1,
            kind: .commandApplied,
            commandID: commandID
        ))
    }
}

@Test
func `unconfirmed receipt requires exact normal evidence correlation`() async throws {
    let normal: [ReceiverEvent.Kind] = [.started, .progress, .paused, .buffering, .ended, .stopped]
    for kind in normal {
        let event = ReceiverEvent(
            deviceID: receiverID,
            childUserID: "kid",
            policyRevision: 2,
            playbackSessionID: "original-session",
            itemID: "approved-item",
            kind: kind,
            positionSeconds: 1
        )
        let api = try receiverAPI(ReceiverTransport("""
        {"commandID":"\(event.eventID)","status":"persisted",
        "evidenceDisposition":"unconfirmed","unconfirmedPlaybackSessionID":"original-session"}
        """))
        let receipt = try await api.send(event)
        #expect(receipt.evidenceDisposition == "unconfirmed")
        #expect(receipt.unconfirmedPlaybackSessionID == event.playbackSessionID)
    }
}

@Test
func `unknown incomplete or cross-session recovery metadata fails closed`() async throws {
    let event = ReceiverEvent(
        deviceID: receiverID,
        childUserID: "kid",
        policyRevision: 2,
        playbackSessionID: "original-session",
        itemID: "approved-item",
        kind: .started,
        positionSeconds: 1
    )
    for metadata in [
        #""evidenceDisposition":"confirmed","unconfirmedPlaybackSessionID":"original-session""#,
        #""evidenceDisposition":"unconfirmed""#,
        #""unconfirmedPlaybackSessionID":"original-session""#,
        #""evidenceDisposition":"unconfirmed","unconfirmedPlaybackSessionID":"other-session""#,
        #""evidenceDisposition":"unconfirmed","unconfirmedPlaybackSessionID":"""#
    ] {
        let api = try receiverAPI(ReceiverTransport("{\"commandID\":\"\(event.eventID)\",\"status\":\"persisted\",\(metadata)}"))
        await #expect(throws: ParentControlError.malformedResponse) { try await api.send(event) }
    }
}

@Test
func `recovery metadata cannot retire playback through control ambient or heartbeat evidence`() async throws {
    for kind: ReceiverEvent.Kind in [.heartbeat, .commandApplied, .commandFailed, .ambientStarted, .ambientFailed] {
        let event = ReceiverEvent(
            deviceID: receiverID,
            childUserID: "kid",
            policyRevision: 2,
            playbackSessionID: "original-session",
            itemID: "approved-item",
            kind: kind,
            positionSeconds: 1
        )
        let api = try receiverAPI(ReceiverTransport("""
        {"commandID":"\(event.eventID)","status":"persisted",
        "evidenceDisposition":"unconfirmed","unconfirmedPlaybackSessionID":"original-session"}
        """))
        await #expect(throws: ParentControlError.malformedResponse) { try await api.send(event) }
    }
}

@Test
func `quarantine receipt is an exact noncredit audit acknowledgement`() async throws {
    let disposition = UUID()
    for kind: ReceiverEvent.Kind in [.started, .progress, .paused, .buffering, .ended, .stopped] {
        let event = ReceiverEvent(
            deviceID: receiverID,
            childUserID: "kid",
            policyRevision: 2,
            playbackSessionID: "retired-session",
            itemID: "approved-item",
            kind: kind,
            positionSeconds: 6.818,
            elapsedPlayingSeconds: 0
        )
        let api = try receiverAPI(ReceiverTransport("""
        {"commandID":"\(event.eventID)","status":"persisted","evidenceDisposition":"quarantined",
        "unconfirmedPlaybackSessionID":"retired-session","dispositionID":"\(disposition)",
        "usageCredited":false,"unknownUsagePreserved":true}
        """))
        let receipt = try await api.send(event)
        #expect(receipt.evidenceDisposition == "quarantined")
        #expect(receipt.unconfirmedPlaybackSessionID == event.playbackSessionID)
        #expect(receipt.dispositionID == disposition)
        #expect(receipt.usageCredited == false)
        #expect(receipt.unknownUsagePreserved == true)
    }
}

@Test
func `missing unsafe or cross-controller quarantine metadata cannot acknowledge evidence`() async throws {
    let event = ReceiverEvent(
        deviceID: receiverID,
        childUserID: "kid",
        policyRevision: 2,
        playbackSessionID: "retired-session",
        itemID: "approved-item",
        kind: .progress,
        positionSeconds: 6.818,
        elapsedPlayingSeconds: 5
    )
    let valid: [String: Any] = [
        "commandID": event.eventID.uuidString,
        "status": "persisted",
        "evidenceDisposition": "quarantined",
        "unconfirmedPlaybackSessionID": "retired-session",
        "dispositionID": UUID().uuidString,
        "usageCredited": false,
        "unknownUsagePreserved": true
    ]
    var variants: [[String: Any]] = []
    for key in ["dispositionID", "usageCredited", "unknownUsagePreserved", "unconfirmedPlaybackSessionID"] {
        var body = valid
        body.removeValue(forKey: key)
        variants.append(body)
    }
    for patch: [String: Any] in [
        ["usageCredited": true], ["unknownUsagePreserved": false], ["dispositionID": "not-a-uuid"],
        ["usageCredited": "false"], ["unconfirmedPlaybackSessionID": "replacement-session"],
        ["commandID": UUID().uuidString], ["status": "applied"]
    ] {
        variants.append(valid.merging(patch) { _, replacement in replacement })
    }
    for body in variants {
        let raw = try JSONSerialization.data(withJSONObject: body)
        let api = try receiverAPI(ReceiverTransport(String(decoding: raw, as: UTF8.self)))
        await #expect(throws: ParentControlError.malformedResponse) { try await api.send(event) }
    }
}

@Test
func `quarantine metadata cannot retire through heartbeat ambient or command acknowledgements`() async throws {
    for kind: ReceiverEvent.Kind in [.heartbeat, .commandApplied, .commandFailed, .ambientStarted, .ambientFailed] {
        let event = ReceiverEvent(
            deviceID: receiverID,
            childUserID: "kid",
            policyRevision: 2,
            playbackSessionID: "retired-session",
            itemID: "approved-item",
            kind: kind,
            positionSeconds: 1
        )
        let api = try receiverAPI(ReceiverTransport("""
        {"commandID":"\(event.eventID)","status":"persisted","evidenceDisposition":"quarantined",
        "unconfirmedPlaybackSessionID":"retired-session","dispositionID":"\(UUID())",
        "usageCredited":false,"unknownUsagePreserved":true}
        """))
        await #expect(throws: ParentControlError.malformedResponse) { try await api.send(event) }
    }
}

@Test
func `quarantine credit flags cannot hide in ordinary or unconfirmed receipts`() async throws {
    let event = ReceiverEvent(
        deviceID: receiverID,
        childUserID: "kid",
        policyRevision: 2,
        playbackSessionID: "retired-session",
        itemID: "approved-item",
        kind: .progress,
        positionSeconds: 1
    )
    for disposition in ["", #","evidenceDisposition":"unconfirmed","unconfirmedPlaybackSessionID":"retired-session""#] {
        let api = try receiverAPI(ReceiverTransport("""
        {"commandID":"\(event.eventID)","status":"persisted","dispositionID":"\(UUID())",
        "usageCredited":false,"unknownUsagePreserved":true\(disposition)}
        """))
        await #expect(throws: ParentControlError.malformedResponse) { try await api.send(event) }
    }
}

@Test
func `invalid device or numbers never leave receiver`() async throws {
    let transport = ReceiverTransport("{}")
    let api = try receiverAPI(transport)
    for event in [
        ReceiverEvent(deviceID: "tvOS_\(receiverID)", childUserID: "kid", policyRevision: 0, kind: .heartbeat),
        ReceiverEvent(deviceID: receiverID, childUserID: "other-child", policyRevision: 0, kind: .heartbeat),
        ReceiverEvent(deviceID: receiverID, childUserID: "kid", policyRevision: 0, kind: .progress, positionSeconds: .nan),
        ReceiverEvent(deviceID: receiverID, childUserID: "kid", policyRevision: 0, kind: .progress, elapsedPlayingSeconds: 31)
    ] {
        await #expect(throws: ParentControlError.invalidSelection) { try await api.send(event) }
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func `intent and surrender requests retain exact scope revision and immutable retry bytes`() async throws {
    let id = UUID(), surrenderID = UUID()
    let intentReceipt = "{\"commandID\":\"\(id)\",\"status\":\"persisted\"}"
    let surrenderReceipt = "{\"commandID\":\"\(surrenderID)\",\"status\":\"persisted\"}"
    let transport = ReceiverTransport(responses: [intentReceipt, intentReceipt, surrenderReceipt, surrenderReceipt])
    let api = try receiverAPI(transport)
    for _ in 0 ..< 2 {
        try await api.requestPlaybackIntent(commandID: id, expectedRevision: 4, playbackSessionID: "prepared-controller", itemID: "episode")
    }
    let intentID = UUID()
    for _ in 0 ..< 2 {
        try await api.surrenderPlayback(
            commandID: surrenderID,
            playbackIntentID: intentID,
            playbackSessionID: "prepared-controller",
            itemID: "episode"
        )
    }
    let requests = await transport.requests
    #expect(requests.count == 4)
    #expect(requests[0].httpBody == requests[1].httpBody)
    #expect(requests[2].httpBody == requests[3].httpBody)
    #expect(requests[0].url?.path == "/api/kids/v1/playback-intents")
    #expect(requests[2].url?.path == "/api/kids/v1/playback-surrenders")
    for (index, request) in requests.enumerated() {
        #expect(request.httpMethod == "POST")
        #expect(request.url?.query == nil)
        let requestID = index >= 2 ? surrenderID : id
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == requestID.uuidString)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer receiver-only")
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
        let body = try #require(request.httpBody)
        let decoded = try JSONSerialization.jsonObject(with: body)
        let object = try #require(decoded as? [String: Any])
        let keys = ["commandID", "deviceID", "childUserID", "playbackSessionID", "itemID"] +
            [index >= 2 ? "playbackIntentID" : "expectedRevision"]
        #expect(Set(object.keys) == Set(keys))
        if index >= 2 {
            #expect(object["playbackIntentID"] as? String == intentID.uuidString)
        }
        #expect(object["commandID"] as? String == requestID.uuidString)
        #expect(object["deviceID"] as? String == receiverID)
        #expect(object["childUserID"] as? String == "kid")
        #expect(object["playbackSessionID"] as? String == "prepared-controller")
        #expect(object["itemID"] as? String == "episode")
        if index < 2 {
            #expect(object["expectedRevision"] as? Int == 4)
        }
    }
}

@Test
func `playback mutations reject unrelated or nonpersisted receipts`() async throws {
    let requested = UUID()
    for receipt in [
        "{\"commandID\":\"\(UUID())\",\"status\":\"persisted\"}",
        "{\"commandID\":\"\(requested)\",\"status\":\"applied\"}",
        "{\"commandID\":\"\(requested)\",\"status\":\"failed\"}"
    ] {
        let api = try receiverAPI(ReceiverTransport(receipt))
        await #expect(throws: ParentControlError.malformedResponse) {
            try await api.requestPlaybackIntent(
                commandID: requested,
                expectedRevision: 1,
                playbackSessionID: "controller",
                itemID: "episode"
            )
        }
        await #expect(throws: ParentControlError.malformedResponse) {
            try await api.surrenderPlayback(
                commandID: requested,
                playbackIntentID: UUID(),
                playbackSessionID: "controller",
                itemID: "episode"
            )
        }
    }
}

@Test
func `playback intent policy distinguishes browse availability from exact bound permission`() async throws {
    let intentID = UUID()
    let base = """
    {"serverID":"family","childUserID":"kid","deviceID":"\(receiverID)","revision":4,
    "serverTime":"2026-10-17T12:00:00.000Z","validUntil":"2026-10-17T12:00:30.000Z",
    "viewingAllowed":true,"blockedShowIDs":[],"blockedEpisodeIDs":[],
    "shuffle":{"preferUnwatched":false,"repeatCooldownDays":0,"preferredShowIDs":[]},"commands":[],
    "playbackIntentRequired":true,"playbackIntentAvailable":true,"playbackIntentID":"\(intentID)",
    "leasePlaybackSessionID":"Prepared-Controller","leaseItemID":"approved-episode"}
    """
    let granted = try await receiverAPI(ReceiverTransport(base)).policy()
    #expect(granted.playbackIntentRequired == true)
    #expect(granted.playbackIntentAvailable == true)
    #expect(granted.playbackIntentID == intentID)
    #expect(granted.leasePlaybackSessionID == "Prepared-Controller")
    #expect(granted.leaseItemID == "approved-episode")
    let decoded = try JSONSerialization.jsonObject(with: Data(base.utf8))
    var browse = try #require(decoded as? [String: Any])
    browse["viewingAllowed"] = false
    browse["validUntil"] = browse["serverTime"]
    for key in ["playbackIntentID", "leasePlaybackSessionID", "leaseItemID"] {
        browse[key] = NSNull()
    }
    let data = try JSONSerialization.data(withJSONObject: browse)
    let json = try #require(String(data: data, encoding: .utf8))
    let idle = try await receiverAPI(ReceiverTransport(json)).policy()
    #expect(idle.playbackIntentAvailable == true)
    #expect(!idle.viewingAllowed)
    #expect(idle.validUntil == idle.serverTime)
    #expect(idle.playbackIntentID == nil && idle.leasePlaybackSessionID == nil && idle.leaseItemID == nil)
    #expect(idle.hasPlaybackGrantFields)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let encoded = try encoder.encode(idle)
    let roundtripJSON = try #require(String(data: encoded, encoding: .utf8))
    let roundtrip = try await receiverAPI(ReceiverTransport(roundtripJSON)).policy()
    #expect(roundtrip == idle)
    #expect(roundtrip.hasPlaybackGrantFields)
}

@Test
func `invalid playback selection or revision cannot send intent or surrender`() async throws {
    let transport = ReceiverTransport("{}")
    let api = try receiverAPI(transport)
    for (revision, session, item) in [(-1, "controller", "item"), (0, "", "item"), (0, "controller", "../item")] {
        await #expect(throws: ParentControlError.invalidSelection) {
            try await api.requestPlaybackIntent(commandID: UUID(), expectedRevision: revision, playbackSessionID: session, itemID: item)
        }
        if revision >= 0 {
            await #expect(throws: ParentControlError.invalidSelection) {
                try await api.surrenderPlayback(
                    commandID: UUID(),
                    playbackIntentID: UUID(),
                    playbackSessionID: session,
                    itemID: item
                )
            }
        }
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func `intent conflicts retain exact refusal codes without refreshing or rewriting request`() async throws {
    let definite = ["revision_conflict", "active_intent_exists", "controller_mismatch"]
    let integrity = ["idempotency_conflict", "command_epoch_changed", "intent_subject_mismatch", "unknown_error"]
    for code in definite + integrity {
        let transport = ReceiverTransport("{\"error\":\"\(code)\",\"message\":\"Synthetic refusal\"}", status: 409)
        let api = try receiverAPI(transport)
        let id = UUID()
        await #expect(throws: ReceiverMutationConflict(code: code)) {
            try await api.requestPlaybackIntent(commandID: id, expectedRevision: 2, playbackSessionID: "controller", itemID: "episode")
        }
        #expect(ReceiverMutationConflict(code: code).isDefiniteIntentRefusal == definite.contains(code))
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].value(forHTTPHeaderField: "Idempotency-Key") == id.uuidString)
    }
}

@Test
func `unknown surrender conflicts cannot be interpreted as safe intent rejection`() async throws {
    for response in ["{}", "not-json", "{\"error\":null}"] {
        let api = try receiverAPI(ReceiverTransport(response, status: 409))
        await #expect(throws: ReceiverMutationConflict(code: nil)) {
            try await api.surrenderPlayback(commandID: UUID(), playbackIntentID: UUID(), playbackSessionID: "controller", itemID: "episode")
        }
    }
    #expect(!ReceiverMutationConflict(code: nil).isDefiniteIntentRefusal)
}

@Test
func `wrong policy identity cannot be installed`() async throws {
    let json = #"{"serverID":"other","childUserID":"kid","deviceID":"10000000-0000-4000-8000-000000000004","revision":1,"serverTime":"2026-10-17T12:00:00.000Z","validUntil":"2026-10-17T12:00:30.000Z","viewingAllowed":true,"blockedShowIDs":[],"blockedEpisodeIDs":[],"shuffle":{"preferUnwatched":false,"repeatCooldownDays":0,"preferredShowIDs":[]},"commands":[]}"#
    let transport = ReceiverTransport(json)
    let api = try receiverAPI(transport)
    await #expect(throws: ParentControlError.serverMismatch) { try await api.policy() }
    let request = try #require(await transport.requests.first)
    #expect(request.httpMethod == "GET")
    #expect(request.httpBody == nil)
    #expect(request.url?.query == nil)
    #expect(request.url?.path == "/api/kids/v1/policy")
}

@Test
func `backend budget fixture keeps held time unavailable`() throws {
    let json = #"{"budget":{"bonusSeconds":0,"dailyMinutes":2,"enabled":true,"localDate":"2026-10-17","remainingSeconds":60,"reservedSeconds":30,"unconfirmedSeconds":25,"usedSeconds":5},"childUserID":"10000000-0000-4000-8000-000000000003","excludedEpisodeIDs":[],"revision":1,"routines":[],"shuffle":{"preferUnwatched":false,"preferredShowIDs":[],"repeatCooldownDays":0},"timeZone":"UTC"}"#
    let profile = try JSONDecoder().decode(ParentProfileSettings.self, from: Data(json.utf8))
    #expect(profile.budget.remainingSeconds == 60)
    #expect(profile.budget.usedSeconds == 5)
    #expect(profile.budget.unconfirmedSeconds == 25)
}
