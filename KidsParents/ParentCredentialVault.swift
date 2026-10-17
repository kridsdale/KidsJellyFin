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

@MainActor
protocol ParentCredentialStore {
    func read<T: Decodable>(_ account: String, as type: T.Type) throws -> T?
    func write(_ value: some Encodable, account: String) throws
    func remove(_ account: String) throws
}

struct KeychainParentCredentialStore: ParentCredentialStore {
    func read<T: Decodable>(_ account: String, as type: T.Type) throws -> T? {
        try ParentCredentialVault.read(account, as: type)
    }

    func write(_ value: some Encodable, account: String) throws {
        try ParentCredentialVault.write(value, account: account)
    }

    func remove(_ account: String) throws {
        try ParentCredentialVault.remove(account)
    }
}

enum ParentCredentialVault {
    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.kridsdale.JellyfinPlayer.Parents",
            kSecAttrAccount as String: account
        ]
    }

    static func read<T: Decodable>(_ account: String, as type: T.Type) throws -> T? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else { throw VaultError.unavailable }
        return try JSONDecoder().decode(type, from: data)
    }

    static func write(_ value: some Encodable, account: String) throws {
        let query = query(account)
        let attributes: [String: Any] = try [
            kSecValueData as String: JSONEncoder().encode(value),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw VaultError.unavailable }
    }

    static func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.unavailable }
    }

    enum VaultError: Error, LocalizedError {
        case unavailable
        var errorDescription: String? {
            "Secure storage is unavailable. Unlock your iPhone and try again."
        }
    }
}
