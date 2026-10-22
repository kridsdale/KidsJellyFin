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

/// Models Jellyfin 12 with deprecated authorization disabled, including logout.
private actor ModernJellyfinTransport: ParentHTTPTransport {
    var requests: [URLRequest] = []
    let administrator: Bool
    let authenticationStatus: Int
    let validationStatus: Int
    let serverID: String
    let logoutStatus: Int

    init(
        administrator: Bool = true,
        authenticationStatus: Int = 200,
        validationStatus: Int = 200,
        serverID: String = "family",
        logoutStatus: Int = 204
    ) {
        self.administrator = administrator
        self.authenticationStatus = authenticationStatus
        self.validationStatus = validationStatus
        self.serverID = serverID
        self.logoutStatus = logoutStatus
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = try #require(request.url?.path)
        var status = 200
        var body = ""
        if path == "/Users/AuthenticateByName" {
            status = authenticationStatus
            body = "{\"AccessToken\":\"synthetic-token\",\"ServerId\":\"family\",\"User\":{\"Id\":\"adult\",\"Name\":\"Parent\",\"Policy\":{\"IsAdministrator\":\(administrator)}}}"
        } else if request.value(forHTTPHeaderField: "Authorization") != "MediaBrowser Token=\"synthetic-token\"" {
            status = 401
        } else {
            switch path {
            case "/Users/Me":
                status = validationStatus
                body = #"{"Id":"adult","Name":"Parent","Policy":{"IsAdministrator":true}}"#
            case "/System/Info": body = "{\"Id\":\"\(serverID)\"}"
            case "/Sessions": body = "[]"
            case "/UserViews": body = #"{"Items":[],"TotalRecordCount":0}"#
            case "/Sessions/Logout": status = logoutStatus
            default: throw ParentControlError.malformedResponse
            }
        }
        return try (Data(body.utf8), #require(HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )))
    }
}

@Test
func `modern Jellyfin sign in validates refreshes and logs out without legacy headers`() async throws {
    let transport = ModernJellyfinTransport()
    let api = try JellyfinParentAPI(server: ParentServer("http://server.local:8096"), transport: transport)
    let device = UUID()
    let credential = try await api.signIn(username: "parent", password: "synthetic-password", deviceID: device)
    #expect(credential.userID == "adult")
    #expect(credential.serverID == "family")
    _ = try await api.sessions(credential)
    _ = try await api.libraries(credential)
    try await api.signOut(credential)
    let requests = await transport.requests
    let login = try #require(requests.first)
    #expect(login.value(forHTTPHeaderField: "Authorization")?.contains("DeviceId=\"\(device.uuidString)\"") == true)
    let body = try JSONSerialization.jsonObject(with: #require(login.httpBody)) as? [String: String]
    #expect(body == ["Username": "parent", "Pw": "synthetic-password"])
    for request in requests.dropFirst() {
        #expect(request.value(forHTTPHeaderField: "Authorization") == "MediaBrowser Token=\"synthetic-token\"")
        #expect(request.value(forHTTPHeaderField: "X-Emby-Token") == nil)
    }
    #expect(requests.last?.url?.path == "/Sessions/Logout")
}

private enum RejectedLogin: CaseIterable, Sendable {
    case nonAdministrator
    case unauthorizedValidation
    case wrongServer
    case failedRetirement
}

@Test(arguments: RejectedLogin.allCases)
private func `rejected issued sessions attempt exact retirement and preserve the original failure`(_ kind: RejectedLogin) async throws {
    let transport: ModernJellyfinTransport
    let expected: ParentControlError
    switch kind {
    case .nonAdministrator:
        transport = ModernJellyfinTransport(administrator: false)
        expected = .administratorRequired
    case .unauthorizedValidation:
        transport = ModernJellyfinTransport(validationStatus: 401)
        expected = .unauthorized
    case .wrongServer:
        transport = ModernJellyfinTransport(serverID: "different-family")
        expected = .serverMismatch
    case .failedRetirement:
        transport = ModernJellyfinTransport(validationStatus: 401, logoutStatus: 503)
        expected = .unauthorized
    }
    let api = try JellyfinParentAPI(server: ParentServer("http://server.local:8096"), transport: transport)
    await #expect(throws: expected) {
        try await api.signIn(username: "parent", password: "synthetic-password", deviceID: UUID())
    }
    let retirements = await transport.requests.filter { $0.url?.path == "/Sessions/Logout" }
    #expect(retirements.count == 1)
    #expect(retirements.first?.httpMethod == "POST")
    #expect(retirements.first?.value(forHTTPHeaderField: "Authorization") == "MediaBrowser Token=\"synthetic-token\"")
}

@Test
func `failed authentication does not invent a session to retire`() async throws {
    let transport = ModernJellyfinTransport(authenticationStatus: 401)
    let api = try JellyfinParentAPI(server: ParentServer("http://server.local:8096"), transport: transport)
    await #expect(throws: ParentControlError.unauthorized) {
        try await api.signIn(username: "parent", password: "synthetic-password", deviceID: UUID())
    }
    #expect(await transport.requests.count == 1)
}

@Test(arguments: ["", "token\r\nInjected: value", "token\"", "token\\", "token space"])
func `malformed credential cannot create an authorization header`(_ token: String) async throws {
    let transport = ModernJellyfinTransport()
    let server = try ParentServer("http://server.local:8096")
    let api = JellyfinParentAPI(server: server, transport: transport)
    let credential = ParentCredential(server: server, serverID: "family", userID: "adult", token: token, name: "Parent")
    await #expect(throws: ParentControlError.unauthorized) { try await api.sessions(credential) }
    #expect(await transport.requests.isEmpty)
}
