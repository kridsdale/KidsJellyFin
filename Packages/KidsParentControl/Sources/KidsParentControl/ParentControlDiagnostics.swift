//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation
import OSLog

/// Local diagnostics only. Never accepts headers, bodies, URLs or server error text.
public enum ParentControlDiagnostics {
    public enum LoopPhase: String, Sendable {
        case started
        case stopped
        case foreground
        case background
        case refreshStarted
        case refreshFinished
        case refreshFailed
    }

    private static let logger = Logger(subsystem: "com.kridsdale.JellyfinPlayer", category: "ParentControl")

    public static func loop(
        _ phase: LoopPhase, foreground: Bool, paired: Bool,
        cancelled: Bool = false, error: (any Error)? = nil
    ) {
        let message = "loop phase=\(phase.rawValue) foreground=\(foreground) paired=\(paired) cancelled=\(cancelled) error=\(errorCode(error))"
        logger.notice("\(message, privacy: .public)")
    }

    static func errorCode(_ error: (any Error)?) -> String {
        guard let error else { return "none" }
        if error is CancellationError {
            return "cancelled"
        }
        if let error = error as? URLError {
            return "url_\(error.code.rawValue)"
        }
        if error is ReceiverEventConflict {
            return "receiver_event_conflict"
        }
        if error is ReceiverMutationConflict {
            return "receiver_mutation_conflict"
        }
        if let error = error as? ParentControlError {
            switch error {
            case let .http(status): return "http_\(status)"
            case .malformedResponse: return "malformed_response"
            case .unauthorized: return "unauthorized"
            case .unsupported: return "unsupported"
            case .conflict: return "conflict"
            case .serverMismatch: return "server_mismatch"
            default: return "sdk_other"
            }
        }
        return "other"
    }

    static func log(_ record: ParentRequestTrace.Record) {
        logger.notice("\(record.message, privacy: .public)")
    }
}

struct ParentRequestTrace: Sendable {
    enum Route: String, Sendable {
        case capabilities = "api/parent/v1/capabilities"
        case dashboard = "api/parent/v1/dashboard"
        case policy = "api/kids/v1/policy"
        case events = "api/kids/v1/events"
        case intents = "api/kids/v1/playback-intents"
        case surrenders = "api/kids/v1/playback-surrenders"
        case other
    }

    enum Method: String, Sendable { case GET, POST, PUT, PATCH, DELETE, other }
    enum Phase: String, Sendable { case begin, response, finish }
    struct Record: Sendable, Equatable {
        let attemptID: UUID
        let route: Route
        let method: Method
        let phase: Phase
        let elapsedMilliseconds: UInt64
        let status: Int?
        let errorCode: String

        var message: String {
            "request attempt=\(attemptID.uuidString) route=\(route.rawValue) method=\(method.rawValue) phase=\(phase.rawValue) elapsed_ms=\(elapsedMilliseconds) status=\(status ?? 0) error=\(errorCode)"
        }
    }

    private let attemptID = UUID()
    private let route: Route
    private let method: Method
    private let startedNS = DispatchTime.now().uptimeNanoseconds
    private let sink: @Sendable (Record) -> Void

    init(path: String, method: String, sink: @escaping @Sendable (Record) -> Void) {
        route = Route(rawValue: path) ?? .other
        self.method = Method(rawValue: method) ?? .other
        self.sink = sink
        emit(.begin)
    }

    func response(_ status: Int) {
        emit(.response, status: status)
    }

    func finish(error: (any Error)? = nil) {
        emit(.finish, error: error)
    }

    private func emit(_ phase: Phase, status: Int? = nil, error: (any Error)? = nil) {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= startedNS ? (now - startedNS) / 1_000_000 : 0
        sink(Record(
            attemptID: attemptID, route: route, method: method, phase: phase,
            elapsedMilliseconds: min(elapsed, 86_400_000), status: status,
            errorCode: ParentControlDiagnostics.errorCode(error)
        ))
    }
}
