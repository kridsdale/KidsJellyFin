//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// Swiftfin is subject to the Mozilla Public License, v2.0.
import Foundation

/// These retain the existing on-device keychain accounts. They do not sync
/// credentials to iCloud and are independent of viewing-state persistence.
public enum CredentialKey: Hashable, Sendable {
    case accessToken(userID: String)
    case userPIN(userID: String)
    case parentPIN
    case receiverConfiguration

    var account: String {
        get throws {
            switch self {
            case let .accessToken(id):
                guard !id.isEmpty else { throw CredentialStoreError.invalidUserID }
                return "\(id)-accessToken"
            case let .userPIN(id):
                guard !id.isEmpty else { throw CredentialStoreError.invalidUserID }
                return "\(id)-pin"
            case .parentPIN:
                return "kids.parentPin.v1"
            case .receiverConfiguration:
                return "kids.receiver.configuration.v1"
            }
        }
    }
}

public enum CredentialStoreError: Error, Equatable, Sendable {
    public enum Operation: Sendable { case read, write, remove }
    case invalidUserID
    case invalidEncoding
    case system(operation: Operation, status: Int32)
}

/// The complete secure-storage port. No bulk enumeration/erase, native query,
/// access-group mutation, or secret-bearing diagnostics are exposed.
@MainActor
public protocol CredentialStore: AnyObject {
    func read(_ key: CredentialKey) throws -> String?
    func write(_ value: String, to key: CredentialKey) throws
    func remove(_ key: CredentialKey) throws
}
