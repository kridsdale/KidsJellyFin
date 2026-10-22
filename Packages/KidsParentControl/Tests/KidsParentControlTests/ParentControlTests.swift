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

private actor StubTransport: ParentHTTPTransport {
    var requests: [URLRequest] = []
    var replies: [(Int, String)]
    init(_ replies: [(Int, String)]) {
        self.replies = replies
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw ParentControlError.malformedResponse }
        let (status, json) = replies.removeFirst()
        if status == 0 {
            throw URLError(.networkConnectionLost)
        }
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private let dashboardJSON = """
{"serverID":"family","children":[{"id":"kid","name":"Kids"}],
"televisions":[{"id":"tv","name":"Living room","childUserID":"kid","online":true,"canEnforceDeadline":true,"revision":7,"countdown":null}],
"birdVideos":[{"id":"birds","name":"Bird feeder"}],
"shows":[{"id":"bear","name":"Little Bear","childUserID":"kid","enabled":true,"revision":3}]}
"""
private func dashboard() throws -> ParentDashboard {
    try JSONDecoder().decode(ParentDashboard.self, from: Data(dashboardJSON.utf8))
}

private func service(_ transport: StubTransport) throws -> ParentControlAPI {
    try ParentControlAPI(
        server: ParentServer("http://1531server.local:8097"),
        serverID: "family",
        token: "companion-only",
        transport: transport
    )
}

private let capabilities = #"{"version":1,"serverID":"family","features":["durable-countdown-v1","show-availability-v1"]}"#

@Test(arguments: [
    "https://youtube.com/playlist?list=PLabcdefghijk",
    "https://www.youtube.com/watch?v=video&list=PLabcdefghijk",
    "https://youtu.be/video?list=PLabcdefghijk"
])
func `playlist canonicalization`(_ input: String) throws {
    #expect(try YouTubePlaylist(input).url.absoluteString == "https://www.youtube.com/playlist?list=PLabcdefghijk")
}

@Test(arguments: [
    "http://youtube.com/playlist?list=PLabcdefghijk",
    "https://youtube.com.evil.test/playlist?list=PLabcdefghijk",
    "https://youtube.com@evil.test/playlist?list=PLabcdefghijk",
    "https://youtube.com/playlist?list=PLabcdefghijk&list=PLdifferent",
    "https://youtube.com/playlist?list=../../etc/passwd",
    "https://youtube.com/watch?v=onlyVideo"
])
func `playlist rejects unexpected sources`(_ input: String) {
    #expect(throws: ParentControlError.invalidPlaylist) { try YouTubePlaylist(input) }
}

@Test
func `server validation`() throws {
    #expect(try ParentServer(" http://1531Server.local:8096/ ").url.absoluteString == "http://1531server.local:8096")
    for value in [
        "file:///Volumes/RAID",
        "https://user:secret@host",
        "http://host?token=secret",
        "http://host/%2e%2e/private",
        "http://host/#fragment"
    ] {
        #expect(throws: ParentControlError.invalidAddress) { try ParentServer(value) }
    }
}

@Test
func `countdown uses server duration and explicit bindings`() throws {
    let state = try dashboard()
    let request = try CountdownRequest(tv: state.televisions[0], minutes: 15, birdItemID: "birds", dashboard: state)
    #expect(request.durationSeconds == 900)
    #expect(request.expectedRevision == 7)
    #expect(request.childUserID == "kid")
    #expect(request.silent)
    #expect(throws: ParentControlError.invalidSelection) { try CountdownRequest(
        tv: state.televisions[0],
        minutes: 0,
        birdItemID: "birds",
        dashboard: state
    ) }
    #expect(throws: ParentControlError.invalidSelection) { try CountdownRequest(
        tv: state.televisions[0],
        minutes: 10,
        birdItemID: "adult-media",
        dashboard: state
    ) }
}

