//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Strict evidence is separate from latency diagnostics and sampled VLC counters.
/// A declaration is a capability claim, not independent proof of implementation.
public struct KidsEvidenceCallbacks: Codable, Equatable, Sendable {
    public let video: String
    public let audio: String
    public let decoder: String

    /// Native drawable playback exposes no verified presentation/output callback
    /// or hardware-utilization counter to the current kids client.
    public static let unavailable = KidsEvidenceCallbacks(
        video: "unavailable", audio: "unavailable", decoder: "unavailable"
    )
    private init(video: String, audio: String, decoder: String) {
        self.video = video
        self.audio = audio
        self.decoder = decoder
    }
}

public enum KidsEvidenceFailure: String, Codable, Sendable {
    case audioOutputError = "audio_output_error"
    case clientDisconnected = "client_disconnected"
    case clientStartFailed = "client_start_failed"
    case conditionMismatch = "condition_mismatch"
    case decoderCounterUnavailable = "decoder_counter_unavailable"
    case firstAudioTimeout = "first_audio_timeout"
    case firstFrameTimeout = "first_frame_timeout"
    case ingestionTraceUnavailable = "ingestion_trace_unavailable"
    case lanUnreachable = "lan_unreachable"
    case playbackCancelled = "playback_cancelled"
    case playbackError = "playback_error"
    case rendererError = "renderer_error"
    case seekTimeout = "seek_timeout"
    case sessionLimitRejected = "session_limit_rejected"
    case unknownClientFailure = "unknown_client_failure"
    case unsupportedClientCallback = "unsupported_client_callback"
    case userCancelled = "user_cancelled"
    case wanProbeFailed = "wan_probe_failed"
}

public enum KidsEvidenceProtocolError: Error, Equatable, Sendable {
    case invalidIdentity
    case invalidDigest
    case invalidRevision
    case invalidTime
    case invalidScope
    case invalidConfiguration
    case unplannedTrial
    case duplicateTrial
    case missingCallback
    case clockChanged
    case observationOutsideRun
}

public enum KidsEvidenceValidation {
    public static func uuid(_ value: String) -> Bool {
        if hex(value, count: 32) {
            return true
        }
        guard let uuid = UUID(uuidString: value) else { return false }
        return value == uuid.uuidString.lowercased()
    }

    public static func hex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    public static func time(_ value: UInt64) -> Bool {
        value <= UInt64(Int64.max)
    }
}

public struct KidsEvidenceClock: Codable, Equatable, Sendable {
    public let id: String
    public let kind = "client_monotonic_ns"
    public let source = "instrumented_client"
    public init(id: UUID) {
        self.id = id.uuidString.lowercased()
    }

    public init(id: String) throws {
        guard KidsEvidenceValidation.uuid(id) else { throw KidsEvidenceProtocolError.invalidIdentity }
        self.id = id
    }

    enum CodingKeys: String, CodingKey { case id, kind, source }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        guard try c.decode(String.self, forKey: .kind) == "client_monotonic_ns",
              try c.decode(String.self, forKey: .source) == "instrumented_client"
        else { throw KidsEvidenceProtocolError.invalidConfiguration }
        try self.init(id: id)
    }
}

public struct KidsEvidenceClient: Codable, Equatable, Sendable {
    public enum Platform: String, Codable, Sendable { case simulator = "tvos_simulator", physical = "physical_apple_tv" }
    public enum Network: String, Codable, Sendable { case wired = "wired_lan", wifi = "wifi_lan", unknown }
    public let platform: Platform
    public let clientID: String
    public let appBuild: String
    public let osBuild: String
    public let network: Network
    public let cacheState: String
    enum CodingKeys: String, CodingKey {
        case platform
        case network
        case clientID = "client_id"
        case appBuild = "app_build"
        case osBuild = "os_build"
        case cacheState = "cache_state"
    }

    public init(platform: Platform, clientID: String, appBuild: String, osBuild: String, network: Network) throws {
        self.platform = platform
        self.clientID = clientID
        self.appBuild = appBuild
        self.osBuild = osBuild
        self.network = network
        cacheState = "uncontrolled"
        try validate()
    }

    public func validate() throws {
        guard KidsEvidenceValidation.uuid(clientID), cacheState == "uncontrolled",
              Self.build(appBuild), Self.build(osBuild) else { throw KidsEvidenceProtocolError.invalidScope }
    }

