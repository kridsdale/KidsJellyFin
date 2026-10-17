//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation
@testable import KidsParentControl
import Testing

private actor FixtureTransport: ParentHTTPTransport {
    var requests: [URLRequest] = []
    var replies: [(status: Int, data: Data)]
    init(status: Int = 200, data: Data) {
        replies = [(status, data)]
    }

    init(replies: [Data]) {
        self.replies = replies.map { (200, $0) }
    }

    init(httpReplies: [(Int, Data)]) {
        replies = httpReplies.map { ($0.0, $0.1) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let reply = try #require(replies.first)
        if replies.count > 1 {
            replies.removeFirst()
        }
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil))
        return (reply.data, response)
    }
}

private func enforcementFixture(_ key: String) throws -> Data {
    try wireFixture("enforcement", key)
}

private func wireFixture(_ name: String, _ key: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    let object = try #require(decoded as? [String: Any])
    let value = try #require(object[key])
    return try JSONSerialization.data(withJSONObject: value)
}

private func nativeUUIDBody(_ key: String) throws -> Data {
    let value = try JSONSerialization.jsonObject(with: wireFixture("native-uuid-transaction", key))
    let object = try #require(value as? [String: Any])
    let body = try #require(object["body"])
    return try JSONSerialization.data(withJSONObject: body)
}

private func nestedRecoveryFixture(_ name: String, _ key: String, _ member: String) throws -> Data {
    let decoded = try JSONSerialization.jsonObject(with: wireFixture(name, key))
    let object = try #require(decoded as? [String: Any])
    let value = try #require(object[member])
    return try JSONSerialization.data(withJSONObject: value)
}

private func grantResponse(_ key: String, event: Bool = false) throws -> (Int, Data) {
    let data = try event ? nestedRecoveryFixture("playback-grants-transaction-v2", key, "response") :
        wireFixture("playback-grants-transaction-v2", key)
    let decoded = try JSONSerialization.jsonObject(with: data)
    let object = try #require(decoded as? [String: Any])
    let status = try #require(object["httpStatus"] as? Int)
    let body = try #require(object["body"])
    return try (status, JSONSerialization.data(withJSONObject: body))
}

private struct GrantIntentRequest: Decodable {
    let commandID: UUID
    let expectedRevision: Int
    let playbackSessionID: String
    let itemID: String
}

private struct GrantSurrenderRequest: Decodable {
    let commandID: UUID
    let playbackIntentID: UUID
    let playbackSessionID: String
    let itemID: String
}

