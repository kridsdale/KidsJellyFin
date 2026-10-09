//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A supplementary session observation, never a renderer/audio callback or trial outcome.
/// Positions are finite snapshots only; a requested seek target is not seek completion.
/// This value contains no media identity, account, path, URL, or error description.
public struct KidsSessionObservation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case sessionStart = "session_start"
        case readinessObserved = "readiness_observed"
        case transportPausedObserved = "transport_paused_observed"
        case transportResumedObserved = "transport_resumed_observed"
        case seekRequested = "seek_requested"
        case bufferingStartedObserved = "buffering_started_observed"
        case bufferingEndedObserved = "buffering_ended_observed"
        case nativeEndObserved = "native_end_observed"
        case failureObserved = "failure_observed"
        case recoveryEntered = "recovery_entered"
        case stopRequested = "stop_requested"
        case driverDrained = "driver_drained"
        case stopCompleted = "stop_completed"
    }

    public enum Failure: String, Codable, Sendable {
        case authentication
        case stream
        case nativeFrame = "native_frame"
    }

    public let sessionID: UUID
    public let kind: Kind
    public let monotonicNS: UInt64
    public let positionSeconds: Double?
    public let requestedSeekTargetSeconds: Double?
    public let failure: Failure?
    public let cancellationRequested: Bool

    public init(
        sessionID: UUID,
        kind: Kind,
        monotonicNS: UInt64,
        positionSeconds: Double? = nil,
        requestedSeekTargetSeconds: Double? = nil,
        failure: Failure? = nil,
        cancellationRequested: Bool = false
    ) {
        self.sessionID = sessionID
        self.kind = kind
        self.monotonicNS = monotonicNS
        self.positionSeconds = positionSeconds.flatMap { $0.isFinite ? $0 : nil }
        self.requestedSeekTargetSeconds = requestedSeekTargetSeconds.flatMap { $0.isFinite ? $0 : nil }
        self.failure = failure
        self.cancellationRequested = cancellationRequested
    }
}