    private static func build(_ value: String) -> Bool {
        (1 ... 96).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || [46, 95, 43, 45].contains($0)
        }
    }

    /// The plan's representation is preserved; runtime identity comparison may
    /// normalize hyphens/case without rewriting anything in the envelope.
    public func matches(platform: Platform, clientID: String, appBuild: String, osBuild: String) -> Bool {
        self.platform == platform && self.appBuild == appBuild && self.osBuild == osBuild &&
            self.clientID.replacingOccurrences(of: "-", with: "") == clientID.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

public struct KidsEvidenceTrial: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case start
        case seek
        case sustained
        case next
        case shuffle
        case pauseResume = "pause_resume"
        case eof
        case sessionLimit = "session_limit"
        case identityAfterRefresh = "identity_after_refresh", identityAfterRestart = "identity_after_restart"
    }

    public enum Load: String, Codable, Sendable { case idle, ingestionActive = "ingestion_active" }
    public enum WAN: String, Codable, Sendable { case connected, disconnected }
    public let id: String
    public let itemID: String
    public let operation: Operation
    public let load: Load
    public let wan: WAN
    enum CodingKeys: String, CodingKey { case id, operation, load, wan
        case itemID = "item_id"
    }

    public init(id: String, itemID: String, operation: Operation, load: Load, wan: WAN) throws {
        guard KidsEvidenceValidation.uuid(id), KidsEvidenceValidation.uuid(itemID) else { throw KidsEvidenceProtocolError.invalidIdentity }
        self.id = id
        self.itemID = itemID
        self.operation = operation
        self.load = load
        self.wan = wan
    }
}

/// Read-only projection of an administrator-prepared plan. Extra planner fields
/// are deliberately never reserialized, and the server verifies the digest.
public struct KidsEvidencePlan: Decodable, Sendable {
    public let id: String
    public let digest: String
    public let serverID: String
    public let userID: String
    public let client: KidsEvidenceClient
    public let trials: [KidsEvidenceTrial]
    enum CodingKeys: String, CodingKey { case id, digest, client, trials
        case serverID = "server_id"
        case userID = "user_id"
    }

    public func validate() throws {
        guard [id, serverID, userID].allSatisfy(KidsEvidenceValidation.uuid),
              KidsEvidenceValidation.hex(digest, count: 64), !trials.isEmpty, trials.count <= 10000,
              Set(trials.map(\.id)).count == trials.count else { throw KidsEvidenceProtocolError.invalidConfiguration }
        try client.validate()
        for trial in trials {
            guard KidsEvidenceValidation.uuid(trial.id), KidsEvidenceValidation.uuid(trial.itemID) else {
                throw KidsEvidenceProtocolError.invalidIdentity
            }
        }
    }
}

public struct KidsEvidenceRunHeader: Encodable, Sendable {
    public let event = "run_started"
    public let protocolVersion = 1
    public let sequence: UInt64 = 0
    public let runID: String
    public let planID: String
    public let planDigest: String
    public let serverID: String
    public let userID: String
    public let client: KidsEvidenceClient
    public let clockID: String
    public let monotonicNS: UInt64
    public let implementationRevision: String
    public let callbacks = KidsEvidenceCallbacks.unavailable
    enum CodingKeys: String, CodingKey {
        case event
        case sequence
        case client
        case callbacks
        case protocolVersion = "protocol_version"
        case runID = "run_id"
        case planID = "plan_id"
        case planDigest = "plan_digest"
        case serverID = "server_id", userID = "user_id", clockID = "clock_id", monotonicNS = "monotonic_ns"
        case implementationRevision = "implementation_revision"
    }

    public init(plan: KidsEvidencePlan, runID: UUID, clock: KidsEvidenceClock, monotonicNS: UInt64, implementationRevision: String) throws {
        try plan.validate()
        guard KidsEvidenceValidation.time(monotonicNS) else { throw KidsEvidenceProtocolError.invalidTime }
        guard KidsEvidenceValidation.hex(implementationRevision, count: 40) || KidsEvidenceValidation.hex(implementationRevision, count: 64)
        else { throw KidsEvidenceProtocolError.invalidRevision }
        self.runID = runID.uuidString.lowercased()
        planID = plan.id
        planDigest = plan.digest
        serverID = plan.serverID
        userID = plan.userID
        client = plan.client
        clockID = clock.id
        self.monotonicNS = monotonicNS
        self.implementationRevision = implementationRevision
    }
}

/// Current VLC capabilities can only produce failed/cancelled partial strict
/// records. No public success initializer exists; supplementary counters cannot
/// be promoted into first_video_presented or first_audio_output.
public struct KidsEvidenceUnmeasuredRecord: Encodable, Sendable {
    public enum Outcome: String, Codable, Sendable { case failed, cancelled }
    public let trialID: String
    public let itemID: String
    public let outcome: Outcome
    public let failureCode: KidsEvidenceFailure
    public let clock: KidsEvidenceClock
    public let events: [KidsEvidenceActionEvent]
    private let trial: KidsEvidenceTrial
    enum CodingKeys: String, CodingKey {
        case outcome
        case clock
        case events
        case conditions
        case behavior
        case trialID = "trial_id"
        case itemID = "item_id"
        case failureCode = "failure_code"
        case decoderLoad = "decoder_load", serverCorroboration = "server_corroboration", conditionObservations = "condition_observations"
    }

