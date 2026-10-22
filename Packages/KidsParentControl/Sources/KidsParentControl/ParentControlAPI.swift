//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Proposed v1 companion contract. Capability negotiation must succeed before writes.
/// Uses a separately provisioned companion token; never forwards a Jellyfin admin token.
public actor ParentControlAPI {
    let http: ParentHTTP
    private let serverID: String
    let headers: [String: String]
    private var capabilities: ParentCapabilities?

    public init(server: ParentServer, serverID: String, token: String, transport: any ParentHTTPTransport = ParentURLTransport()) {
        http = ParentHTTP(server: server, transport: transport)
        self.serverID = serverID
        headers = ["Authorization": "Bearer \(token)"]
    }

    func requireAuthorizationServer(_ value: String) throws {
        guard value == serverID else { throw ParentControlError.serverMismatch }
    }

    public func connect() async throws -> ParentCapabilities {
        capabilities = nil
        let value: ParentCapabilities = try await http.request("api/parent/v1/capabilities", headers: headers)
        guard value.serverID == serverID else { throw ParentControlError.serverMismatch }
        guard value.version == 1 else { throw ParentControlError.unsupported }
        capabilities = value
        return value
    }

    public func dashboard() async throws -> ParentDashboard {
        guard capabilities != nil else { throw ParentControlError.unsupported }
        let value: ParentDashboard = try await http.request("api/parent/v1/dashboard", headers: headers)
        guard value.serverID == serverID else { throw ParentControlError.serverMismatch }
        return value
    }

    public func setEnforcement(tv: ControlledTV, enabled: Bool, commandID: UUID = UUID()) async throws -> ParentCommandReceipt {
        try require("receiver-enforcement-v1")
        guard tv.enforcementEnabled != nil, tv.revision >= 0, !enabled || tv.online else {
            throw ParentControlError.invalidSelection
        }
        let deviceID = try ParentHTTP.identifier(tv.id)
        _ = try ParentHTTP.identifier(tv.childUserID)
        struct Enforcement: Encodable {
            let commandID: UUID
            let childUserID: String
            let expectedRevision: Int
            let enabled: Bool
        }
        return try await command(
            "devices/\(deviceID)/enforcement",
            value: Enforcement(
                commandID: commandID,
                childUserID: tv.childUserID,
                expectedRevision: tv.revision,
                enabled: enabled
            ),
            id: commandID
        )
    }

    public func countdown(_ request: CountdownRequest) async throws -> ParentCommandReceipt {
        try require("durable-countdown-v1")
        return try await command("countdowns", value: request, id: request.commandID)
    }

    public func cancelCountdown(tv: ControlledTV, commandID: UUID = UUID()) async throws -> ParentCommandReceipt {
        try require("durable-countdown-v1")
        struct Cancel: Encodable { let commandID: UUID
            let deviceID: String
            let childUserID: String
            let expectedRevision: Int
        }
        return try await command("countdowns/cancel", value: Cancel(
            commandID: commandID,
            deviceID: tv.id,
            childUserID: tv.childUserID,
            expectedRevision: tv.revision
        ), id: commandID)
    }

    public func setAvailability(_ show: ShowAvailability, enabled: Bool, commandID: UUID = UUID()) async throws -> ParentCommandReceipt {
        try require("show-availability-v1")
        struct Availability: Encodable {
            let commandID: UUID
            let showID: String
            let childUserID: String
            let enabled: Bool
            let expectedRevision: Int
        }
        return try await command(
            "shows/availability",
            value: Availability(
                commandID: commandID,
                showID: show.id,
                childUserID: show.childUserID,
                enabled: enabled,
                expectedRevision: show.revision
            ),
            id: commandID
        )
    }

    func require(_ name: String) throws {
        guard capabilities?.supports(name) == true else { throw ParentControlError.unsupported }
    }

    func requireConnected() throws {
        guard capabilities != nil else { throw ParentControlError.unsupported }
    }

    func command(_ path: String, value: some Encodable, id: UUID) async throws -> ParentCommandReceipt {
        var headers = headers
        headers["Idempotency-Key"] = id.uuidString
        let receipt: ParentCommandReceipt = try await http.request(
            "api/parent/v1/\(path)",
            method: "POST",
            headers: headers,
            body: JSONEncoder().encode(value),
            parentMutation: true
        )
        guard receipt.commandID == id else { throw ParentControlError.malformedResponse }
        return receipt
    }
}
