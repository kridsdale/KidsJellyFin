//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation
import Security

/// Discovery carries a short-lived LAN proof, never a PIN, bearer or approval.
public struct LANParentAuthorizationNotice: Codable, Equatable, Sendable {
    public let version: Int
    public let serverID: String
    public let requestID: UUID
    public let lanNonce: String

    public init(serverID: String, requestID: UUID = UUID(), lanNonce: String) throws {
        guard !serverID.isEmpty, serverID.utf8.count <= 128, Self.validNonce(lanNonce) else {
            throw ParentControlError.invalidSelection
        }
        version = 1
        self.serverID = serverID
        self.requestID = requestID
        self.lanNonce = lanNonce
    }

    public static func fresh(serverID: String) throws -> Self {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ParentControlError.unauthorized
        }
        let nonce = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try Self(serverID: serverID, lanNonce: nonce)
    }

    public var isValid: Bool {
        version == 1 && !serverID.isEmpty && serverID.utf8.count <= 128 && Self.validNonce(lanNonce)
    }

    private static func validNonce(_ value: String) -> Bool {
        value.utf8.count == 43 && value.utf8.allSatisfy {
            (65 ... 90).contains($0) || (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

public struct ParentAuthorization: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, approved, denied, cancelled, expired }
    public let requestID: UUID
    public let serverID: String
    public let childUserID: String
    public let deviceID: String
    public let deviceName: String
    public let expiresAt: Date
    public let status: Status
    public var id: UUID {
        requestID
    }

    public init(
        requestID: UUID,
        serverID: String,
        childUserID: String,
        deviceID: String,
        deviceName: String,
        expiresAt: Date,
        status: Status
    ) {
        self.requestID = requestID
        self.serverID = serverID
        self.childUserID = childUserID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.expiresAt = expiresAt
        self.status = status
    }

    func validate(serverID: String, requestID: UUID) throws {
        guard self.serverID == serverID, self.requestID == requestID,
              !childUserID.isEmpty, UUID(uuidString: deviceID) != nil,
              !deviceName.isEmpty, deviceName.count <= 256,
              expiresAt.timeIntervalSinceNow <= 65 else { throw ParentControlError.malformedResponse }
    }
}

public extension ParentControlAPI {
    /// Resolve an untrusted Bonjour hint through the already configured adult service.
    func authorization(notice: LANParentAuthorizationNotice, wait: Bool = false) async throws -> ParentAuthorization {
        try require("parent-authorization-v1")
        guard notice.isValid else { throw ParentControlError.invalidSelection }
        try requireAuthorizationServer(notice.serverID)
        struct Lookup: Encodable { let requestID: String
            let lanNonce: String
        }
        let result: ParentAuthorization = try await http.request(
            "api/parent/v1/authorizations/lookup", method: "POST", headers: headers,
            query: wait ? [.init(name: "wait", value: "10")] : [], body: JSONEncoder().encode(Lookup(
                requestID: notice.requestID.uuidString.lowercased(),
                lanNonce: notice.lanNonce
            ))
        )
        try validateAuthorization(result, notice: notice)
        return result
    }

    func decideAuthorization(
        _ notice: LANParentAuthorizationNotice,
        approved: Bool,
        commandID: UUID = UUID()
    ) async throws -> ParentAuthorization {
        try require("parent-authorization-v1")
        guard notice.isValid else { throw ParentControlError.invalidSelection }
        try requireAuthorizationServer(notice.serverID)
        struct Decision: Encodable { let requestID: String
            let lanNonce: String
            let approved: Bool
            let commandID: String
        }
        var headers = headers
        headers["Idempotency-Key"] = commandID.uuidString.lowercased()
        let result: ParentAuthorization = try await http.request(
            "api/parent/v1/authorizations/decision", method: "POST", headers: headers,
            body: JSONEncoder().encode(Decision(
                requestID: notice.requestID.uuidString.lowercased(),
                lanNonce: notice.lanNonce,
                approved: approved,
                commandID: commandID.uuidString.lowercased()
            )),
            parentMutation: true
        )
        try validateAuthorization(result, notice: notice)
        return result
    }

    private func validateAuthorization(_ result: ParentAuthorization, notice: LANParentAuthorizationNotice) throws {
        // Compare the notice to the configured identity before trusting any response.
        try requireAuthorizationServer(notice.serverID)
        try result.validate(serverID: notice.serverID, requestID: notice.requestID)
    }
}
