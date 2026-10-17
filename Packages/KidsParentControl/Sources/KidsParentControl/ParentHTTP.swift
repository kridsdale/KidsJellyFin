//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation

public protocol ParentHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
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

public final class ParentURLTransport: ParentHTTPTransport, Sendable {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ParentControlError.malformedResponse }
        return (data, response)
    }
}

private struct ReceiverConflictBody: Decodable { let error: String }

struct ParentHTTP: Sendable {
    let server: ParentServer
    let transport: any ParentHTTPTransport

    func request<T: Decodable & Sendable>(
        _ path: String, method: String = "GET", headers: [String: String] = [:],
        query: [URLQueryItem] = [], body: Data? = nil, receiverEvent: Bool = false
    ) async throws -> T {
        var parts = URLComponents(url: server.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        parts.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: parts.url!)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.allHTTPHeaderFields = headers.merging(["Accept": "application/json", "Content-Type": "application/json"]) { old, _ in old }
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200 ... 299: break
        case 401, 403: throw ParentControlError.unauthorized
        case 404, 501: throw ParentControlError.unsupported
        case 409 where receiverEvent:
            let code = data.count <= 4096 ? (try? JSONDecoder().decode(ReceiverConflictBody.self, from: data).error) : nil
            throw ReceiverEventConflict(code: code)
        case 409, 412: throw ParentControlError.conflict
        default: throw ParentControlError.http(response.statusCode)
        }
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = parser.date(from: value) {
                return date
            }
            parser.formatOptions = [.withInternetDateTime]
            guard let date = parser.date(from: value) else { throw ParentControlError.malformedResponse }
            return date
        }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw ParentControlError.malformedResponse }
    }

    static func identifier(_ text: String) throws -> String {
        guard !text.isEmpty, text.count <= 128,
              text.utf8
                  .allSatisfy({ (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 45 || $0 == 95 })
        else { throw ParentControlError.invalidSelection }
        return text
    }
}

struct EmptyResponse: Decodable, Sendable {}
