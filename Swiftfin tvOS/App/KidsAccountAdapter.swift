//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import FactoryKit
import Foundation
import JellyfinAPI
import KidsAccounts
import KidsCatalog
import KidsDomain
import SwiftfinAccountAccess
import SwiftfinAccountModels
import SwiftfinAccountStore
import SwiftfinCredentials
import SwiftfinNetworking

// SPDX-License-Identifier: MPL-2.0
import SwiftfinStoredValues

/// Composition adapter for the retained Swiftfin secure account lifecycle.
/// No SDK user, global container, or Keychain type crosses the kids account port.
@MainActor
final class SwiftfinKidsAccountHost: KidsAccountHost {
    private let sessions: UserSessionManager

    init(sessions: UserSessionManager) {
        self.sessions = sessions
    }

    private static func identity(from session: UserSession?) -> KidsAccountIdentity? {
        guard let session else { return nil }
        return KidsAccountIdentity(
            serverURL: session.server.effectiveServerURL,
            serverID: session.server.id,
            serverName: session.server.name,
            userID: session.user.id,
            accessToken: session.user.accessToken
        )
    }

    var currentIdentity: KidsAccountIdentity? {
        Self.identity(from: sessions.currentSession)
    }

    var identityChanges: AnyPublisher<KidsAccountIdentity?, Never> {
        sessions.$currentSession
            .map { session in MainActor.assumeIsolated { Self.identity(from: session) } }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    var parentPIN: String? {
        get throws { try Container.shared.keychainService().read(.parentPIN) }
    }

    func storeParentPIN(_ pin: String) throws {
        try Container.shared.keychainService().write(pin, to: .parentPIN)
    }

    var receiverConfiguration: KidsReceiverConfiguration? {
        get throws {
            guard let value = try Container.shared.keychainService().read(.receiverConfiguration),
                  let data = value.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode(KidsReceiverConfiguration.self, from: data)
        }
    }

    func storeReceiverConfiguration(_ configuration: KidsReceiverConfiguration?) throws {
        if let configuration {
            let data = try JSONEncoder().encode(configuration)
            guard let value = String(data: data, encoding: .utf8) else { throw KidsContractError.denied }
            try Container.shared.keychainService().write(value, to: .receiverConfiguration)
        } else {
            try Container.shared.keychainService().remove(.receiverConfiguration)
        }
    }

    func authenticate(
        url: URL,
        serverID: String,
        serverName: String,
        username: String,
        password: String
    ) async throws -> KidsAuthenticatedAccount {
        let client = JellyfinTransport.swiftfin(url: url, policy: .systemDefault, logging: false)
        let access = AccountAccessClient(transport: client, expectedServerID: serverID)
        let result: AccountAuthentication
        do {
            result = try await access.signIn(username: username, password: password, fallbackUsername: username)
        } catch is AccountAccessError {
            throw KidsAPIError.authentication
        }
        let identity = KidsAccountIdentity(
            serverURL: url,
            serverID: serverID,
            serverName: serverName,
            userID: result.userID,
            accessToken: result.accessToken
        )
        let server = ServerState(urls: [url], currentURL: url, name: serverName, id: serverID, userIDs: [result.userID])
        let saved = UserState(id: result.userID, serverID: serverID, username: result.username)
        return KidsAuthenticatedAccount(identity: identity, credentialStorage: { validate in
            try validate()
            let store = Container.shared.localAccountStore()
            try store.saveAuthenticatedAccount(server, user: saved, accessToken: result.accessToken)
            try validate()
            saved.data = result.user
            try validate()
            saved.accessPolicy = .none
        }) { [sessions] validate in
            try await sessions.signIn(userID: result.userID, serverID: serverID, validate: validate) { session in
                guard Self.identity(from: session) == identity else { throw KidsContractError.denied }
            }
        }
    }

    func signOut(validate: @escaping KidsAccountCheckpoint) async throws {
        try await sessions.signOut(reason: .explicit, validate: validate)
    }
}
