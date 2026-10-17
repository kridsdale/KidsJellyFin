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
    let response: String
    init(_ response: String) {
        self.response = response
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private let receiverID = "10000000-0000-4000-8000-000000000004"
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