@Test
func `actual backend grant transaction requires fresh bound GET and keeps resumed generation distinct`() async throws {
    let name = "playback-grants-transaction-v2"
    let transport = try FixtureTransport(httpReplies: [
        grantResponse("idle-policy"), grantResponse("intent-receipt"), grantResponse("exact-intent-retry"), grantResponse("bound-policy"),
        grantResponse("started", event: true), grantResponse("progress", event: true), grantResponse("paused", event: true),
        grantResponse("surrender-receipt"), grantResponse("exact-surrender-retry"), grantResponse("held-after-surrender"),
        grantResponse("resume-intent-receipt"), grantResponse("resume-bound-policy"), grantResponse("stale-old-surrender"),
        grantResponse("policy-after-stale-surrender"), grantResponse("resume-started", event: true), grantResponse("outage-held-policy"),
        grantResponse("outage-current-surrender")
    ])
    let api = try recoveryAPI(transport)
    let idle = try await api.policy()
    #expect(idle.hasPlaybackGrantFields && idle.playbackIntentAvailable == true && !idle.viewingAllowed)
    #expect(idle.playbackIntentID == nil && idle.validUntil == idle.serverTime)
    let decoder = JSONDecoder()
    let intent = try decoder.decode(GrantIntentRequest.self, from: wireFixture(name, "intent-request"))
    for _ in 0 ..< 2 {
        try await api.requestPlaybackIntent(
            commandID: intent.commandID,
            expectedRevision: intent.expectedRevision,
            playbackSessionID: intent.playbackSessionID,
            itemID: intent.itemID
        )
    }
    let bound = try await api.policy()
    #expect(bound.viewingAllowed && bound.playbackIntentAvailable == false)
    #expect(bound.playbackIntentID == intent.commandID && bound.leasePlaybackSessionID == intent.playbackSessionID && bound
        .leaseItemID == intent.itemID)
    for key in ["started", "progress", "paused"] {
        try await api.send(decoder.decode(ReceiverEvent.self, from: nestedRecoveryFixture(name, key, "request")))
    }
    let surrender = try decoder.decode(GrantSurrenderRequest.self, from: wireFixture(name, "surrender-request"))
    for _ in 0 ..< 2 {
        try await api.surrenderPlayback(
            commandID: surrender.commandID,
            playbackIntentID: surrender.playbackIntentID,
            playbackSessionID: surrender.playbackSessionID,
            itemID: surrender.itemID
        )
    }
    let held = try await api.policy()
    #expect(!held.viewingAllowed && held.playbackIntentAvailable == true && held.playbackIntentID == nil)
    let resume = try decoder.decode(GrantIntentRequest.self, from: wireFixture(name, "resume-intent-request"))
    #expect(resume.playbackSessionID == intent.playbackSessionID && resume.commandID != intent.commandID)
    try await api.requestPlaybackIntent(
        commandID: resume.commandID,
        expectedRevision: resume.expectedRevision,
        playbackSessionID: resume.playbackSessionID,
        itemID: resume.itemID
    )
    let resumed = try await api.policy()
    #expect(resumed.playbackIntentID == resume.commandID)
    let oldReceipt = try JSONDecoder().decode(ParentCommandReceipt.self, from: grantResponse("stale-old-surrender").1)
    try await api.surrenderPlayback(
        commandID: oldReceipt.commandID,
        playbackIntentID: intent.commandID,
        playbackSessionID: intent.playbackSessionID,
        itemID: intent.itemID
    )
    let afterOld = try await api.policy()
    #expect(afterOld == resumed)
    try await api.send(decoder.decode(ReceiverEvent.self, from: nestedRecoveryFixture(name, "resume-started", "request")))
    let renewal = try await api.policy()
    #expect(renewal.playbackIntentID == resume.commandID && renewal.revision > resumed.revision)
    let finalReceipt = try JSONDecoder().decode(ParentCommandReceipt.self, from: grantResponse("outage-current-surrender").1)
    try await api.surrenderPlayback(
        commandID: finalReceipt.commandID,
        playbackIntentID: resume.commandID,
        playbackSessionID: resume.playbackSessionID,
        itemID: resume.itemID
    )
    let requests = await transport.requests
    #expect(requests[1].httpBody == requests[2].httpBody)
    #expect(requests[7].httpBody == requests[8].httpBody)
    #expect(requests[0].httpMethod == "GET" && requests[3].httpMethod == "GET" && requests[9].httpMethod == "GET")
}

@Test
func `actual admission conflict fixtures preserve integrity versus definite refusal`() async throws {
    for (key, code, definite) in [
        ("revision-refusal", "revision_conflict", true), ("active-refusal", "active_intent_exists", true),
        ("changed-intent-body", "idempotency_conflict", false)
    ] {
        let response = try grantResponse(key)
        let api = try recoveryAPI(FixtureTransport(status: response.0, data: response.1))
        await #expect(throws: ReceiverMutationConflict(code: code)) {
            try await api.requestPlaybackIntent(
                commandID: UUID(),
                expectedRevision: 1,
                playbackSessionID: "Synthetic-Controller-A",
                itemID: "10000000-0000-4000-8000-000000000006"
            )
        }
        #expect(ReceiverMutationConflict(code: code).isDefiniteIntentRefusal == definite)
    }
}

private func recoveryAPI(_ transport: FixtureTransport) throws -> KidsReceiverAPI {
    try KidsReceiverAPI(
        server: ParentServer("http://127.0.0.1:9"),
        serverID: "10000000-0000-4000-8000-000000000001",
        childUserID: "10000000-0000-4000-8000-000000000003",
        deviceID: "10000000-0000-4000-8000-000000000004",
        token: "synthetic", transport: transport
    )
}

