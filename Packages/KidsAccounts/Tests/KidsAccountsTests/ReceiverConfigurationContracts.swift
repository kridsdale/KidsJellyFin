//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
@testable import KidsAccounts
import Testing

@Test
func `receiver credentials redact both descriptions`() throws {
    let configuration = try KidsReceiverConfiguration(
        serviceURL: #require(URL(string: "http://private-household.local:8097")),
        serverID: "server",
        childUserID: "child",
        deviceID: UUID(),
        token: "synthetic-receiver-secret"
    )
    for description in [String(describing: configuration), String(reflecting: configuration)] {
        #expect(!description.contains("synthetic-receiver-secret"))
        #expect(!description.contains("private-household"))
    }
    #expect(!configuration.activated)
}

@Test
func `activation and explicit end latch survive credential round trip`() throws {
    let commandID = UUID()
    let configuration = try KidsReceiverConfiguration(
        serviceURL: #require(URL(string: "http://server.local:8097")),
        serverID: "server",
        childUserID: "child",
        deviceID: UUID(),
        token: "synthetic",
        activated: true,
        latchedControlID: commandID
    )
    let restored = try JSONDecoder().decode(KidsReceiverConfiguration.self, from: JSONEncoder().encode(configuration))
    #expect(restored.activated)
    #expect(restored.latchedControlID == commandID)
    #expect(restored.deviceID == configuration.deviceID)
    #expect(restored.childUserID == configuration.childUserID)
}

@Test
func `explicit grant mode survives storage while legacy configuration stays legacy`() throws {
    let configuration = try KidsReceiverConfiguration(
        serviceURL: #require(URL(string: "http://server.local:8097")), serverID: "server", childUserID: "child", deviceID: UUID(),
        token: "synthetic", activated: true, requiresPlaybackGrants: true
    )
    let encoded = try JSONEncoder().encode(configuration)
    let restored = try JSONDecoder().decode(KidsReceiverConfiguration.self, from: encoded)
    #expect(restored == configuration)
    #expect(restored.requiresPlaybackGrants && restored.activated)
    let decoded = try JSONSerialization.jsonObject(with: encoded)
    var legacy = try #require(decoded as? [String: Any])
    legacy.removeValue(forKey: "requiresPlaybackGrants")
    let oldData = try JSONSerialization.data(withJSONObject: legacy)
    let old = try JSONDecoder().decode(KidsReceiverConfiguration.self, from: oldData)
    #expect(!old.requiresPlaybackGrants)
    #expect(old.activated)
    legacy["requiresPlaybackGrants"] = "true"
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(KidsReceiverConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
    }
}
