//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import Security
@testable import SwiftfinCredentials
import Testing

@MainActor
private final class FakeSecurityDriver: SecurityItemDriving {
    var items: [String: Data] = [:]
    var queries: [[String: Any]] = []
    var operations: [String] = []
    var updates: [[String: Any]] = []
    var readStatus: Int32?
    var updateStatus: Int32?
    var addStatus: Int32?
    var removeStatus: Int32?
    var simulateRacingInsert = false
    func copy(_ query: [String: Any]) -> (status: Int32, data: Data?) {
        queries.append(query)
        operations.append("read")
        let data = items[query[kSecAttrAccount as String] as? String ?? ""]
        return (readStatus ?? (data == nil ? errSecItemNotFound : errSecSuccess), data)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> Int32 {
        queries.append(query)
        operations.append("update")
        updates.append(attributes)
        if let updateStatus {
            return updateStatus
        }
        let key = query[kSecAttrAccount as String] as? String ?? ""
        guard items[key] != nil else { return errSecItemNotFound }
        items[key] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func add(_ query: [String: Any]) -> Int32 {
        queries.append(query)
        operations.append("add")
        if let addStatus {
            return addStatus
        }
        let key = query[kSecAttrAccount as String] as? String ?? ""
        if simulateRacingInsert {
            items[key] = Data("racing-value".utf8)
            return errSecDuplicateItem
        }
        guard items[key] == nil else { return errSecDuplicateItem }
        items[key] = query[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> Int32 {
        queries.append(query)
        operations.append("delete")
        if let removeStatus {
            return removeStatus
        }
        let key = query[kSecAttrAccount as String] as? String ?? ""
        return items.removeValue(forKey: key) == nil ? errSecItemNotFound : errSecSuccess
    }
}

@MainActor
struct CredentialContracts {
    @Test
    func `legacy names and native query scope remain exact`() throws {
        let driver = FakeSecurityDriver()
        let store = KeychainCredentialStore(driver: driver)
        for (key, account) in [
            (CredentialKey.accessToken(userID: "kid"), "kid-accessToken"),
            (.userPIN(userID: "kid"), "kid-pin"),
            (.parentPIN, "kids.parentPin.v1"),
            (.receiverConfiguration, "kids.receiver.configuration.v1")
        ] {
            driver.items[account] = Data("synthetic-test-value".utf8)
            #expect(try store.read(key) == "synthetic-test-value")
            let query = try #require(driver.queries.last)
            #expect(Set(query.keys) == Set([kSecClass, kSecAttrAccount, kSecMatchLimit, kSecReturnData].map { $0 as String }))
            #expect(query[kSecAttrAccount as String] as? String == account)
            #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
            #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
            #expect(query[kSecReturnData as String] as? Bool == true)
        }
    }

    @Test
    func `failed replacement retains old credential and does not delete`() throws {
        let driver = FakeSecurityDriver()
        driver.items["kid-accessToken"] = Data("old-value".utf8)
        driver.updateStatus = errSecInteractionNotAllowed
        let store = KeychainCredentialStore(driver: driver)
        #expect(throws: CredentialStoreError.system(operation: .write, status: errSecInteractionNotAllowed)) {
            try store.write("new-value", to: .accessToken(userID: "kid"))
        }
        #expect(driver.items["kid-accessToken"] == Data("old-value".utf8))
        #expect(driver.operations == ["update"])
    }

    @Test
    func `successful replacement uses update and keeps default accessibility`() throws {
        let driver = FakeSecurityDriver()
        driver.items["kid-pin"] = Data("old-pin".utf8)
        let store = KeychainCredentialStore(driver: driver)
        try store.write("new-pin", to: .userPIN(userID: "kid"))
        #expect(try store.read(.userPIN(userID: "kid")) == "new-pin")
        #expect(driver.operations == ["update", "read"])
        let attributes = try #require(driver.updates.first)
        #expect(Set(attributes.keys) == Set([kSecValueData, kSecAttrAccessible].map { $0 as String }))
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlocked as String)
    }

    @Test
    func `absent credential adds without expanding namespace`() throws {
        let driver = FakeSecurityDriver()
        let store = KeychainCredentialStore(driver: driver)
        try store.write("new-value", to: .accessToken(userID: "kid"))
        #expect(driver.operations == ["update", "add"])
        let addition = try #require(driver.queries.last)
        #expect(Set(addition.keys) == Set([kSecClass, kSecAttrAccount, kSecValueData, kSecAttrAccessible].map { $0 as String }))
        #expect(addition[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlocked as String)
        #expect(try store.read(.accessToken(userID: "kid")) == "new-value")
    }

    @Test
    func `racing insert gets one bounded update without deleting`() throws {
        let driver = FakeSecurityDriver()
        driver.simulateRacingInsert = true
        let store = KeychainCredentialStore(driver: driver)
        try store.write("our-value", to: .accessToken(userID: "kid"))
        #expect(driver.operations == ["update", "add", "update"])
        #expect(driver.items["kid-accessToken"] == Data("our-value".utf8))
    }

    @Test
    func `failed add reports numeric error without publishing credential`() throws {
        let driver = FakeSecurityDriver()
        driver.addStatus = errSecAuthFailed
        let store = KeychainCredentialStore(driver: driver)
        #expect(throws: CredentialStoreError.system(operation: .write, status: errSecAuthFailed)) {
            try store.write("synthetic-test-value", to: .accessToken(userID: "kid"))
        }
        #expect(driver.items.isEmpty)
        #expect(driver.operations == ["update", "add"])
    }

    @Test
    func `absence is distinct from denied or malformed read`() throws {
        let driver = FakeSecurityDriver()
        let store = KeychainCredentialStore(driver: driver)
        #expect(try store.read(.parentPIN) == nil)
        driver.readStatus = errSecInteractionNotAllowed
        #expect(throws: CredentialStoreError.system(operation: .read, status: errSecInteractionNotAllowed)) { try store.read(.parentPIN) }
        driver.readStatus = nil
        driver.items["kids.parentPin.v1"] = Data([255])
        #expect(throws: CredentialStoreError.invalidEncoding) { try store.read(.parentPIN) }
    }

    @Test
    func `removing exact account leaves other accounts and missing is idempotent`() throws {
        let driver = FakeSecurityDriver()
        driver.items = ["kid-pin": Data("pin".utf8), "kid-accessToken": Data("token".utf8)]
        let store = KeychainCredentialStore(driver: driver)
        try store.remove(.userPIN(userID: "kid"))
        try store.remove(.userPIN(userID: "kid"))
        #expect(driver.items == ["kid-accessToken": Data("token".utf8)])
        driver.removeStatus = errSecInteractionNotAllowed
        #expect(throws: CredentialStoreError.system(operation: .remove, status: errSecInteractionNotAllowed)) {
            try store.remove(.accessToken(userID: "kid"))
        }
        #expect(driver.items["kid-accessToken"] == Data("token".utf8))
    }

    @Test
    func `invalid user ID cannot issue any native operation`() throws {
        let driver = FakeSecurityDriver()
        let store = KeychainCredentialStore(driver: driver)
        #expect(throws: CredentialStoreError.invalidUserID) { try store.read(.accessToken(userID: "")) }
        #expect(throws: CredentialStoreError.invalidUserID) { try store.write("value", to: .userPIN(userID: "")) }
        #expect(throws: CredentialStoreError.invalidUserID) { try store.remove(.userPIN(userID: "")) }
        #expect(driver.operations.isEmpty)
    }
}
