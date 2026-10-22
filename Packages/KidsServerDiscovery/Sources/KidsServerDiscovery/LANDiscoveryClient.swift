//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation
import SwiftfinNetworking

private final class DiscoveryNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Finite, unauthenticated discovery. Existing Jellyfin SDK owns the UDP socket,
/// interface broadcasts and five-second lifetime; canceling the consumer closes it.
public struct LANDiscoveryClient: Sendable {
    public typealias Stream = @Sendable () -> AsyncThrowingStream<LANServer, any Error>
    public typealias Verify = @Sendable (LANServer, String?) async throws -> LANServer
    private let stream: Stream
    private let verify: Verify

    public init(stream: @escaping Stream, verify: @escaping Verify) {
        self.stream = stream
        self.verify = verify
    }

    public static let live = LANDiscoveryClient(stream: {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let source = await JellyfinTransport.discover()
                    for try await value in source {
                        try Task.checkCancellation()
                        continuation.yield(LANServer(id: value.id, name: value.name, url: value.url))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }, verify: verifyPublicServer)

    public func servers(expectedID: String? = nil) async throws -> [LANServer] {
        var candidates: [LANServer] = []
        var seen = Set<String>()
        for try await candidate in stream() {
            try Task.checkCancellation()
            guard candidates.count < 16,
                  (try? LANDiscoveryPolicy.validatedURL(candidate.url)) != nil,
                  expectedID.map({ $0 == candidate.id }) ?? true,
                  seen.insert(candidate.id + "|" + candidate.url.absoluteString).inserted else { continue }
            candidates.append(candidate)
        }
        // At most sixteen small unauthenticated probes; requests have a shared
        // short deadline. A bad advertisement cannot hold setup indefinitely.
        let verified = await withTaskGroup(of: LANServer?.self, returning: [LANServer].self) { group in
            for candidate in candidates {
                group.addTask { try? await verify(candidate, expectedID) }
            }
            var values: [LANServer] = []
            for await value in group {
                if let value, !values.contains(where: { $0.id == value.id && $0.url == value.url }) {
                    values.append(value)
                }
            }
            return values
        }
        try Task.checkCancellation()
        return verified.sorted { ($0.name, $0.url.absoluteString) < ($1.name, $1.url.absoluteString) }
    }

    /// Also used immediately before sending a password to a chosen result. A
    /// scan does not move a stored credential to a newly advertised address.
    public static func verifyPublicServer(_ proposed: LANServer, expectedID: String? = nil) async throws -> LANServer {
        let base = try LANDiscoveryPolicy.validatedURL(proposed.url)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 5
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: DiscoveryNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: base.appendingPathComponent("System/Info/Public"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = http.url, LANDiscoveryPolicy.sameOrigin(base, finalURL), data.count <= 65536
        else { throw LANDiscoveryError.invalidResponse }
        struct Info: Decodable { let Id: String
            let ServerName: String
        }
        let info = try JSONDecoder().decode(Info.self, from: data)
        return try LANDiscoveryPolicy.verified(proposed, responseID: info.Id, responseName: info.ServerName, expectedID: expectedID)
    }
}
