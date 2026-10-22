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

private actor FamilyTransport: ParentHTTPTransport {
    var requests: [URLRequest] = []
    var responses: [(Int, String)]
    init(_ responses: [(Int, String)]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else { throw ParentControlError.malformedResponse }
        let (code, text) = responses.removeFirst()
        return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

private let familyCapabilities = #"{"version":1,"serverID":"family","features":["finish-episode-v1","routines-v1","daily-budget-v1","bonus-time-v1","remote-control-v1","episode-exclusions-v1","review-inbox-v1","shuffle-preferences-v1","viewing-history-v1","health-v1"]}"#
private func familyAPI(_ transport: FamilyTransport) throws -> ParentControlAPI {
    try ParentControlAPI(
        server: ParentServer("http://192.168.10.100:8097"),
        serverID: "family",
        token: "parent-service-only",
        transport: transport
    )
}

private func profile() -> ParentProfileSettings {
    .init(
        childUserID: "kid",
        revision: 4,
        timeZone: "America/Los_Angeles",
        routines: [],
        budget: .init(enabled: true, dailyMinutes: 60, usedSeconds: 600, bonusSeconds: 0, localDate: "2026-10-17"),
        shuffle: .init(),
        excludedEpisodeIDs: []
    )
}

private func television() throws -> ControlledTV {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(
        ControlledTV.self,
        from: Data(
            #"{"id":"tv","name":"Living room","childUserID":"kid","online":true,"canEnforceDeadline":true,"revision":7,"countdown":{"id":"schedule","deadline":"2026-10-18T02:00:00Z","birdItemID":"birds","status":"delivered"}}"#
                .utf8
        )
    )
}

private func episode() throws -> ParentEpisode {
    try JSONDecoder().decode(
        ParentEpisode.self,
        from: Data(#"{"id":"ep","name":"Snow","showID":"bear","season":1,"episode":2,"excluded":false}"#.utf8)
    )
}

private enum FamilyWrite: String, CaseIterable, Sendable {
    case finish = "finish-episode"
    case routines
    case budget = "budgets"
    case countdownBonus = "bonuses"
    case remote
    case episode = "episodes/availability"
    case shuffle
}

@Test(arguments: FamilyWrite.allCases)
private func `feature writes have scoped revisioned bodies`(_ operation: FamilyWrite) async throws {
    let id = UUID()
    let transport = FamilyTransport([(200, familyCapabilities), (202, "{\"commandID\":\"\(id)\",\"status\":\"persisted\"}")])
    let api = try familyAPI(transport)
    _ = try await api.connect()
    let result: ParentCommandReceipt = switch operation {
    case .finish: try await api.finishEpisode(tv: television(), birdItemID: "birds", maximumMinutes: 30, commandID: id)
    case .routines: try await api.saveRoutines(
            profile: profile(),
            routines: [ViewingRoutine()],
            timeZone: "America/Los_Angeles",
            commandID: id
        )
    case .budget: try await api.saveBudget(profile: profile(), enabled: true, dailyMinutes: 45, commandID: id)
    case .countdownBonus: try await api.bonusTime(
            childUserID: "kid",
            tv: television(),
            target: .countdown,
            minutes: 10,
            profileRevision: 4,
            commandID: id
        )
    case .remote: try await api.remote(tv: television(), action: .skip, commandID: id)
    case .episode: try await api.setEpisode(profile: profile(), episode: episode(), excluded: true, commandID: id)
    case .shuffle: try await api.saveShuffle(
            profile: profile(),
            preferences: .init(preferUnwatched: true, repeatCooldownDays: 7, preferredShowIDs: ["bear"]),
            commandID: id
        )
    }
    #expect(result.status == "persisted")
    let request = try #require(await transport.requests.last)
    let requestData = try #require(request.httpBody)
    let decodedBody = try JSONSerialization.jsonObject(with: requestData)
    let body = try #require(decodedBody as? [String: Any])
    #expect(request.url?.path == "/api/parent/v1/\(operation.rawValue)")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == id.uuidString)
    #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
    #expect(body["childUserID"] as? String == "kid")
    #expect(body["commandID"] as? String == id.uuidString)
    #expect(body["expectedRevision"] as? Int == ([.finish, .countdownBonus, .remote].contains(operation) ? 7 : 4))
    if operation == .finish {
        #expect(body["maxDurationSeconds"] as? Int == 1800)
    }
    if operation == .countdownBonus {
        #expect(body["seconds"] as? Int == 600)
    }
    if operation == .remote {
        #expect(body["action"] as? String == "skip")
    }
    if operation == .episode {
        #expect(body["excluded"] as? Bool == true)
    }
}

@Test
func `all features require explicit capabilities`() async throws {
    let transport = FamilyTransport([(200, #"{"version":1,"serverID":"family","features":[]}"#)])
    let api = try familyAPI(transport)
    _ = try await api.connect()
    await #expect(throws: ParentControlError.unsupported) { try await api.saveRoutines(profile: profile(), routines: [], timeZone: "UTC") }
    await #expect(throws: ParentControlError.unsupported) { try await api.saveBudget(profile: profile(), enabled: true, dailyMinutes: 30) }
    await #expect(throws: ParentControlError.unsupported) { try await api.finishEpisode(
        tv: television(),
        birdItemID: "birds",
        maximumMinutes: 30
    ) }
    await #expect(throws: ParentControlError.unsupported) { try await api.bonusTime(
        childUserID: "kid",
        tv: nil,
        target: .budget,
        minutes: 10,
        profileRevision: 4
    ) }
    await #expect(throws: ParentControlError.unsupported) { try await api.remote(tv: television(), action: .pause) }
    await #expect(throws: ParentControlError.unsupported) {
        try await api.setEpisode(profile: profile(), episode: episode(), excluded: true)
    }
    await #expect(throws: ParentControlError.unsupported) { try await api.saveShuffle(profile: profile(), preferences: .init()) }
    await #expect(throws: ParentControlError.unsupported) { try await api.reviewInbox() }
    await #expect(throws: ParentControlError.unsupported) { try await api.history(childUserID: "kid") }
    await #expect(throws: ParentControlError.unsupported) { try await api.health() }
    #expect(await transport.requests.count == 1)
}

@Test
func `routine input rejects overnight and invalid days`() {
    let invalid = [
        ViewingRoutine(weekdays: []),
        ViewingRoutine(weekdays: [1, 1]),
        ViewingRoutine(weekdays: [0, 8]),
        ViewingRoutine(startMinute: 1080, endMinute: 900),
        ViewingRoutine(startMinute: 1440),
        ViewingRoutine(name: "  ")
    ]
    for rule in invalid {
        #expect(throws: ParentControlError.invalidRoutine) { try rule.validate() }
    }
}

@Test
func `routine and budget validation happens before network write`() async throws {
    let transport = FamilyTransport([(200, familyCapabilities)])
    let api = try familyAPI(transport)
    _ = try await api.connect()
    await #expect(throws: ParentControlError.invalidRoutine) { try await api.saveRoutines(
        profile: profile(),
        routines: [],
        timeZone: "No/Where"
    ) }
    let rule = ViewingRoutine()
    await #expect(throws: ParentControlError.invalidRoutine) { try await api.saveRoutines(
        profile: profile(),
        routines: [rule, rule],
        timeZone: "UTC"
    ) }
    await #expect(throws: ParentControlError.invalidBudget) { try await api.saveBudget(profile: profile(), enabled: true, dailyMinutes: -1)
    }
    await #expect(throws: ParentControlError.invalidBudget) {
        try await api.saveBudget(profile: profile(), enabled: true, dailyMinutes: 1441)
    }
    await #expect(throws: ParentControlError.invalidBudget) { try await api.bonusTime(
        childUserID: "kid",
        tv: nil,
        target: .budget,
        minutes: 61,
        profileRevision: 4
    ) }
    #expect(await transport.requests.count == 1)
}

