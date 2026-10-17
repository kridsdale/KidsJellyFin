//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Retains the structured receiver error. Integrity conflicts are never staleness.
public struct ReceiverEventConflict: Error, Equatable, Sendable, LocalizedError {
    public let code: String?
    public init(code: String?) {
        self.code = code
    }

    public var allowsHeartbeatRefresh: Bool {
        guard let code else { return false }
        return ["lease_mismatch", "lease_expired_or_mismatched", "policy_revision_mismatch", "heartbeat_session_mismatch"].contains(code)
    }

    public var errorDescription: String? {
        "Receiver synchronization was rejected. No report was acknowledged."
    }
}

public struct ReceiverPolicy: Codable, Equatable, Sendable {
    public struct PolicyControl: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case countdown, finishEpisode, release }
        public let commandID: UUID
        public let kind: Kind
    }

    public struct Command: Codable, Equatable, Sendable {
        public let commandID: UUID
        public let action: ParentRemoteAction
        public let playbackSessionID: String
        public let expiresAt: Date
    }

    public struct ShuffleContext: Codable, Equatable, Sendable {
        public let complete: Bool?
        public let watchedItemIDs: [String]
        public let recentItemIDs: [String]
    }

    public let serverID: String
    public let childUserID: String
    public let deviceID: String
    public let revision: Int
    public let enforcementEnabled: Bool?
    public let playbackIntentRequired: Bool?
    public let playbackIntentAvailable: Bool?
    public let playbackIntentID: UUID?
    public let leasePlaybackSessionID: String?
    public let leaseItemID: String?
    public let serverTime: Date
    public let validUntil: Date
    public let viewingAllowed: Bool
    public let blockedShowIDs: [String]
    public let blockedEpisodeIDs: [String]
    public let deadline: Date?
    public let finishPlaybackSessionID: String?
    public let birdItemID: String?
    public let shuffle: ParentShufflePreferences
    public let shuffleContext: ShuffleContext?
    public let policyControl: PolicyControl?
    public let commands: [Command]
}

public struct ReceiverEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case heartbeat
        case started
        case progress
        case paused
        case buffering
        case ended
        case stopped
        case commandApplied
        case commandFailed
        case ambientStarted
        case ambientFailed
    }

    public let eventID: UUID
    public let deviceID: String
    public let childUserID: String
    public let policyRevision: Int
    public let playbackSessionID: String?
    public let itemID: String?
    public let kind: Kind
    public let positionSeconds: Double?
    public let elapsedPlayingSeconds: Double
    public let commandID: UUID?
    public init(
        eventID: UUID = UUID(),
        deviceID: String,
        childUserID: String,
        policyRevision: Int,
        playbackSessionID: String? = nil,
        itemID: String? = nil,
        kind: Kind,
        positionSeconds: Double? = nil,
        elapsedPlayingSeconds: Double = 0,
        commandID: UUID? = nil
    ) {
        self.eventID = eventID
        self.deviceID = deviceID
        self.childUserID = childUserID
        self.policyRevision = policyRevision
        self.playbackSessionID = playbackSessionID
        self.itemID = itemID
        self.kind = kind
        self.positionSeconds = positionSeconds
        self.elapsedPlayingSeconds = elapsedPlayingSeconds
        self.commandID = commandID
    }

    enum CodingKeys: String, CodingKey {
        case eventID
        case deviceID
        case childUserID
        case policyRevision
        case playbackSessionID
        case itemID
        case kind
        case positionSeconds
        case elapsedPlayingSeconds
        case commandID
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(eventID, forKey: .eventID)
        try values.encode(deviceID, forKey: .deviceID)
        try values.encode(childUserID, forKey: .childUserID)
        try values.encode(policyRevision, forKey: .policyRevision)
        try values.encode(playbackSessionID, forKey: .playbackSessionID)
        try values.encode(itemID, forKey: .itemID)
        try values.encode(kind, forKey: .kind)
        try values.encode(positionSeconds, forKey: .positionSeconds)
        try values.encode(elapsedPlayingSeconds, forKey: .elapsedPlayingSeconds)
        try values.encode(commandID, forKey: .commandID)
    }
}

/// Acknowledges event storage, never command application or viewing permission.
public struct ReceiverEventReceipt: Decodable, Equatable, Sendable {
    public let commandID: UUID
    public let status: String
    public let evidenceDisposition: String?
    public let unconfirmedPlaybackSessionID: String?

