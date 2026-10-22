//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation
import KidsParentControl
@testable import ParentsModelHarness
import Testing

@MainActor
private final class MemoryCredentials: ParentCredentialStore {
    var data: [String: Data] = [:]
    var writes = 0
    var rejectWrites = false
    struct WriteFailure: Error {}
    func read<T: Decodable>(_ account: String, as type: T.Type) throws -> T? {
        try data[account].map { try JSONDecoder().decode(type, from: $0) }
    }

    func write(_ value: some Encodable, account: String) throws {
        if rejectWrites {
            throw WriteFailure()
        }
        data[account] = try JSONEncoder().encode(value)
        writes += 1
    }

    func remove(_ account: String) throws {
        data[account] = nil
    }
}

private actor Suspension {
    let entered = AsyncStream<Void>.makeStream()
    var continuation: CheckedContinuation<Void, Never>?
    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.continuation.yield(())
        }
    }

    func waitUntilEntered() async {
        for await _ in entered.stream {
            break
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SyntheticTransport: ParentHTTPTransport {
    let suspension: Suspension
    let suspendedPath: String?
    var paths: [String] = []
    var logoutAuthorizations: [String] = []
    var mutationRequests: [URLRequest] = []
    var mutationFailures: [(status: Int, json: String)] = []
    var freshRevision = 1

    func setMutationFailures(_ failures: [(Int, String)]) {
        mutationFailures = failures
    }

    var features: [String] = []
    var capabilityStatus = 200
    var responses: [String: (json: String, status: Int)] = [:]

    func setResponse(path: String, json: String, status: Int = 200) {
        responses[path] = (json, status)
    }

    func setCapabilities(_ features: [String], status: Int = 200) {
        self.features = features
        capabilityStatus = status
    }

    init(suspension: Suspension = Suspension(), suspendedPath: String? = nil) {
        self.suspension = suspension
        self.suspendedPath = suspendedPath
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        paths.append(url.path)
        if url.path == "/Sessions/Logout", let authorization = request.value(forHTTPHeaderField: "Authorization") {
            logoutAuthorizations.append(authorization)
        }
        if url.path == suspendedPath {
            await suspension.suspend()
        }
        if request.httpMethod == "POST", url.path.hasPrefix("/api/parent/v1/") {
            mutationRequests.append(request)
            if !mutationFailures.isEmpty {
                let failure = mutationFailures.removeFirst()
                if failure.status == 0 {
                    throw URLError(.networkConnectionLost)
                }
                return try (
                    Data(failure.json.utf8),
                    #require(HTTPURLResponse(url: url, statusCode: failure.status, httpVersion: nil, headerFields: nil))
                )
            }
            let body = try #require(request.httpBody)
            let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let commandID = try #require(fields["commandID"] as? String)
            let data = try JSONSerialization.data(withJSONObject: ["commandID": commandID, "status": "persisted"])
            return try (data, #require(HTTPURLResponse(url: url, statusCode: 202, httpVersion: nil, headerFields: nil)))
        }
        if let response = responses[url.path] {
            let json = response.json.replacingOccurrences(of: "FRESH-REVISION", with: String(freshRevision))
            if response.json.contains("FRESH-REVISION") {
                freshRevision += 1
            }
            return try (
                Data(json.utf8),
                #require(HTTPURLResponse(url: url, statusCode: response.status, httpVersion: nil, headerFields: nil))
            )
        }
        let json: String
        switch url.path {
        case "/Users/AuthenticateByName":
            json = #"{"AccessToken":"synthetic-not-a-real-secret","ServerId":"family","User":{"Id":"adult","Name":"Synthetic adult","Policy":{"IsAdministrator":true}}}"#
        case "/Users/Me": json = #"{"Id":"adult","Name":"Synthetic adult","Policy":{"IsAdministrator":true}}"#
        case "/System/Info": json = #"{"Id":"family"}"#
        case "/Sessions": json = "[]"
        case "/UserViews": json = #"{"Items":[],"TotalRecordCount":0}"#
        case "/Sessions/Logout": json = ""
        case "/api/parent/v1/capabilities":
            let data = try JSONSerialization.data(withJSONObject: ["version": 1, "serverID": "family", "features": features])
            return try (data, #require(HTTPURLResponse(url: url, statusCode: capabilityStatus, httpVersion: nil, headerFields: nil)))
        case "/api/parent/v1/dashboard": json = #"{"serverID":"family","children":[],"televisions":[],"birdVideos":[],"shows":[]}"#
        default: throw ParentControlError.malformedResponse
        }
        return try (Data(json.utf8), #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}

@MainActor
struct ParentsLifecycleTests {
    private func credential() throws -> ParentCredential {
        try ParentCredential(
            server: ParentServer("http://127.0.0.1:9"),
            serverID: "family",
            userID: "adult",
            token: "synthetic",
            name: "Synthetic adult"
        )
    }

    @Test
    func `backgrounded sign in cannot store or expose its late session`() async {
        let storage = MemoryCredentials(), suspension = Suspension()
        let transport = SyntheticTransport(suspension: suspension, suspendedPath: "/Users/AuthenticateByName")
        let model = ParentsModel(credentialStore: storage, transport: transport, authenticateDevice: { false })
        model.serverText = "http://127.0.0.1:9"
        model.username = "synthetic"
        model.password = "synthetic"
        let signingIn = Task { await model.signIn() }
        await suspension.waitUntilEntered()
        model.lock()
        await suspension.release()
        await signingIn.value
        #expect(model.credential == nil)
        #expect(!model.signedIn)
        #expect(!model.busy)
        #expect(model.password.isEmpty)
        #expect(model.error == nil)
        #expect(storage.writes == 0)
        let paths = await transport.paths
        #expect(paths.filter { $0 == "/Sessions/Logout" }.count == 1)
    }

    @Test
    func `foreground sign in still stores and loads the validated adult`() async throws {
        let storage = MemoryCredentials(), transport = SyntheticTransport()
        let model = ParentsModel(credentialStore: storage, transport: transport, authenticateDevice: { false })
        model.serverText = "http://127.0.0.1:9"
        model.username = "synthetic"
        model.password = "synthetic"
        await model.signIn()
        #expect(model.signedIn)
        #expect(!model.locked)
        #expect(model.error == nil)
        #expect(model.password.isEmpty)
        #expect(storage.writes == 1)
        #expect(try storage.read("jellyfin", as: ParentCredential.self)?.userID == "adult")
    }

    @Test
    func `rejected secure storage cannot admit a new login`() async {
        let storage = MemoryCredentials(), transport = SyntheticTransport()
        storage.rejectWrites = true
        let model = ParentsModel(credentialStore: storage, transport: transport, authenticateDevice: { false })
        model.serverText = "http://127.0.0.1:9"
        model.username = "synthetic"
        model.password = "synthetic"
        await model.signIn()
        #expect(!model.signedIn)
        #expect(model.credential == nil)
        #expect(storage.data.isEmpty)
        #expect(model.error != nil)
        let paths = await transport.paths
        #expect(paths.filter { $0 == "/Sessions/Logout" }.count == 1)
    }

    @Test(arguments: ["success", "wrongAccount", "storageFailure", "background"])
    func `password unlock preserves saved pairing and retires only the correct session`(_ scenario: String) async throws {
        let storage = MemoryCredentials(), suspension = Suspension()
        let original = try credential()
        try storage.write(original, account: "jellyfin")
        try storage.write(ParentServiceConnection(
            server: original.server,
            serverID: original.serverID,
            adultUserID: original.userID,
            token: "synthetic-parent-pairing"
        ), account: "parentService")
        let savedPairing = storage.data["parentService"]
        let savedJellyfin = storage.data["jellyfin"]
        let transport = SyntheticTransport(
            suspension: suspension,
            suspendedPath: scenario == "background" ? "/Users/AuthenticateByName" : nil
        )
        let userID = scenario == "wrongAccount" ? "other-adult" : "adult"
        await transport.setResponse(
            path: "/Users/AuthenticateByName",
            json: #"{"AccessToken":"replacement-token","ServerId":"family","User":{"Id":"USER-ID","Name":"Synthetic adult","Policy":{"IsAdministrator":true}}}"#
                .replacingOccurrences(of: "USER-ID", with: userID)
        )
        await transport.setResponse(
            path: "/Users/Me",
            json: #"{"Id":"USER-ID","Name":"Synthetic adult","Policy":{"IsAdministrator":true}}"#
                .replacingOccurrences(of: "USER-ID", with: userID)
        )
        let model = ParentsModel(credentialStore: storage, transport: transport, authenticateDevice: { false })
        storage.rejectWrites = scenario == "storageFailure"
        model.password = "synthetic-adult-password"
        let unlocking = Task { await model.unlockWithPassword() }
        if scenario == "background" {
            await suspension.waitUntilEntered()
            model.lock()
            await suspension.release()
        }
        await unlocking.value

        #expect(model.password.isEmpty && !model.busy)
        #expect(storage.data["parentService"] == savedPairing)
        let logoutAuthorizations = await transport.logoutAuthorizations
        if scenario == "success" {
            #expect(!model.locked && model.error == nil)
            #expect(model.credential?.token == "replacement-token")
            #expect(try storage.read("jellyfin", as: ParentCredential.self)?.token == "replacement-token")
            #expect(model.controls != nil)
            #expect(logoutAuthorizations == ["MediaBrowser Token=\"synthetic\""])
        } else {
            #expect(model.locked)
            #expect(model.credential?.token == original.token)
            #expect(storage.data["jellyfin"] == savedJellyfin)
            #expect(logoutAuthorizations == ["MediaBrowser Token=\"replacement-token\""])
            #expect(model.error != nil || scenario == "background")
        }
    }

    @Test
    func `a late device authentication result cannot unlock after backgrounding`() async throws {
        let storage = MemoryCredentials(), suspension = Suspension(), transport = SyntheticTransport()
        try storage.write(credential(), account: "jellyfin")
        let model = ParentsModel(credentialStore: storage, transport: transport, authenticateDevice: {
            await suspension.suspend()
            return true
        })
        #expect(model.locked)
        let unlocking = Task { await model.unlock() }
        await suspension.waitUntilEntered()
        model.lock()
        await suspension.release()
        await unlocking.value
        #expect(model.locked)
        #expect(model.error == nil)
        let paths = await transport.paths
        #expect(paths.isEmpty)
    }

    @Test
    func `backgrounded control connection does not persist cleared credentials`() async throws {
        let storage = MemoryCredentials(), suspension = Suspension()
        try storage.write(credential(), account: "jellyfin")
        let transport = SyntheticTransport(suspension: suspension, suspendedPath: "/api/parent/v1/capabilities")
        let model = ParentsModel(credentialStore: storage, transport: transport, authenticateDevice: { false })
        model.locked = false // Synthetic already-unlocked fixture; no device prompt.
        model.controlServerText = "http://127.0.0.1:9"
        model.controlToken = "synthetic-parent-token"
        let connecting = Task { await model.connectControls() }
        await suspension.waitUntilEntered()
        model.lock()
        await suspension.release()
        await connecting.value
        #expect(model.locked)
        #expect(model.controls == nil)
        #expect(model.capabilities == nil)
        #expect(model.controlToken.isEmpty)
        #expect(try storage.read("parentService", as: ParentServiceConnection.self) == nil)
        #expect(storage.writes == 1) // Only the synthetic initial adult credential.
        let paths = await transport.paths
        #expect(!paths.contains("/api/parent/v1/dashboard"))
    }

    @Test
    func `connection persists the credential that was actually validated`() async throws {
        let storage = MemoryCredentials(), suspension = Suspension()
        try storage.write(credential(), account: "jellyfin")
        let transport = SyntheticTransport(suspension: suspension, suspendedPath: "/api/parent/v1/capabilities")
        let model = ParentsModel(credentialStore: storage, transport: transport, authenticateDevice: { false })
        model.locked = false
        model.controlServerText = "http://127.0.0.1:9"
        model.controlToken = "validated-original"
        let connecting = Task { await model.connectControls() }
        await suspension.waitUntilEntered()
        model.controlToken = "edited-during-request"
        model.controlServerText = "http://different.invalid"
        await suspension.release()
        await connecting.value
        let stored = try storage.read("parentService", as: ParentServiceConnection.self)
        let saved = try #require(stored)
        #expect(saved.token == "validated-original")
        #expect(saved.server.url.absoluteString == "http://127.0.0.1:9")
        #expect(model.error == nil)
    }

    @Test
    func `valid parent pairing survives an unavailable optional profile endpoint`() async throws {
        let storage = MemoryCredentials(), transport = SyntheticTransport()
        try storage.write(credential(), account: "jellyfin")
        await transport.setCapabilities(["show-availability-v1", "daily-budget-v1"])
        await transport.setResponse(
            path: "/api/parent/v1/dashboard",
            json: #"{"serverID":"family","children":[{"id":"kids","name":"Kids"}],"televisions":[],"birdVideos":[],"shows":[{"id":"bear","name":"Little Bear","childUserID":"kids","enabled":true,"revision":1}]}"#
        )
        await transport.setResponse(path: "/api/parent/v1/profiles/kids/settings", json: "{}", status: 404)
        let model = ParentsModel(credentialStore: storage, transport: transport, authenticateDevice: { false })
        model.locked = false
        model.controlServerText = "http://127.0.0.1:9"
        model.controlToken = "synthetic-scoped-parent-token"

        await model.connectControls()

        let stored = try storage.read("parentService", as: ParentServiceConnection.self)
        let saved = try #require(stored)
        #expect(saved.serverID == "family" && saved.adultUserID == "adult")
        #expect(saved.server.url.absoluteString == "http://127.0.0.1:9")
        #expect(saved.token == "synthetic-scoped-parent-token")
        #expect(model.controlToken.isEmpty)
        #expect(model.controls != nil && model.canChangeShows)
        #expect(model.dashboard?.children.first?.id == "kids")
        #expect(model.dashboard?.shows.first?.id == "bear")
        #expect(model.selectedChild == "kids")
        #expect(model.profile == nil)
        #expect(model.error == nil && !model.needsRefresh)
        let paths = await transport.paths
        #expect(paths.contains("/api/parent/v1/profiles/kids/settings"))
    }

    @Test(arguments: ["remote", "budget"], ["revision", "repeat", "other", "500", "network"])
    func `basic commands retry only one exact revision conflict with fresh scope`(_ target: String, _ failure: String) async throws {
        let storage = MemoryCredentials(), transport = SyntheticTransport()
        try storage.write(credential(), account: "jellyfin")
        await transport.setCapabilities(["remote-control-v1", "daily-budget-v1"])
        await transport.setResponse(
            path: "/api/parent/v1/dashboard",
            json: #"{"serverID":"family","children":[{"id":"kids","name":"Kids"}],"televisions":[{"id":"tv","name":"TV","childUserID":"kids","online":true,"canEnforceDeadline":true,"revision":FRESH-REVISION,"countdown":null}],"birdVideos":[],"shows":[]}"#
        )
        await transport.setResponse(
            path: "/api/parent/v1/profiles/kids/settings",
            json: #"{"childUserID":"kids","revision":FRESH-REVISION,"timeZone":"America/Los_Angeles","routines":[],"budget":{"enabled":false,"dailyMinutes":60,"usedSeconds":0,"bonusSeconds":0,"localDate":"2026-10-20"},"shuffle":{"preferUnwatched":false,"repeatCooldownDays":0,"preferredShowIDs":[]},"excludedEpisodeIDs":[]}"#
        )
        let model = ParentsModel(credentialStore: storage, transport: transport, authenticateDevice: { false })
        model.locked = false
        model.controlServerText = "http://127.0.0.1:9"
        model.controlToken = "synthetic-parent-token"
        await model.connectControls()
        let draft = try #require(model.profile)
        let revisionError = #"{"error":"revision_conflict"}"#
        switch failure {
        case "revision": await transport.setMutationFailures([(409, revisionError)])
        case "repeat": await transport.setMutationFailures([(409, revisionError), (409, revisionError)])
        case "other": await transport.setMutationFailures([(409, #"{"error":"active_intent_exists"}"#)])
        case "500": await transport.setMutationFailures([(500, "{}")])
        default: await transport.setMutationFailures([(0, "")])
        }
        if target == "remote" {
            await model.remote(.pause)
        } else {
            await model.saveBudget(enabled: true, minutes: 25, profile: draft)
        }

        let requests = await transport.mutationRequests
        let expectedCount = ["revision", "repeat"].contains(failure) ? 2 : 1
        #expect(requests.count == expectedCount)
        var commandIDs: [String] = [], revisions: [Int] = []
        for request in requests {
            let body = try #require(request.httpBody)
            let fields = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let commandID = try #require(fields["commandID"] as? String)
            commandIDs.append(commandID)
            try revisions.append(#require(fields["expectedRevision"] as? Int))
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == commandID)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-parent-token")
            #expect(fields["childUserID"] as? String == "kids")
            if target == "remote" {
                #expect(request.url?.path == "/api/parent/v1/remote")
                #expect(fields["deviceID"] as? String == "tv")
                #expect(fields["action"] as? String == "pause")
            } else {
                #expect(request.url?.path == "/api/parent/v1/budgets")
                #expect(fields["enabled"] as? Bool == true)
                #expect(fields["dailyMinutes"] as? Int == 25)
            }
        }
        #expect(Set(commandIDs).count == requests.count)
        #expect(revisions.first.map { $0 > draft.revision } == true)
        if requests.count == 2 {
            #expect(revisions[1] > revisions[0])
        }
        if failure == "revision" {
            #expect(model.error == nil && !model.needsRefresh)
            #expect(model.lastCommand?.status == "persisted")
        } else {
            #expect(model.error != nil && model.needsRefresh)
            #expect(model.lastCommand == nil)
        }
    }

    @Test
    func `an enforcement tap during a refresh is explained and can be retried when idle`() async throws {
        let storage = MemoryCredentials(), transport = SyntheticTransport()
        try storage.write(credential(), account: "jellyfin")
        await transport.setCapabilities(["receiver-enforcement-v1"])
        await transport.setResponse(
            path: "/api/parent/v1/dashboard",
            json: #"{"serverID":"family","children":[{"id":"kids","name":"Kids"}],"televisions":[{"id":"tv","name":"TV","childUserID":"kids","online":true,"canEnforceDeadline":true,"enforcementEnabled":false,"revision":1,"countdown":null}],"birdVideos":[],"shows":[]}"#
        )
        let model = ParentsModel(credentialStore: storage, transport: transport, authenticateDevice: { false })
        model.locked = false
        model.controlServerText = "http://127.0.0.1:9"
        model.controlToken = "synthetic-parent-token"
        await model.connectControls()
        model.busy = true // A read started after the UI rendered an enabled switch.
        await model.setEnforcement(enabled: true)
        #expect(await transport.mutationRequests.isEmpty)
        #expect(model.notice?.contains("still in progress") == true)
        #expect(model.chosenTV?.enforcementEnabled == false)
        model.busy = false
        await model.setEnforcement(enabled: true)
        #expect(await transport.mutationRequests.count == 1)
        #expect(model.error == nil && !model.needsRefresh)
        #expect(model.lastCommand?.status == "persisted")
        #expect(model.chosenTV?.enforcementEnabled == false) // The receipt cannot replace server state.
    }

    @Test
    func `backgrounding after a rejected command prevents its revision retry`() async throws {
        let storage = MemoryCredentials(), suspension = Suspension()
        try storage.write(credential(), account: "jellyfin")
        let transport = SyntheticTransport(suspension: suspension, suspendedPath: "/api/parent/v1/remote")
        await transport.setCapabilities(["remote-control-v1"])
        await transport.setResponse(
            path: "/api/parent/v1/dashboard",
            json: #"{"serverID":"family","children":[{"id":"kids","name":"Kids"}],"televisions":[{"id":"tv","name":"TV","childUserID":"kids","online":true,"canEnforceDeadline":true,"revision":1,"countdown":null}],"birdVideos":[],"shows":[]}"#
        )
        let model = ParentsModel(credentialStore: storage, transport: transport, authenticateDevice: { false })
        model.locked = false
        model.controlServerText = "http://127.0.0.1:9"
        model.controlToken = "synthetic-parent-token"
        await model.connectControls()
        await transport.setMutationFailures([(409, #"{"error":"revision_conflict"}"#)])
        let command = Task { await model.remote(.pause) }
        await suspension.waitUntilEntered()
        model.lock()
        await suspension.release()
        await command.value
        #expect(await transport.mutationRequests.count == 1)
        #expect(model.locked && model.needsRefresh)
        #expect(model.lastCommand == nil)
    }

    @Test
    func `unknown mutation cancellation still requires fresh state`() async {
        let model = ParentsModel(credentialStore: MemoryCredentials(), transport: SyntheticTransport(), authenticateDevice: { false })
        await model.perform { throw CancellationError() }
        #expect(model.needsRefresh)
        #expect(model.error != nil)
    }

    @Test
    func `refresh and polling discover enabled and revoked server capabilities`() async throws {
        let storage = MemoryCredentials(), transport = SyntheticTransport()
        try storage.write(credential(), account: "jellyfin")
        let model = ParentsModel(credentialStore: storage, transport: transport, authenticateDevice: { false })
        model.locked = false
        model.controlServerText = "http://127.0.0.1:9"
        model.controlToken = "synthetic-parent-token"
        await model.connectControls()
        #expect(model.controls != nil && !model.canChangeShows)
        await transport.setCapabilities(["show-availability-v1"])
        await model.refresh()
        #expect(model.canChangeShows)
        #expect(!model.needsRefresh && model.error == nil)
        await transport.setCapabilities([])
        await model.pollControls()
        #expect(!model.canChangeShows)
        #expect(model.capabilities?.features == [])
        let paths = await transport.paths
        #expect(paths.filter { $0 == "/api/parent/v1/capabilities" }.count == 3)
        #expect(paths.filter { $0 == "/api/parent/v1/dashboard" }.count == 3)
    }

    @Test
    func `failed capability refresh blocks writes until a fresh negotiation succeeds`() async throws {
        let storage = MemoryCredentials(), transport = SyntheticTransport()
        try storage.write(credential(), account: "jellyfin")
        await transport.setCapabilities(["show-availability-v1"])
        let model = ParentsModel(credentialStore: storage, transport: transport, authenticateDevice: { false })
        model.locked = false
        model.controlServerText = "http://127.0.0.1:9"
        model.controlToken = "synthetic-parent-token"
        await model.connectControls()
        #expect(model.canChangeShows)
        await transport.setCapabilities([], status: 503)
        await model.pollControls()
        #expect(model.needsRefresh && !model.canChangeShows)
        let beforeRecovery = await transport.paths
        #expect(beforeRecovery.filter { $0 == "/api/parent/v1/dashboard" }.count == 1)
        await transport.setCapabilities([])
        await model.pollControls()
        #expect(!model.needsRefresh && !model.canChangeShows)
        #expect(model.capabilities?.features == [])
    }

    @Test
    func `expired parent service can be replaced without losing Jellyfin or replaying commands`() async throws {
        let storage = MemoryCredentials(), transport = SyntheticTransport()
        try storage.write(credential(), account: "jellyfin")
        let originalJellyfin = storage.data["jellyfin"]
        await transport.setCapabilities(["show-availability-v1"])
        let model = ParentsModel(credentialStore: storage, transport: transport, authenticateDevice: { false })
        model.locked = false
        model.controlServerText = "http://127.0.0.1:9"
        model.controlToken = "synthetic-expired-service"
        await model.connectControls()
        #expect(model.canChangeShows)

        await transport.setCapabilities([], status: 401)
        await model.pollControls()
        #expect(model.signedIn && !model.locked)
        #expect(model.controls == nil && model.capabilities == nil && model.dashboard == nil)
        #expect(!model.canChangeShows)
        #expect(storage.data["jellyfin"] == originalJellyfin)
        let expired = try storage.read("parentService", as: ParentServiceConnection.self)
        #expect(expired?.token == "synthetic-expired-service")

        await model.refresh()
        #expect(model.controls == nil && !model.canChangeShows)
        #expect(model.error != nil)
        #expect(storage.data["jellyfin"] == originalJellyfin)

        await transport.setCapabilities(["show-availability-v1"])
        model.controlToken = "synthetic-replacement-service"
        await model.connectControls()
        #expect(model.controls != nil && model.canChangeShows)
        #expect(model.error == nil && !model.needsRefresh)
        #expect(model.controlToken.isEmpty)
        #expect(storage.data["jellyfin"] == originalJellyfin)
        let replacement = try storage.read("parentService", as: ParentServiceConnection.self)
        #expect(replacement?.token == "synthetic-replacement-service")
        let paths = await transport.paths
        #expect(!paths.contains("/Users/AuthenticateByName"))
        #expect(!paths.contains("/Sessions/Logout"))
        #expect(paths.filter { $0.hasPrefix("/api/parent/") }.allSatisfy {
            ["/api/parent/v1/capabilities", "/api/parent/v1/dashboard"].contains($0)
        })
    }

    @Test
    func `cached health becomes unknown at expiry or an unconfirmed clock`() throws {
        let model = ParentsModel(credentialStore: MemoryCredentials(), transport: SyntheticTransport(), authenticateDevice: { false })
        let observed = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(!model.healthIsCurrent(at: observed))
        let data = Data(
            #"{"observedAt":"2023-11-14T22:13:20Z","jellyfin":"healthy","worker":"idle","storageFreeBytes":1024,"pendingJobs":2,"failedJobs":0,"televisions":[{"id":"tv","name":"Television","online":true,"lastSeen":"2023-11-14T22:13:20Z"}],"issues":[]}"#
                .utf8
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        model.serverHealth = try decoder.decode(ParentServerHealth.self, from: data)
        #expect(model.healthIsCurrent(at: observed))
        #expect(model.healthIsCurrent(at: observed.addingTimeInterval(60)))
        #expect(!model.healthIsCurrent(at: observed.addingTimeInterval(60.001)))
        #expect(!model.healthIsCurrent(at: observed.addingTimeInterval(-0.001)))
        #expect(!model.healthIsCurrent(at: Date(timeIntervalSince1970: .infinity)))
        // Presentation expiry must preserve the historical observation and
        // cannot probe the server, change credentials, or issue a repair.
        #expect(model.serverHealth?.observedAt == observed)
        #expect(model.serverHealth?.pendingJobs == 2)
        #expect(model.serverHealth?.televisions.first?.online == true)
    }
}