@Test
func `historical reports preserve old revision through current denial and exact retry`() async throws {
    let transport = try FixtureTransport(replies: [
        wireFixture("historical-usage", "original-allow"), wireFixture("historical-usage", "current-denial"),
        nestedRecoveryFixture("historical-usage", "late-progress", "response"),
        nestedRecoveryFixture("historical-usage", "late-progress", "response"),
        nestedRecoveryFixture("historical-usage", "old-controller-stopped", "response"),
        wireFixture("historical-usage", "still-denied")
    ])
    let api = try recoveryAPI(transport)
    #expect(try await api.policy().viewingAllowed)
    #expect(try await !api.policy().viewingAllowed)
    let progress = try JSONDecoder().decode(ReceiverEvent.self, from: nestedRecoveryFixture("historical-usage", "late-progress", "request"))
    let stopped = try JSONDecoder().decode(
        ReceiverEvent.self,
        from: nestedRecoveryFixture("historical-usage", "old-controller-stopped", "request")
    )
    try await api.send(progress)
    try await api.send(progress)
    try await api.send(stopped)
    let denied = try await api.policy()
    #expect(!denied.viewingAllowed)
    #expect(denied.revision == 5)
    let requests = await transport.requests
    #expect(requests[2].httpBody == requests[3].httpBody)
    let reports = try requests.compactMap { request in
        try request.httpBody.map { try JSONDecoder().decode(ReceiverEvent.self, from: $0) }
    }
    #expect(reports == [progress, progress, stopped])
    #expect(reports.allSatisfy { $0.policyRevision == 2 })
}

@Test
func `late command persistence receipt is distinct from fresh release action receipt`() async throws {
    let transport = try FixtureTransport(replies: [
        wireFixture("late-ack", "delivered-policy"), nestedRecoveryFixture("late-ack", "expired-ACK", "response"),
        wireFixture("late-ack", "fresh-release-policy"), nestedRecoveryFixture("late-ack", "release-ACK", "response")
    ])
    let api = try recoveryAPI(transport)
    let delivered = try await api.policy()
    let expired = try JSONDecoder().decode(ReceiverEvent.self, from: nestedRecoveryFixture("late-ack", "expired-ACK", "request"))
    #expect(expired.commandID == delivered.commands.first?.commandID)
    try await api.send(expired)
    // send accepts only the event persistence receipt. It never interprets it as
    // an applied parent action or locally grants permission on that basis.
    let release = try await api.policy()
    let acknowledgement = try JSONDecoder().decode(ReceiverEvent.self, from: nestedRecoveryFixture("late-ack", "release-ACK", "request"))
    #expect(release.policyControl?.kind == .release)
    #expect(acknowledgement.commandID == release.policyControl?.commandID)
    #expect(acknowledgement.commandID != expired.commandID)
    try await api.send(acknowledgement)
    let requests = await transport.requests
    let events = try requests.compactMap { request in
        try request.httpBody.map { try JSONDecoder().decode(ReceiverEvent.self, from: $0) }
    }
    #expect(events == [expired, acknowledgement])
    #expect(events.map(\.policyRevision) == [3, 5])
}

@Test
func `backend unconfirmed first start survives denial retry and replacement without relabeling`() async throws {
    let name = "unconfirmed-first-start"
    let transport = try FixtureTransport(replies: [
        wireFixture(name, "original-allow"), wireFixture(name, "current-denial"),
        nestedRecoveryFixture(name, "unobserved-start", "response"), wireFixture(name, "exact-retry-response"),
        nestedRecoveryFixture(name, "unobserved-progress", "response"), nestedRecoveryFixture(name, "real-stop-after-reset", "response"),
        wireFixture(name, "still-denied"), wireFixture(name, "new-explicit-allow"),
        nestedRecoveryFixture(name, "new-operational-start", "response"), nestedRecoveryFixture(name, "new-observed-progress", "response"),
        nestedRecoveryFixture(name, "late-old-terminal", "response")
    ])
    let api = try recoveryAPI(transport)
    #expect(try await api.policy().viewingAllowed)
    #expect(try await !api.policy().viewingAllowed)
    let decoder = JSONDecoder()
    let start = try decoder.decode(ReceiverEvent.self, from: nestedRecoveryFixture(name, "unobserved-start", "request"))
    let first = try await api.send(start)
    let retry = try await api.send(start)
    #expect(first == retry)
    #expect(first.evidenceDisposition == "unconfirmed")
    #expect(first.unconfirmedPlaybackSessionID == "actual-callback-queued-offline")
    for key in ["unobserved-progress", "real-stop-after-reset"] {
        let event = try decoder.decode(ReceiverEvent.self, from: nestedRecoveryFixture(name, key, "request"))
        let receipt = try await api.send(event)
        #expect(receipt.unconfirmedPlaybackSessionID == start.playbackSessionID)
        #expect(event.policyRevision == 2)
    }
    let denied = try await api.policy()
    #expect(!denied.viewingAllowed)
    #expect(denied.revision == 6)
    // The source transaction explicitly changes parent policy before this new
    // grant. No unconfirmed receipt itself creates this permission or start.
    let allowed = try await api.policy()
    #expect(allowed.viewingAllowed)
    #expect(allowed.revision == 9)
    for key in ["new-operational-start", "new-observed-progress"] {
        let event = try decoder.decode(ReceiverEvent.self, from: nestedRecoveryFixture(name, key, "request"))
        let receipt = try await api.send(event)
        #expect(receipt.evidenceDisposition == nil)
        #expect(receipt.unconfirmedPlaybackSessionID == nil)
        #expect(event.playbackSessionID == "replacement-controller")
        #expect(event.policyRevision == 9)
    }
    let terminal = try decoder.decode(ReceiverEvent.self, from: nestedRecoveryFixture(name, "late-old-terminal", "request"))
    let late = try await api.send(terminal)
    #expect(late.unconfirmedPlaybackSessionID == start.playbackSessionID)
    #expect(late.unconfirmedPlaybackSessionID != "replacement-controller")
    let requests = await transport.requests
    #expect(requests[2].httpBody == requests[3].httpBody)
    let sent = try requests.compactMap { request in
        try request.httpBody.map { try decoder.decode(ReceiverEvent.self, from: $0) }
    }
    #expect(sent.map(\.policyRevision) == [2, 2, 2, 2, 9, 9, 2])
}

