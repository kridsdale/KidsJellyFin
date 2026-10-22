//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation
@testable import KidsServerDiscovery
import Testing

private let local = URL(string: "http://192.168.10.100:8096")!
private let server = LANServer(id: "family-server", name: "Old advertisement", url: local)

@Suite("LAN discovery boundaries")
struct DiscoveryTests {
    @Test(arguments: ["http://192.168.10.100:8096", "https://1531server.local", "http://10.2.3.4/jellyfin", "http://[fd12::42]:8096"])
    func `local origins`(_ value: String) throws {
        _ = try LANDiscoveryPolicy.validatedURL(#require(URL(string: value)))
    }

    @Test(arguments: [
        "https://example.com",
        "http://127.0.0.1:8096",
        "file:///tmp/server",
        "http://user:password@1531server.local",
        "http://192.168.10.100/?token=x",
        "http://192.168.10.100/#fragment",
        "http://192.168.10.100/base/%2fadmin"
    ])
    func `reject untrusted addresses`(_ value: String) throws {
        #expect(throws: LANDiscoveryError.invalidAddress) { try LANDiscoveryPolicy.validatedURL(#require(URL(string: value))) }
    }

    @Test
    func `exact identity and name`() throws {
        let result = try LANDiscoveryPolicy.verified(server, responseID: server.id, responseName: "Family", expectedID: server.id)
        #expect(result.name == "Family")
        #expect(result.url == local)
        #expect(throws: LANDiscoveryError.identityMismatch) { try LANDiscoveryPolicy.verified(
            server,
            responseID: "other",
            responseName: "Family",
            expectedID: nil
        ) }
        #expect(throws: LANDiscoveryError.identityMismatch) { try LANDiscoveryPolicy.verified(
            server,
            responseID: server.id,
            responseName: "Family",
            expectedID: "remembered-other-server"
        ) }
    }

    @Test
    func `origin includes scheme host and port`() throws {
        #expect(try LANDiscoveryPolicy.sameOrigin(local, #require(URL(string: "http://192.168.10.100:8096/System/Info/Public"))))
        #expect(try !LANDiscoveryPolicy.sameOrigin(local, #require(URL(string: "http://192.168.10.100:18097"))))
        #expect(try !LANDiscoveryPolicy.sameOrigin(local, #require(URL(string: "https://192.168.10.100:8096"))))
        #expect(try !LANDiscoveryPolicy.sameOrigin(local, #require(URL(string: "http://1531server.local:8096"))))
    }

    @Test
    func `deduplicate and filter before probe`() async throws {
        actor Count { var value = 0
            func add() {
                value += 1
            }
        }
        let count = Count()
        let client = LANDiscoveryClient(stream: {
            AsyncThrowingStream { continuation in
                continuation.yield(server)
                continuation.yield(server)
                continuation.yield(LANServer(id: "different", name: "Other", url: local))
                continuation.yield(LANServer(id: server.id, name: "WAN", url: URL(string: "https://example.com")!))
                continuation.finish()
            }
        }, verify: { candidate, _ in await count.add()
            return candidate
        })
        let results = try await client.servers(expectedID: server.id)
        #expect(results == [server])
        #expect(await count.value == 1)
    }

    @Test @MainActor
    func `canceled or superseded scan cannot publish`() async {
        let (started, signal) = AsyncStream<Void>.makeStream()
        let client = LANDiscoveryClient(stream: {
            AsyncThrowingStream { continuation in continuation.yield(server)
                continuation.finish()
            }
        }, verify: { candidate, _ in
            signal.yield(())
            try? await Task.sleep(for: .milliseconds(20))
            return candidate
        })
        let model = LANDiscoveryModel(client: client)
        let scan = Task { await model.scan() }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next() // Actual probe started; it will complete after cancel.
        model.cancel()
        await scan.value
        #expect(model.servers.isEmpty)
        #expect(!model.scanning)
    }
}

@Suite("Parents service discovery identity")
struct ParentDiscoveryTests {
    private func txt(_ id: String = "family-server", version: String = "1") -> [String: Data] {
        ["jellyfinServerId": Data(id.utf8), "apiVersion": Data(version.utf8)]
    }

    @Test
    func `exact identity and resolved port`() throws {
        let value = try LANParentService(
            name: "Family controls",
            host: "1531server.local.",
            port: 18097,
            txt: txt(),
            expectedServerID: "family-server"
        )
        #expect(value.serverID == "family-server")
        #expect(value.url.absoluteString == "http://1531server.local:18097")
    }

    @Test
    func `reject wrong identity version host and port`() {
        #expect(throws: LANDiscoveryError.identityMismatch) { try LANParentService(
            name: "Wrong",
            host: "1531server.local",
            port: 18097,
            txt: txt("other-server"),
            expectedServerID: "family-server"
        ) }
        #expect(throws: LANDiscoveryError.identityMismatch) { try LANParentService(
            name: "Wrong",
            host: "1531server.local",
            port: 18097,
            txt: txt(version: "2"),
            expectedServerID: "family-server"
        ) }
        #expect(throws: LANDiscoveryError.invalidAddress) { try LANParentService(
            name: "WAN",
            host: "example.com",
            port: 18097,
            txt: txt(),
            expectedServerID: "family-server"
        ) }
        #expect(throws: LANDiscoveryError.identityMismatch) { try LANParentService(
            name: "Bad port",
            host: "1531server.local",
            port: 0,
            txt: txt(),
            expectedServerID: "family-server"
        ) }
    }
}
