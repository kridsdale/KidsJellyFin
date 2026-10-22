//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
@testable import KidsParentControl
import Testing

struct ParentRequestDiagnosticsTests {
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [ParentRequestTrace.Record] = []
        func append(_ record: ParentRequestTrace.Record) {
            lock.withLock { records.append(record) }
        }

        var snapshot: [ParentRequestTrace.Record] {
            lock.withLock { records }
        }
    }

    private actor Transport: ParentHTTPTransport {
        enum Reply: Sendable { case response(Int, String), timeout, cancelled }
        let reply: Reply
        var requests: [URLRequest] = []
        init(_ reply: Reply) {
            self.reply = reply
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            switch reply {
            case let .response(status, body):
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            case .timeout:
                throw URLError(
                    .timedOut,
                    userInfo: [
                        NSLocalizedDescriptionKey: "SENTINEL_CREDENTIAL",
                        NSURLErrorFailingURLStringErrorKey: "https://secret.invalid/?token=SENTINEL_CREDENTIAL"
                    ]
                )
            case .cancelled: throw CancellationError()
            }
        }
    }

    @Test
    func `http failure preserves wire and error without logging credentials`() async throws {
        let capture = Capture(), transport = Transport(.response(503, "SENTINEL_CREDENTIAL"))
        let http = try ParentHTTP(server: ParentServer("http://family.invalid:18097"), transport: transport, diagnostics: capture.append)
        do {
            let _: EmptyResponse = try await http.request(
                "api/kids/v1/policy", headers: ["Authorization": "Bearer SENTINEL_CREDENTIAL"],
                query: [URLQueryItem(name: "private", value: "SENTINEL_CREDENTIAL")], body: Data("SENTINEL_CREDENTIAL".utf8)
            )
            Issue.record("Expected the unchanged HTTP failure")
        } catch { #expect(error as? ParentControlError == .http(503)) }
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer SENTINEL_CREDENTIAL")
        #expect(requests[0].httpBody == Data("SENTINEL_CREDENTIAL".utf8))
        #expect(requests[0].url?.query == "private=SENTINEL_CREDENTIAL")
        let records = capture.snapshot
        #expect(records.map(\.phase) == [.begin, .response, .finish])
        #expect(records.allSatisfy { $0.route == .policy && $0.method == .GET && $0.elapsedMilliseconds <= 86_400_000 })
        #expect(Set(records.map(\.attemptID)).count == 1)
        #expect(records[1].status == 503)
        #expect(records[2].errorCode == "http_503")
        #expect(records
            .allSatisfy {
                !$0.message.contains("SENTINEL") && !$0.message.contains("family.invalid") && !$0.message.contains("Authorization")
            })
    }

    @Test
    func `timeout uses only numeric code and does not retry`() async throws {
        let capture = Capture(), transport = Transport(.timeout)
        let http = try ParentHTTP(server: ParentServer("http://family.invalid"), transport: transport, diagnostics: capture.append)
        do {
            let _: EmptyResponse = try await http.request("api/kids/v1/policy")
            Issue.record("Expected timeout")
        } catch { #expect((error as? URLError)?.code == .timedOut) }
        #expect(await transport.requests.count == 1)
        #expect(capture.snapshot.map(\.phase) == [.begin, .finish])
        #expect(capture.snapshot.last?.errorCode == "url_-1001")
        #expect(capture.snapshot.allSatisfy { !$0.message.contains("SENTINEL") && !$0.message.contains("secret.invalid") })
    }

    @Test
    func `malformed body and dynamic route stay private`() async throws {
        let capture = Capture(), transport = Transport(.response(200, "SENTINEL_CREDENTIAL"))
        let http = try ParentHTTP(server: ParentServer("http://family.invalid"), transport: transport, diagnostics: capture.append)
        do {
            let _: [String: String] = try await http.request("api/parent/v1/children/SENTINEL_CREDENTIAL/preferences")
            Issue.record("Expected malformed response")
        } catch { #expect(error as? ParentControlError == .malformedResponse) }
        #expect(capture.snapshot.allSatisfy { $0.route == .other && !$0.message.contains("SENTINEL") })
        #expect(capture.snapshot.last?.errorCode == "malformed_response")
    }

    @Test
    func `cancellation stays cancellation`() async throws {
        let capture = Capture(), transport = Transport(.cancelled)
        let http = try ParentHTTP(server: ParentServer("http://family.invalid"), transport: transport, diagnostics: capture.append)
        do {
            let _: EmptyResponse = try await http.request("api/parent/v1/capabilities")
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
        #expect(await transport.requests.count == 1)
        #expect(capture.snapshot.last?.errorCode == "cancelled")
        #expect(capture.snapshot.count == 2)
    }

    @Test
    func `unknown error never logs its domain or description`() {
        let error = NSError(domain: "SENTINEL_CREDENTIAL", code: 42, userInfo: [NSLocalizedDescriptionKey: "SENTINEL_CREDENTIAL"])
        #expect(ParentControlDiagnostics.errorCode(error) == "other")
    }
}