private func nativeUUIDAPI(_ transport: FixtureTransport) throws -> KidsReceiverAPI {
    try KidsReceiverAPI(
        server: ParentServer("http://127.0.0.1:9"),
        serverID: "10000000-0000-4000-8000-000000000001",
        childUserID: "10000000-0000-4000-8000-000000000003",
        deviceID: "ABCDEFAB-ABCD-4ABC-8ABC-ABCDEFABCDEF",
        token: "synthetic",
        transport: transport
    )
}

@Test
func `native UUID transaction preserves subject spelling and matches canonical receipts`() async throws {
    let transport = try FixtureTransport(replies: [
        nativeUUIDBody("bootstrap-response"), nativeUUIDBody("exact-byte-retry"),
        nativeUUIDBody("policy-response"), nativeUUIDBody("uppercase-control-ACK-response")
    ])
    let api = try nativeUUIDAPI(transport)
    let bootstrap = try JSONDecoder().decode(ReceiverEvent.self, from: wireFixture("native-uuid-transaction", "bootstrap-request"))
    try await api.send(bootstrap)
    try await api.send(bootstrap)
    let policy = try await api.policy()
    #expect(policy.deviceID == "ABCDEFAB-ABCD-4ABC-8ABC-ABCDEFABCDEF")
    let acknowledgement = try JSONDecoder().decode(
        ReceiverEvent.self,
        from: wireFixture("native-uuid-transaction", "uppercase-control-ACK-request")
    )
    #expect(acknowledgement.commandID == policy.policyControl?.commandID)
    try await api.send(acknowledgement)
    let requests = await transport.requests
    #expect(requests[0].httpBody == requests[1].httpBody)
    for request in requests where request.httpMethod == "POST" {
        let data = try #require(request.httpBody)
        let value = try JSONSerialization.jsonObject(with: data)
        let object = try #require(value as? [String: Any])
        #expect(object["deviceID"] as? String == "ABCDEFAB-ABCD-4ABC-8ABC-ABCDEFABCDEF")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == object["eventID"] as? String)
    }
}

@Test
func `installation alias is rejected before sending a scoped receiver event`() async throws {
    let transport = FixtureTransport(data: Data("{}".utf8))
    let api = try nativeUUIDAPI(transport)
    await #expect(throws: ParentControlError.invalidSelection) {
        try await api.send(ReceiverEvent(
            deviceID: "abcdefab-abcd-4abc-8abc-abcdefabcdef",
            childUserID: "10000000-0000-4000-8000-000000000003",
            policyRevision: 0,
            kind: .heartbeat
        ))
    }
    #expect(await transport.requests.isEmpty)
}

@Test
func `policy cannot substitute a differently spelled installation identity`() async throws {
    let value = try JSONSerialization.jsonObject(with: nativeUUIDBody("policy-response"))
    var object = try #require(value as? [String: Any])
    object["deviceID"] = "abcdefab-abcd-4abc-8abc-abcdefabcdef"
    let api = try nativeUUIDAPI(FixtureTransport(data: JSONSerialization.data(withJSONObject: object)))
    await #expect(throws: ParentControlError.serverMismatch) { try await api.policy() }
}

