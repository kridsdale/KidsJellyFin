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

private actor AuthorizationTransport: ParentHTTPTransport {
    var requests: [URLRequest] = []
    let authorization: ParentAuthorization
    init(_ authorization: ParentAuthorization) {
        self.authorization = authorization
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        let data: Data
        if url.path.hasSuffix("capabilities") {
            data = Data(#"{"version":1,"serverID":"family","features":["parent-authorization-v1"]}"#.utf8)
        } else {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(authorization)
        }
        return try (data, #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}

struct ParentAuthorizationTests {
    private func fixture(
        requestID: UUID = UUID(),
        child: String = "child",
        expires: Date = Date().addingTimeInterval(50)
    ) -> ParentAuthorization {
        ParentAuthorization(
            requestID: requestID,
            serverID: "family",
            childUserID: child,
            deviceID: "abcdefab-0000-4000-8000-000000000194",
            deviceName: "Family TV",
            expiresAt: expires,
            status: .pending
        )
    }

    @Test
    func `foreign discovery cannot send parent bearer`() async throws {
        let transport = AuthorizationTransport(fixture())
        let api = try ParentControlAPI(
            server: ParentServer("http://127.0.0.1:8097"),
            serverID: "family",
            token: "synthetic-parent",
            transport: transport
        )
        _ = try await api.connect()
        let notice = try LANParentAuthorizationNotice.fresh(serverID: "foreign")
        await #expect(throws: ParentControlError.serverMismatch) { try await api.authorization(notice: notice) }
        #expect(await transport.requests.count == 1)
    }

    @Test
    func `receiver rejects other child and other request`() async throws {
        let notice = try LANParentAuthorizationNotice.fresh(serverID: "family")
        for response in [fixture(requestID: notice.requestID, child: "other-child"), fixture()] {
            let transport = AuthorizationTransport(response)
            let api = try KidsReceiverAPI(
                server: ParentServer("http://127.0.0.1:8097"),
                serverID: "family",
                childUserID: "child",
                deviceID: response.deviceID,
                token: "synthetic-receiver",
                transport: transport
            )
            await #expect(throws: (any Error).self) { try await api.requestParentAuthorization(notice) }
        }
    }

    @Test
    func `canonical decision and bounded event wait`() async throws {
        let requestID = UUID(), commandID = UUID()
        let notice = try LANParentAuthorizationNotice(serverID: "family", requestID: requestID, lanNonce: String(repeating: "a", count: 43))
        let response = fixture(requestID: requestID)
        let transport = AuthorizationTransport(response)
        let api = try ParentControlAPI(
            server: ParentServer("http://127.0.0.1:8097"),
            serverID: "family",
            token: "synthetic-parent",
            transport: transport
        )
        _ = try await api.connect()
        _ = try await api.authorization(notice: notice, wait: true)
        _ = try await api.decideAuthorization(notice, approved: false, commandID: commandID)
        let requests = await transport.requests
        #expect(requests[1].url?.query == "wait=10")
        let requestBody = try #require(requests[2].httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(body["requestID"] as? String == requestID.uuidString.lowercased())
        #expect(body["commandID"] as? String == commandID.uuidString.lowercased())
        #expect(body["approved"] as? Bool == false)
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-parent")
        #expect(requests.allSatisfy { $0.url?.host == "127.0.0.1" })
    }

    @Test
    func `rejects extended expiry and invalid nonce`() throws {
        let response = fixture(expires: Date().addingTimeInterval(3600))
        #expect(throws: ParentControlError.malformedResponse) { try response.validate(serverID: "family", requestID: response.requestID) }
        #expect(throws: ParentControlError.invalidSelection) {
            try LANParentAuthorizationNotice(serverID: "family", lanNonce: "not-a-proof")
        }
    }
}