@Test
func `countdown bonus cannot cross profiles`() async throws {
    let transport = FamilyTransport([(200, familyCapabilities)])
    let api = try familyAPI(transport)
    _ = try await api.connect()
    await #expect(throws: ParentControlError.invalidSelection) { try await api.bonusTime(
        childUserID: "other-child",
        tv: television(),
        target: .countdown,
        minutes: 10,
        profileRevision: 4
    ) }
    #expect(await transport.requests.count == 1)
}

@Test
func `budget bonus uses profile revision without TV target`() async throws {
    let id = UUID()
    let transport = FamilyTransport([(200, familyCapabilities), (200, "{\"commandID\":\"\(id)\",\"status\":\"persisted\"}")])
    let api = try familyAPI(transport)
    _ = try await api.connect()
    _ = try await api.bonusTime(childUserID: "kid", tv: nil, target: .budget, minutes: 10, profileRevision: 4, commandID: id)
    let request = try #require(await transport.requests.last)
    let requestData = try #require(request.httpBody)
    let decodedBody = try JSONSerialization.jsonObject(with: requestData)
    let body = try #require(decodedBody as? [String: Any])
    #expect(body["expectedRevision"] as? Int == 4)
    #expect(body["deviceID"] is NSNull)
    #expect(body["target"] as? String == "budget")
}