@Test(arguments: ["activated-idle-heartbeat", "playing-heartbeat", "ambient-start", "ambient-heartbeat"])
func `backend heartbeat vectors roundtrip all scoped event fields`(_ key: String) async throws {
    let rootData = try wireFixture("heartbeats", key)
    let rootValue = try JSONSerialization.jsonObject(with: rootData)
    let root = try #require(rootValue as? [String: Any])
    var expected = try #require(root["request"] as? [String: Any])
    let event = try JSONDecoder().decode(ReceiverEvent.self, from: JSONSerialization.data(withJSONObject: expected))
    let response = try #require(root["response"])
    let transport = try FixtureTransport(data: JSONSerialization.data(withJSONObject: response))
    let api = try KidsReceiverAPI(
        server: ParentServer("http://127.0.0.1:9"), serverID: "10000000-0000-4000-8000-000000000001",
        childUserID: event.childUserID, deviceID: event.deviceID, token: "synthetic", transport: transport
    )
    try await api.send(event)
    try await api.send(event)
    let requests = await transport.requests
    let firstData = try #require(requests.first?.httpBody)
    let actual = try JSONSerialization.jsonObject(with: firstData)
    // Swift UUID encodes uppercase. Event/control identity is a UUID; installation
    // spelling is separate and must not be rewritten. Backend acceptance of this
    // native spelling is an explicit cross-language integration requirement.
    for key in ["eventID", "commandID"] {
        if let spelling = expected[key] as? String {
            expected[key] = try #require(UUID(uuidString: spelling)).uuidString
        }
    }
    #expect((actual as? NSDictionary)?.isEqual(to: expected) == true)
    #expect(requests.first?.httpBody == requests.last?.httpBody)
    #expect(event.elapsedPlayingSeconds == 0)
}

@Test(arguments: ["sessionless-playing-denial", "wrong-ambient-controller-denial", "stale-ambient-after-release-denial"])
func `backend stale heartbeat responses retain structured recovery reason`(_ key: String) async throws {
    let value = try JSONSerialization.jsonObject(with: wireFixture("heartbeats", key))
    let object = try #require(value as? [String: Any])
    let body = try #require(object["body"])
    let transport = try FixtureTransport(status: 409, data: JSONSerialization.data(withJSONObject: body))
    let api = try KidsReceiverAPI(
        server: ParentServer("http://127.0.0.1:9"), serverID: "10000000-0000-4000-8000-000000000001",
        childUserID: "10000000-0000-4000-8000-000000000003", deviceID: "10000000-0000-4000-8000-000000000004",
        token: "synthetic", transport: transport
    )
    await #expect(throws: ReceiverEventConflict(code: "heartbeat_session_mismatch")) {
        try await api.send(ReceiverEvent(
            deviceID: "10000000-0000-4000-8000-000000000004",
            childUserID: "10000000-0000-4000-8000-000000000003",
            policyRevision: 5,
            kind: .heartbeat
        ))
    }
}

private func fixtureAPI(_ key: String, status: Int = 200) throws -> KidsReceiverAPI {
    let fixture = try enforcementFixture(key)
    let data: Data
    if status == 200 {
        data = fixture
    } else {
        let decoded = try JSONSerialization.jsonObject(with: fixture)
        let object = try #require(decoded as? [String: Any])
        let body = try #require(object["body"])
        data = try JSONSerialization.data(withJSONObject: body)
    }
    return try KidsReceiverAPI(
        server: ParentServer("http://127.0.0.1:9"),
        serverID: "10000000-0000-4000-8000-000000000001",
        childUserID: "10000000-0000-4000-8000-000000000003",
        deviceID: "10000000-0000-4000-8000-000000000004",
        token: "synthetic-never-sent-to-network",
        transport: FixtureTransport(status: status, data: data)
    )
}

@Test
func `backend fractional playback remains precise while public budget is integral`() async throws {
    let event = try JSONDecoder().decode(ReceiverEvent.self, from: wireFixture("fractional-seconds", "progress-request"))
    #expect(event.elapsedPlayingSeconds == 1.23)
    #expect(event.positionSeconds == 1.23)
    let transport = try FixtureTransport(data: wireFixture("fractional-seconds", "progress-response"))
    let api = try KidsReceiverAPI(
        server: ParentServer("http://127.0.0.1:9"),
        serverID: "10000000-0000-4000-8000-000000000001",
        childUserID: event.childUserID,
        deviceID: event.deviceID,
        token: "synthetic",
        transport: transport
    )
    try await api.send(event)
    let requests = await transport.requests
    let sentData = try #require(requests.first?.httpBody)
    let sent = try JSONDecoder().decode(ReceiverEvent.self, from: sentData)
    #expect(sent == event)
    let before = try JSONDecoder().decode(ParentProfileSettings.self, from: wireFixture("fractional-seconds", "settings-with-reservation"))
    let after = try JSONDecoder().decode(
        ParentProfileSettings.self,
        from: wireFixture("fractional-seconds", "settings-after-reservation-expires")
    )
    #expect(before.budget.usedSeconds == 1)
    #expect(before.budget.reservedSeconds == 29)
    #expect(after.budget.reservedSeconds == 0)
    #expect(after.budget.unconfirmedSeconds == 29)
    #expect(before.budget.remainingSeconds == 270)
    #expect(after.budget.remainingSeconds == 270)
}

