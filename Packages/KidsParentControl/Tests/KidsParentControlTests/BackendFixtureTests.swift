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
