//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Combine
import Foundation
import KidsDomain

/// Full network identity. Credential replacement is an identity change even for the same user.
/// Descriptions deliberately disclose no credentials or household connection details.
public struct KidsAccountIdentity: Equatable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let serverURL: URL
    public let serverID: String
    public let serverName: String
    public let userID: String
    public let accessToken: String

    public init(serverURL: URL, serverID: String, serverName: String, userID: String, accessToken: String) {
        self.serverURL = serverURL
        self.serverID = serverID
        self.serverName = serverName
        self.userID = userID
        self.accessToken = accessToken
    }

    public var description: String {
        "KidsAccountIdentity(redacted)"
    }

    public var debugDescription: String {
        description
    }

    // A display-name change must not invalidate an otherwise identical authorized stream.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.serverURL == rhs.serverURL && lhs.serverID == rhs.serverID &&
            lhs.userID == rhs.userID && lhs.accessToken == rhs.accessToken
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(serverURL)
        hasher.combine(serverID)
        hasher.combine(userID)
        hasher.combine(accessToken)
    }

    public func matches(_ binding: KidsBinding) -> Bool {
        binding.isValid && serverID == binding.serverID && userID == binding.userID
    }
}

public typealias KidsAccountCheckpoint = @MainActor @Sendable () throws -> Void

/// Separate device-scoped secret, never the child's Jellyfin access token.
public struct KidsReceiverConfiguration: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let serviceURL: URL
    public let serverID: String
    public let childUserID: String
    public let deviceID: UUID
    public let token: String
    public let activated: Bool
    public let latchedControlID: UUID?
    public let requiresPlaybackGrants: Bool
    public init(
        serviceURL: URL,
        serverID: String,
        childUserID: String,
        deviceID: UUID,
        token: String,
        activated: Bool = false,
        latchedControlID: UUID? = nil,
        requiresPlaybackGrants: Bool = false
    ) {
        self.serviceURL = serviceURL
        self.serverID = serverID
        self.childUserID = childUserID
        self.deviceID = deviceID
        self.token = token
        self.activated = activated
        self.latchedControlID = latchedControlID
        self.requiresPlaybackGrants = requiresPlaybackGrants
    }

    private enum CodingKeys: String, CodingKey {
        case serviceURL
        case serverID
        case childUserID
        case deviceID
        case token
        case activated
        case latchedControlID
        case requiresPlaybackGrants
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serviceURL = try values.decode(URL.self, forKey: .serviceURL)
        serverID = try values.decode(String.self, forKey: .serverID)
        childUserID = try values.decode(String.self, forKey: .childUserID)
        deviceID = try values.decode(UUID.self, forKey: .deviceID)
        token = try values.decode(String.self, forKey: .token)
        activated = try values.decode(Bool.self, forKey: .activated)
        latchedControlID = try values.decodeIfPresent(UUID.self, forKey: .latchedControlID)
        requiresPlaybackGrants = try values.decodeIfPresent(Bool.self, forKey: .requiresPlaybackGrants) ?? false
    }

    public var description: String {
        "KidsReceiverConfiguration(redacted)"
    }

    public var debugDescription: String {
        description
    }
}

/// SDK-specific authentication data stays inside the host's activation closure.
/// The application must verify policy and the exact libraries before activation.
@MainActor
public final class KidsAuthenticatedAccount {
    public let identity: KidsAccountIdentity
    private let credentialStorage: @MainActor (KidsAccountCheckpoint) throws -> Void
    private let activation: @MainActor (@escaping KidsAccountCheckpoint) async throws -> Void
    private var preparedBinding: KidsBinding?

    public init(
        identity: KidsAccountIdentity,
        credentialStorage: @escaping @MainActor (KidsAccountCheckpoint) throws -> Void = { try $0() },
        activation: @escaping @MainActor (@escaping KidsAccountCheckpoint) async throws -> Void
    ) {
        self.identity = identity
        self.credentialStorage = credentialStorage
        self.activation = activation
    }

    /// Each preparation revokes earlier authority, including a failed retry.
    public func prepareActivation(
        binding: KidsBinding,
        validate: @escaping KidsAccountCheckpoint = { try Task.checkCancellation() }
    ) throws {
        preparedBinding = nil
        try validate()
        guard identity.matches(binding) else { throw KidsContractError.denied }
        try credentialStorage(validate)
        try validate()
        preparedBinding = binding
    }

    /// Preparation is consumed before suspension. The host checks before native publication.
    public func activate(binding: KidsBinding, validate: @escaping KidsAccountCheckpoint = { try Task.checkCancellation() }) async throws {
        try validate()
        guard preparedBinding == binding, identity.matches(binding) else { throw KidsContractError.denied }
        preparedBinding = nil
        try await activation(validate)
        try validate()
    }
}

/// Account lifecycle and secure local credentials belong to the application host.
/// Catalog/policy authorization and playback progress belong to their own libraries.
@MainActor
public protocol KidsAccountHost: AnyObject {
    var currentIdentity: KidsAccountIdentity? { get }
    /// Deliver identity changes synchronously on the main actor, including credential replacement.
    var identityChanges: AnyPublisher<KidsAccountIdentity?, Never> { get }
    var parentPIN: String? { get throws }
    func storeParentPIN(_ pin: String) throws
    func authenticate(
        url: URL,
        serverID: String,
        serverName: String,
        username: String,
        password: String
    ) async throws -> KidsAuthenticatedAccount
    func signOut(validate: @escaping KidsAccountCheckpoint) async throws
    var receiverConfiguration: KidsReceiverConfiguration? { get throws }
    func storeReceiverConfiguration(_ configuration: KidsReceiverConfiguration?) throws
}

public extension KidsAccountHost {
    var receiverConfiguration: KidsReceiverConfiguration? {
        get throws { nil }
    }

    func storeReceiverConfiguration(_ configuration: KidsReceiverConfiguration?) throws {
        throw KidsContractError.denied
    }
}