@Test
func `excerpted history cannot bypass required stable identity`() async throws {
    let transport = try FixtureTransport(data: wireFixture("fractional-seconds", "history-item"))
    let http = try ParentHTTP(server: ParentServer("http://127.0.0.1:9"), transport: transport)
    // Server confirmed this historical vector intentionally removed the ID.
    // The separately generated exact-page successor must prove positive decode.
    await #expect(throws: ParentControlError.malformedResponse) {
        let _: ViewingHistoryEntry = try await http.request("fixture/history")
    }
}

@Test
func `exact backend history page preserves scope stable ID and integral duration`() async throws {
    let capabilities = Data(#"{"version":1,"serverID":"10000000-0000-4000-8000-000000000001","features":["viewing-history-v1"]}"#.utf8)
    let transport = try FixtureTransport(replies: [capabilities, wireFixture("fractional-seconds-full-page", "history-page")])
    let api = try ParentControlAPI(
        server: ParentServer("http://127.0.0.1:9"),
        serverID: "10000000-0000-4000-8000-000000000001",
        token: "synthetic",
        transport: transport
    )
    _ = try await api.connect()
    let page = try await api.history(childUserID: "10000000-0000-4000-8000-000000000003")
    #expect(page.childUserID == "10000000-0000-4000-8000-000000000003")
    #expect(page.items.count == 1)
    let item = try #require(page.items.first)
    #expect(item.id == "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff")
    #expect(item.watchedSeconds == 1)
    #expect(item.evidence == "clientReported")
    #expect(page.nextCursor == nil)
    let requests = await transport.requests
    #expect(requests.last?.url?.path == "/api/parent/v1/profiles/10000000-0000-4000-8000-000000000003/history")
}

@Test
func `backend enforcement fixture decodes explicit activation and zero lease release`() async throws {
    let enabled = try await fixtureAPI("enabled-policy").policy()
    #expect(enabled.enforcementEnabled == true)
    #expect(enabled.revision == 2)
    #expect(enabled.validUntil.timeIntervalSince(enabled.serverTime) == 30)
    let disabled = try await fixtureAPI("disabled-policy").policy()
    #expect(disabled.enforcementEnabled == false)
    #expect(disabled.policyControl?.kind == .release)
    #expect(disabled.policyControl?.commandID == UUID(uuidString: "abcdefab-0000-4000-8000-000000000194"))
    #expect(disabled.revision > enabled.revision)
    #expect(disabled.validUntil == disabled.serverTime)
    #expect(!disabled.viewingAllowed)
}

@Test
func `backend enforcement fixture receipt acknowledges event not release control`() async throws {
    let api = try fixtureAPI("release-applied")
    try await api.send(ReceiverEvent(
        eventID: #require(UUID(uuidString: "abcdefab-0000-4000-8000-000000000195")),
        deviceID: "10000000-0000-4000-8000-000000000004",
        childUserID: "10000000-0000-4000-8000-000000000003",
        policyRevision: 3,
        kind: .commandApplied,
        commandID: #require(UUID(uuidString: "abcdefab-0000-4000-8000-000000000194"))
    ))
}

@Test
func `backend enforcement fixture preserves commissioning denial and heartbeat race`() async throws {
    let notReady = try fixtureAPI("before-policy-denial", status: 501)
    await #expect(throws: ParentControlError.unsupported) { try await notReady.policy() }
    let race = try fixtureAPI("racing-idle-heartbeat-denial", status: 409)
    await #expect(throws: ReceiverEventConflict(code: "lease_mismatch")) {
        try await race.send(ReceiverEvent(
            eventID: #require(UUID(uuidString: "abcdefab-0000-4000-8000-000000000191")),
            deviceID: "10000000-0000-4000-8000-000000000004",
            childUserID: "10000000-0000-4000-8000-000000000003",
            policyRevision: 0,
            kind: .heartbeat
        ))
    }
}