    public init(
        trial: KidsEvidenceTrial,
        clock: KidsEvidenceClock,
        event: KidsEvidenceActionEvent?,
        failure: KidsEvidenceFailure = .unsupportedClientCallback,
        outcome: Outcome = .failed
    ) throws {
        guard KidsEvidenceValidation.uuid(trial.id),
              KidsEvidenceValidation.uuid(trial.itemID) else { throw KidsEvidenceProtocolError.invalidIdentity }
        if let event {
            guard event.clockID == clock.id else { throw KidsEvidenceProtocolError.clockChanged }
            guard (trial.operation == .start && event.event == .playbackRequested) ||
                (trial.operation == .seek && event.event == .seekRequested)
            else { throw KidsEvidenceProtocolError.invalidConfiguration }
        }
        trialID = trial.id
        itemID = trial.itemID
        self.outcome = outcome
        failureCode = failure
        self.clock = clock
        events = event.map { [$0] } ?? []
        self.trial = trial
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(trialID, forKey: .trialID)
        try c.encode(itemID, forKey: .itemID)
        try c.encode(outcome, forKey: .outcome)
        try c.encode(failureCode, forKey: .failureCode)
        try c.encode(clock, forKey: .clock)
        try c.encode(events, forKey: .events)
        try c.encode([Int](), forKey: .decoderLoad)
        try c.encode(UnobservedConditions(load: trial.load, wan: trial.wan), forKey: .conditions)
        try c.encodeNil(forKey: .behavior)
        try c.encode(UnknownServerCorroboration(), forKey: .serverCorroboration)
        try c.encodeNil(forKey: .conditionObservations)
    }

    private struct UnobservedConditions: Encodable {
        let load: KidsEvidenceTrial.Load
        let wan: KidsEvidenceTrial.WAN
        enum CodingKeys: String, CodingKey { case load, wan, observed
            case artifact = "artifact_sha256"
            case comparable = "media_properties_comparable"
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(load, forKey: .load)
            try c.encode(wan, forKey: .wan)
            try c.encode(false, forKey: .observed)
            try c.encodeNil(forKey: .artifact)
            try c.encode(false, forKey: .comparable)
        }
    }

    private struct UnknownServerCorroboration: Encodable {
        enum CodingKeys: String, CodingKey { case method = "play_method", artifact = "artifact_sha256", trace = "ingestion_trace_id" }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeNil(forKey: .method)
            try c.encodeNil(forKey: .artifact)
            try c.encodeNil(forKey: .trace)
        }
    }
}

/// Only actual action callbacks may produce these events. Renderer/audio events
/// intentionally have no constructor in the current implementation.
public struct KidsEvidenceActionEvent: Encodable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case playbackRequested = "playback_requested"
        case seekRequested = "seek_requested"
    }

    public let event: Kind
    public let clockID: String
    public let monotonicNS: UInt64
    public let source: String
    enum CodingKeys: String, CodingKey {
        case event
        case source
        case clockID = "clock_id"
        case monotonicNS = "monotonic_ns"
    }

    public init(event: Kind, clock: KidsEvidenceClock, monotonicNS: UInt64) throws {
        guard KidsEvidenceValidation.time(monotonicNS) else { throw KidsEvidenceProtocolError.invalidTime }
        self.event = event
        clockID = clock.id
        self.monotonicNS = monotonicNS
        source = "instrumented_client"
    }
}

public struct KidsEvidenceRunFooter: Encodable, Sendable {
    public enum Disposition: String, Codable, Sendable { case complete, interrupted }
    public let event = "run_finished"
    public let sequence: UInt64
    public let runID: String
    public let monotonicNS: UInt64
    public let disposition: Disposition
    enum CodingKeys: String, CodingKey {
        case event
        case sequence
        case disposition
        case runID = "run_id"
        case monotonicNS = "monotonic_ns"
    }

    public init(sequence: UInt64, runID: UUID, monotonicNS: UInt64, disposition: Disposition) throws {
        guard KidsEvidenceValidation.time(monotonicNS) else { throw KidsEvidenceProtocolError.invalidTime }
        self.sequence = sequence
        self.runID = runID.uuidString.lowercased()
        self.monotonicNS = monotonicNS
        self.disposition = disposition
    }
}

public struct KidsEvidenceTrialLine<Record: Encodable & Sendable>: Encodable, Sendable {
    public let event = "trial_record"
    public let sequence: UInt64
    public let runID: String
    public let record: Record
    enum CodingKeys: String, CodingKey {
        case event
        case sequence
        case record
        case runID = "run_id"
    }

    public init(sequence: UInt64, runID: UUID, record: Record) {
        self.sequence = sequence
        self.runID = runID.uuidString.lowercased()
        self.record = record
    }
}

/// This stream is supplementary and is deliberately not a strict trial_record.
public struct KidsEvidenceObservationLine<Record: Encodable & Sendable>: Encodable, Sendable {
    public let event = "observation_record"
    public let sequence: UInt64
    public let runID: String
    public let record: Record
    enum CodingKeys: String, CodingKey {
        case event
        case sequence
        case record
        case runID = "run_id"
    }

    public init(sequence: UInt64, runID: UUID, record: Record) {
        self.sequence = sequence
        self.runID = runID.uuidString.lowercased()
        self.record = record
    }
}
