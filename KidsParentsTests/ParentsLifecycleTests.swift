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
    var features: [String] = []
    var capabilityStatus = 200

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
        if url.path == suspendedPath {
            await suspension.suspend()
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
}