@Test
func `offline or old receiver cannot arm`() throws {
    for field in ["online", "canEnforceDeadline"] {
        let state = try JSONDecoder().decode(
            ParentDashboard.self,
            from: Data(dashboardJSON.replacingOccurrences(of: "\"\(field)\":true", with: "\"\(field)\":false").utf8)
        )
        #expect(throws: ParentControlError.invalidSelection) { try CountdownRequest(
            tv: state.televisions[0],
            minutes: 10,
            birdItemID: "birds",
            dashboard: state
        ) }
    }
}

@Test
func `no command before negotiation`() async throws {
    let transport = StubTransport([])
    let api = try service(transport)
    let state = try dashboard()
    await #expect(throws: ParentControlError.unsupported) { try await api.setAvailability(state.shows[0], enabled: false) }
    #expect(await transport.requests.isEmpty)
}

@Test
func `different server cannot receive control`() async throws {
    let transport = StubTransport([(200, capabilities.replacingOccurrences(of: "family", with: "other"))])
    let api = try service(transport)
    await #expect(throws: ParentControlError.serverMismatch) { try await api.connect() }
    await #expect(throws: ParentControlError.unsupported) { try await api.dashboard() }
    #expect(await transport.requests.count == 1)
}

@Test
func `unadvertised feature cannot write`() async throws {
    let transport = StubTransport([(200, #"{"version":1,"serverID":"family","features":[]}"#)])
    let api = try service(transport)
    _ = try await api.connect()
    let state = try dashboard()
    await #expect(throws: ParentControlError.unsupported) { try await api.countdown(CountdownRequest(
        tv: state.televisions[0],
        minutes: 10,
        birdItemID: "birds",
        dashboard: state
    )) }
    #expect(await transport.requests.count == 1)
}

@Test
func `commands carry idempotency and never claim playback`() async throws {
    let id = UUID()
    let transport = StubTransport([(200, capabilities), (202, "{\"commandID\":\"\(id)\",\"status\":\"persisted\"}")])
    let api = try service(transport)
    _ = try await api.connect()
    let state = try dashboard()
    let receipt = try await api.countdown(CountdownRequest(
        tv: state.televisions[0],
        minutes: 10,
        birdItemID: "birds",
        dashboard: state,
        commandID: id
    ))
    #expect(receipt.status == "persisted")
    let requests = await transport.requests
    #expect(requests.last?.value(forHTTPHeaderField: "Idempotency-Key") == id.uuidString)
    #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer companion-only")
    #expect(requests.last?.value(forHTTPHeaderField: "X-Emby-Token") == nil)
}

@Test(arguments: [true, false])
func `enforcement binds scoped revision and permits disabling offline`(_ enabled: Bool) async throws {
    let id = UUID()
    let transport = StubTransport([
        (200, #"{"version":1,"serverID":"family","features":["receiver-enforcement-v1"]}"#),
        (202, "{\"commandID\":\"\(id)\",\"status\":\"persisted\"}")
    ])
    let api = try service(transport)
    _ = try await api.connect()
    let json = dashboardJSON
        .replacingOccurrences(of: "\"online\":true", with: "\"online\":\(enabled)")
        .replacingOccurrences(of: "\"revision\":7", with: "\"revision\":7,\"enforcementEnabled\":\(!enabled)")
    let state = try JSONDecoder().decode(ParentDashboard.self, from: Data(json.utf8))
    let tv = state.televisions[0]
    let receipt = try await api.setEnforcement(tv: tv, enabled: enabled, commandID: id)

    #expect(receipt.commandID == id && receipt.status == "persisted")
    #expect(tv.enforcementEnabled == !enabled)
    let requests = await transport.requests
    let request = try #require(requests.last)
    #expect(request.url?.path == "/api/parent/v1/devices/tv/enforcement")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer companion-only")
    #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == id.uuidString)
    let body = try #require(request.httpBody)
    let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(Set(fields.keys) == Set(["commandID", "childUserID", "expectedRevision", "enabled"]))
    #expect(fields["commandID"] as? String == id.uuidString)
    #expect(fields["childUserID"] as? String == "kid")
    #expect(fields["expectedRevision"] as? Int == 7)
    #expect(fields["enabled"] as? Bool == enabled)
    #expect(requests.count == 2)
}

@Test
func `stale write rejected without retry`() async throws {
    let transport = StubTransport([(200, capabilities), (409, "")])
    let api = try service(transport)
    _ = try await api.connect()
    let state = try dashboard()
    await #expect(throws: ParentControlError.conflict) { try await api.setAvailability(state.shows[0], enabled: false) }
    #expect(await transport.requests.count == 2)
}

@Test
func `wrong receipt rejected`() async throws {
    let transport = StubTransport([(200, capabilities), (202, "{\"commandID\":\"\(UUID())\",\"status\":\"persisted\"}")])
    let api = try service(transport)
    _ = try await api.connect()
    let state = try dashboard()
    await #expect(throws: ParentControlError.malformedResponse) { try await api.setAvailability(state.shows[0], enabled: false) }
}

@Test
func `redirect cannot become success`() async throws {
    let transport = StubTransport([(302, capabilities)])
    let api = try service(transport)
    await #expect(throws: ParentControlError.http(302)) { try await api.connect() }
    #expect(await transport.requests.count == 1)
}

@Test
func `administrator sign in required`() async throws {
    let transport = StubTransport([(
        200,
        #"{"AccessToken":"token","ServerId":"family","User":{"Id":"kid","Name":"Kid","Policy":{"IsAdministrator":false}}}"#
    )])
    let api = try JellyfinParentAPI(server: ParentServer("http://server.local:8096"), transport: transport)
    await #expect(throws: ParentControlError.administratorRequired) { try await api.signIn(
        username: "kid",
        password: "not-logged",
        deviceID: UUID()
    ) }
}