@Test
func `history cannot mix child accounts`() async throws {
    let transport = FamilyTransport([(200, familyCapabilities), (200, #"{"childUserID":"other","items":[],"nextCursor":null}"#)])
    let api = try familyAPI(transport)
    _ = try await api.connect()
    await #expect(throws: ParentControlError.malformedResponse) { try await api.history(childUserID: "kid") }
}

@Test
func `episode page cannot mix show membership`() async throws {
    let transport = FamilyTransport([
        (200, familyCapabilities),
        (
            200,
            #"{"childUserID":"kid","showID":"bear","items":[{"id":"adult","name":"No","showID":"other","excluded":false}],"nextCursor":null}"#
        )
    ])
    let api = try familyAPI(transport)
    _ = try await api.connect()
    await #expect(throws: ParentControlError.serverMismatch) { try await api.episodes(childUserID: "kid", showID: "bear") }
}

@Test
func `opaque pagination is escaped and bounded`() async throws {
    let transport = FamilyTransport([(200, familyCapabilities), (200, #"{"items":[],"nextCursor":null}"#)])
    let api = try familyAPI(transport)
    _ = try await api.connect()
    _ = try await api.reviewInbox(cursor: "a/b+=&scope=other")
    let request = try #require(await transport.requests.last)
    let query = try URLComponents(url: #require(request.url), resolvingAgainstBaseURL: false)?.queryItems
    #expect(query == [URLQueryItem(name: "cursor", value: "a/b+=&scope=other")])
    await #expect(throws: ParentControlError.invalidSelection) { try await api.reviewInbox(cursor: String(repeating: "x", count: 513)) }
    #expect(await transport.requests.count == 2)
}

@Test
func `health unknown is not zero`() async throws {
    let transport = FamilyTransport([
        (200, familyCapabilities),
        (
            200,
            #"{"observedAt":"2026-10-17T19:00:00Z","jellyfin":"unknown","worker":"unknown","storageFreeBytes":null,"pendingJobs":null,"failedJobs":null,"televisions":[],"issues":[]}"#
        )
    ])
    let api = try familyAPI(transport)
    _ = try await api.connect()
    let health = try await api.health()
    #expect(health.storageFreeBytes == nil)
    #expect(health.pendingJobs == nil)
    #expect(health.failedJobs == nil)
}

@Test
func `invalid health cannot be displayed as healthy`() async throws {
    let transport = FamilyTransport([
        (200, familyCapabilities),
        (
            200,
            #"{"observedAt":"2026-10-17T19:00:00Z","jellyfin":"healthy","worker":"idle","storageFreeBytes":-1,"pendingJobs":0,"failedJobs":0,"televisions":[],"issues":[]}"#
        )
    ])
    let api = try familyAPI(transport)
    _ = try await api.connect()
    await #expect(throws: ParentControlError.malformedResponse) { try await api.health() }
}

@Test
func `shuffle never accepts duplicate or path I ds`() {
    #expect(throws: ParentControlError.invalidPreferences) { try ParentShufflePreferences(repeatCooldownDays: 31).validate() }
    #expect(throws: ParentControlError.invalidPreferences) { try ParentShufflePreferences(preferredShowIDs: ["bear", "bear"]).validate() }
    #expect(throws: ParentControlError.invalidSelection) { try ParentShufflePreferences(preferredShowIDs: ["../adult"]).validate() }
}

@Test
func `rounded budget fields cannot reconstruct remaining permission`() {
    #expect(DailyViewingBudget(
        enabled: true,
        dailyMinutes: 60,
        usedSeconds: 5000,
        bonusSeconds: 0,
        localDate: "today",
        reservedSeconds: 0,
        unconfirmedSeconds: 0
    ).remainingSeconds == nil)
    #expect(DailyViewingBudget(
        enabled: true,
        dailyMinutes: 60,
        usedSeconds: 600,
        bonusSeconds: 600,
        localDate: "today",
        reservedSeconds: 30,
        unconfirmedSeconds: 10
    ).remainingSeconds == nil)
    #expect(DailyViewingBudget(
        enabled: true,
        dailyMinutes: Int.max,
        usedSeconds: 0,
        bonusSeconds: Int.max,
        localDate: "today",
        reservedSeconds: 0,
        unconfirmedSeconds: 0
    ).remainingSeconds == nil)
    // A displayed usedSeconds of1 may represent1.23. Naive integer arithmetic
    // would say119 remaining, whereas the full-precision server says118.
    #expect(DailyViewingBudget(
        enabled: true, dailyMinutes: 2, usedSeconds: 1, bonusSeconds: 0, localDate: "today",
        reservedSeconds: 0, unconfirmedSeconds: 0, serverRemainingSeconds: 118
    ).remainingSeconds == 118)
}