    func validate(for event: ReceiverEvent) throws {
        guard commandID == event.eventID, status == "persisted" else { throw ParentControlError.malformedResponse }
        if evidenceDisposition == nil, unconfirmedPlaybackSessionID == nil {
            return
        }
        guard evidenceDisposition == "unconfirmed", let session = unconfirmedPlaybackSessionID, !session.isEmpty,
              session == event.playbackSessionID, event.commandID == nil,
              let item = event.itemID, !item.isEmpty,
              [.started, .progress, .paused, .buffering, .ended, .stopped].contains(event.kind)
        else { throw ParentControlError.malformedResponse }
    }
}

/// Device credential only. There are no parent writes or generic Jellyfin play routes.
public struct KidsReceiverAPI: Sendable {
    private let http: ParentHTTP
    private let serverID: String
    private let childUserID: String
    private let deviceID: String
    private let headers: [String: String]
    public init(
        server: ParentServer,
        serverID: String,
        childUserID: String,
        deviceID: String,
        token: String,
        transport: any ParentHTTPTransport = ParentURLTransport()
    ) {
        http = ParentHTTP(server: server, transport: transport)
        self.serverID = serverID
        self.childUserID = childUserID
        self.deviceID = deviceID
        headers = ["Authorization": "Bearer \(token)"]
    }

    public func policy() async throws -> ReceiverPolicy {
        let policy: ReceiverPolicy = try await http.request("api/kids/v1/policy", headers: headers)
        guard policy.serverID == serverID, policy.childUserID == childUserID,
              UUID(uuidString: deviceID) != nil, policy.deviceID == deviceID
        else { throw ParentControlError.serverMismatch }
        return policy
    }

    /// Persists an admission request, never a playback grant. Fetch and validate
    /// fresh exact-session policy after this receipt before starting transport.
    @discardableResult
    public func requestPlaybackIntent(
        commandID: UUID,
        expectedRevision: Int,
        playbackSessionID: String,
        itemID: String
    ) async throws -> ParentCommandReceipt {
        struct Body: Encodable {
            let commandID: UUID
            let deviceID: String
            let childUserID: String
            let expectedRevision: Int
            let playbackSessionID: String
            let itemID: String
        }
        guard expectedRevision >= 0 else { throw ParentControlError.invalidSelection }
        return try await sendPlaybackMutation("playback-intents", commandID: commandID, body: Body(
            commandID: commandID, deviceID: deviceID, childUserID: childUserID,
            expectedRevision: expectedRevision,
            playbackSessionID: ParentHTTP.identifier(playbackSessionID), itemID: ParentHTTP.identifier(itemID)
        ))
    }

    /// Local transport must already be held and its prior evidence drained.
    /// Persisting surrender does not confirm a refund or grant future permission.
    @discardableResult
    public func surrenderPlayback(
        commandID: UUID,
        playbackIntentID: UUID,
        playbackSessionID: String,
        itemID: String
    ) async throws -> ParentCommandReceipt {
        struct Body: Encodable {
            let commandID: UUID
            let playbackIntentID: UUID
            let deviceID: String
            let childUserID: String
            let playbackSessionID: String
            let itemID: String
        }
        return try await sendPlaybackMutation("playback-surrenders", commandID: commandID, body: Body(
            commandID: commandID, playbackIntentID: playbackIntentID, deviceID: deviceID, childUserID: childUserID,
            playbackSessionID: ParentHTTP.identifier(playbackSessionID), itemID: ParentHTTP.identifier(itemID)
        ))
    }

    private func sendPlaybackMutation(_ path: String, commandID: UUID, body: some Encodable) async throws -> ParentCommandReceipt {
        guard UUID(uuidString: deviceID) != nil else { throw ParentControlError.invalidSelection }
        var headers = headers
        headers["Idempotency-Key"] = commandID.uuidString
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let receipt: ParentCommandReceipt = try await http.request(
            "api/kids/v1/\(path)", method: "POST", headers: headers,
            body: encoder.encode(body)
        )
        guard receipt.commandID == commandID, receipt.status == "persisted" else { throw ParentControlError.malformedResponse }
        return receipt
    }

    @discardableResult
    public func send(_ event: ReceiverEvent) async throws -> ReceiverEventReceipt {
        guard event.childUserID == childUserID, UUID(uuidString: deviceID) != nil, event.deviceID == deviceID,
              event.policyRevision >= 0, event.elapsedPlayingSeconds.isFinite, (0 ... 30).contains(event.elapsedPlayingSeconds),
              event.positionSeconds == nil || (event.positionSeconds!.isFinite && event.positionSeconds! >= 0)
        else { throw ParentControlError.invalidSelection }
        var headers = headers
        headers["Idempotency-Key"] = event.eventID.uuidString
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let receipt: ReceiverEventReceipt = try await http.request(
            "api/kids/v1/events",
            method: "POST",
            headers: headers,
            body: encoder.encode(event),
            receiverEvent: true
        )
        try receipt.validate(for: event)
        return receipt
    }
}