@Test
func `catalog filters unapproved libraries`() async throws {
    let transport = StubTransport([(
        200,
        #"{"Items":[{"Id":"kids","Name":"Kid TV","CollectionType":"tvshows"},{"Id":"all","Name":"All Media","CollectionType":"tvshows"},{"Id":"adult","Name":"Adults","CollectionType":"movies"}]}"#
    )])
    let server = try ParentServer("http://server.local:8096")
    let api = JellyfinParentAPI(server: server, transport: transport)
    let account = ParentCredential(server: server, serverID: "family", userID: "parent", token: "token", name: "Parent")
    #expect(try await api.libraries(account).map(\.id) == ["kids"])
}

@Test(arguments: ["2026-10-17T02:30:00Z", "2026-10-17T02:30:00.123Z"])
func `server deadline accepts fractional timestamps`(_ date: String) async throws {
    let json = dashboardJSON.replacingOccurrences(
        of: "\"countdown\":null",
        with:
        "\"countdown\":{\"id\":\"schedule\",\"deadline\":\"\(date)\",\"birdItemID\":\"birds\",\"status\":\"persisted\"}"
    )
    let api = try service(StubTransport([(200, capabilities), (200, json)]))
    _ = try await api.connect()
    let state = try await api.dashboard()
    #expect(state.televisions[0].countdown?.status == "persisted")
}

@Test(arguments: ["revision", "other", "malformed", "412", "500", "network", "read"])
func `only exact parent mutation revision conflicts are retryable`(_ scenario: String) async throws {
    let status = scenario == "500" ? 500 : (scenario == "network" ? 0 : (scenario == "412" ? 412 : 409))
    let json = scenario == "other" ? #"{"error":"active_intent_exists"}"# :
        (scenario == "malformed" ? "not-json" : #"{"error":"revision_conflict"}"#)
    let transport = StubTransport([(status, json)])
    let http = try ParentHTTP(server: ParentServer("http://127.0.0.1:9"), transport: transport)
    do {
        let _: ParentCommandReceipt = try await http.request("api/parent/v1/test", method: "POST", parentMutation: scenario != "read")
        Issue.record("A failed request was accepted")
    } catch {
        if scenario == "revision" {
            #expect(error is ParentRevisionConflict)
        } else if scenario == "500" {
            #expect(error as? ParentControlError == .http(500))
        } else if scenario == "network" {
            #expect((error as? URLError)?.code == .networkConnectionLost)
        } else {
            #expect(error as? ParentControlError == .conflict)
        }
    }
    #expect(await transport.requests.count == 1)
}