@Test
func `unknown reservations cannot be shown as available time`() {
    #expect(DailyViewingBudget(enabled: true, dailyMinutes: 60, usedSeconds: 0, bonusSeconds: 0, localDate: "today")
        .remainingSeconds == nil)
    #expect(DailyViewingBudget(enabled: true, dailyMinutes: 60, usedSeconds: 0, bonusSeconds: 0, localDate: "today", reservedSeconds: 30)
        .remainingSeconds == nil)
    #expect(DailyViewingBudget(
        enabled: true,
        dailyMinutes: 60,
        usedSeconds: 0,
        bonusSeconds: 0,
        localDate: "today",
        serverRemainingSeconds: 3450
    ).remainingSeconds == 3450)
}

@Test
func `routine writes use canonical UUI ds`() async throws {
    let routineID = try #require(UUID(uuidString: "ABCDEFAB-CDEF-4ABC-8DEF-ABCDEFABCDEF"))
    let commandID = try #require(UUID(uuidString: "FEDCBAFE-DCBA-4FED-8CBA-FEDCBAFEDCBA"))
    let routine = ViewingRoutine(id: routineID)
    let transport = FamilyTransport([
        (200, familyCapabilities),
        (202, "{\"commandID\":\"\(commandID)\",\"status\":\"persisted\"}")
    ])
    let api = try familyAPI(transport)
    _ = try await api.connect()
    _ = try await api.saveRoutines(profile: profile(), routines: [routine], timeZone: "UTC", commandID: commandID)
    let request = try #require(await transport.requests.last)
    let data = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let rows = try #require(body["routines"] as? [[String: Any]])
    #expect(rows.count == 1)
    let row = try #require(rows.first)
    #expect(Set(row.keys) == Set(["id", "name", "weekdays", "startMinute", "endMinute", "enabled"]))
    #expect(row["id"] as? String == "abcdefab-cdef-4abc-8def-abcdefabcdef")
    #expect(row["name"] as? String == "After school")
    #expect(row["weekdays"] as? [Int] == [1, 2, 3, 4, 5])
    #expect(row["startMinute"] as? Int == 900)
    #expect(row["endMinute"] as? Int == 1080)
    #expect(row["enabled"] as? Bool == true)
    #expect(body["timeZone"] as? String == "UTC")
    #expect(body["commandID"] as? String == commandID.uuidString)
    #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == commandID.uuidString)
    let roundTrip = try JSONDecoder().decode(ViewingRoutine.self, from: JSONSerialization.data(withJSONObject: row))
    #expect(roundTrip == routine)
    #expect(routine.id == routineID)
}
