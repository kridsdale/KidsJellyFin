//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation
import KidsDomain
import KidsParentControl

/// Pure policy decisions. SDK playback and credential storage remain host-owned.
/// A freshly launched paired receiver has no permission until a verified response.
public struct ViewingLease: Sendable {
    public private(set) var policy: ReceiverPolicy?
    public let serverID: String
    public let childUserID: String
    public let deviceID: UUID
    public private(set) var requiresPlaybackGrants: Bool
    private var acceptedAt: UInt64?
    private var leaseEnd: UInt64 = 0
    private var catalogEnd: UInt64 = 0
    private var deadlineEnd: UInt64?
    private var commandExpiries: [UUID: UInt64] = [:]

    public init(serverID: String, childUserID: String, deviceID: UUID, requiresPlaybackGrants: Bool = false) {
        self.serverID = serverID
        self.childUserID = childUserID
        self.deviceID = deviceID
        self.requiresPlaybackGrants = requiresPlaybackGrants
    }

    public mutating func accept(_ value: ReceiverPolicy, requestStartedNS: UInt64, receivedNS: UInt64) throws {
        guard value.serverID == serverID, value.childUserID == childUserID, UUID(uuidString: value.deviceID) == deviceID,
              value.revision >= 0, value.revision >= (policy?.revision ?? 0), requestStartedNS <= receivedNS,
              requestStartedNS >= (acceptedAt ?? 0),
              value.blockedShowIDs.count <= 10000, value.blockedEpisodeIDs.count <= 100_000, value.commands.count <= 64
        else { throw ParentControlError.serverMismatch }
        let duration = value.validUntil.timeIntervalSince(value.serverTime)
        guard duration.isFinite, (0 ... 30).contains(duration) else { throw ParentControlError.malformedResponse }
        let requiresGrants = requiresPlaybackGrants || value.playbackIntentRequired == true
        let explicitDisable = value.enforcementEnabled == false && value.policyControl?.kind == .release
        if requiresGrants, explicitDisable {
            guard !value.viewingAllowed, duration == 0 else { throw ParentControlError.malformedResponse }
        }
        if requiresGrants {
            guard value.hasPlaybackGrantFields, value.playbackIntentRequired == true, value.playbackIntentAvailable != nil else {
                throw ParentControlError.malformedResponse
            }
            let bound = value.playbackIntentID != nil || value.leasePlaybackSessionID != nil || value.leaseItemID != nil
            if bound || value.viewingAllowed {
                guard value.playbackIntentID != nil,
                      let session = value.leasePlaybackSessionID, !session.isEmpty,
                      let item = value.leaseItemID, !item.isEmpty else { throw ParentControlError.malformedResponse }
            }
        }
        try value.shuffle.validate()
        var expiries: [UUID: UInt64] = [:]
        for command in value.commands {
            guard expiries[command.commandID] == nil, !command.playbackSessionID.isEmpty else { throw ParentControlError.malformedResponse }
            let remaining = command.expiresAt.timeIntervalSince(value.serverTime)
            guard remaining.isFinite, remaining <= 30 else { throw ParentControlError.malformedResponse }
            expiries[command.commandID] = Self.limit(from: requestStartedNS, seconds: max(0, remaining))
        }
        let deadline: UInt64?
        if let date = value.deadline {
            let duration = date.timeIntervalSince(value.serverTime)
            guard duration.isFinite else { throw ParentControlError.malformedResponse }
            deadline = Self.limit(from: requestStartedNS, seconds: max(0, duration))
        } else {
            deadline = nil
        }
        policy = value
        requiresPlaybackGrants = requiresGrants
        acceptedAt = receivedNS
        leaseEnd = Self.limit(from: requestStartedNS, seconds: duration)
        // Read-only catalog freshness is not a viewing reservation or grant.
        catalogEnd = Self.limit(from: requestStartedNS, seconds: 30)
        deadlineEnd = deadline
        commandExpiries = expiries
    }

    private static func limit(from start: UInt64, seconds: Double) -> UInt64 {
        let value = min(max(0, seconds), 366 * 24 * 3600) * 1_000_000_000
        let result = start.addingReportingOverflow(UInt64(value))
        return result.overflow ? UInt64.max : result.partialValue
    }

    public func isFresh(at now: UInt64) -> Bool {
        guard let acceptedAt else { return false }
        return now >= acceptedAt && now < leaseEnd
    }

    public static func nextActivation(current: Bool, policy: ReceiverPolicy) -> Bool {
        if policy.enforcementEnabled == true {
            return true
        }
        if policy.enforcementEnabled == false, policy.policyControl?.kind == .release {
            return false
        }
        return current
    }

    public func allowsNormalViewing(at now: UInt64) -> Bool {
        isFresh(at: now) && policy?.viewingAllowed == true && (deadlineEnd == nil || now < deadlineEnd!)
    }

    public func deadlineReached(at now: UInt64) -> Bool {
        deadlineEnd.map { now >= $0 } == true
    }

    /// A bird item alone is not authority. Generic holds remain static.
    public func ambientCommandID(latchedControlID: UUID?, at now: UInt64) -> UUID? {
        guard let policy, let bird = policy.birdItemID, !bird.isEmpty,
              let control = policy.policyControl, control.kind != .release,
              latchedControlID == control.commandID || deadlineReached(at: now) else { return nil }
        return control.commandID
    }

    public func permits(_ item: KidsItem, binding: KidsBinding, at now: UInt64) -> Bool {
        guard binding.serverID == serverID, binding.userID == childUserID,
              KidsEligibility.permits(item, binding: binding), allowsNormalViewing(at: now), let policy,
              item.id != policy.birdItemID,
              !policy.blockedShowIDs.contains(item.id), !policy.blockedEpisodeIDs.contains(item.id),
              item.seriesID == nil || !policy.blockedShowIDs.contains(item.seriesID!) else { return false }
        return true
    }

    public func permitsPlayback(_ item: KidsItem, binding: KidsBinding, intentID: UUID?, sessionID: String, at now: UInt64) -> Bool {
        guard permits(item, binding: binding, at: now) else { return false }
        guard requiresPlaybackGrants else { return true }
        guard let intentID, policy?.playbackIntentRequired == true else { return false }
        return policy?.playbackIntentID == intentID && policy?.leasePlaybackSessionID == sessionID && policy?.leaseItemID == item.id
    }

    /// Browse eligibility never authorizes transport. A zero-duration viewing
    /// lease may still carry a recently fetched read-only catalog policy.
    public func permitsBrowsing(_ item: KidsItem, binding: KidsBinding, at now: UInt64) -> Bool {
        guard requiresPlaybackGrants else { return permits(item, binding: binding, at: now) }
        guard let policy, policy.playbackIntentRequired == true,
              let acceptedAt, now >= acceptedAt, now < catalogEnd,
              policy.playbackIntentAvailable == true || allowsNormalViewing(at: now),
              binding.serverID == serverID, binding.userID == childUserID,
              KidsEligibility.permits(item, binding: binding), !deadlineReached(at: now),
              item.id != policy.birdItemID, !policy.blockedShowIDs.contains(item.id), !policy.blockedEpisodeIDs.contains(item.id),
              item.seriesID == nil || !policy.blockedShowIDs.contains(item.seriesID!) else { return false }
        return true
    }

    /// Finish grants end on this exact controller's EOF, never a later session.
    public func endsAtEOF(playbackSessionID: String) -> Bool {
        guard policy?.policyControl?.kind == .finishEpisode else { return false }
        return policy?.finishPlaybackSessionID == playbackSessionID
    }

    public func mayApply(_ command: ReceiverPolicy.Command, playbackSessionID: String, at now: UInt64) -> Bool {
        isFresh(at: now) && command.playbackSessionID == playbackSessionID &&
            commandExpiries[command.commandID].map { now < $0 } == true
    }

    public func shuffleCandidates(_ items: [KidsItem], binding: KidsBinding, at now: UInt64) -> [KidsItem] {
        let allowed = items.filter { permits($0, binding: binding, at: now) }
        guard let policy, let context = policy.shuffleContext, context.complete == true else { return allowed }
        var candidates = allowed
        if policy.shuffle.repeatCooldownDays > 0 {
            let recent = Set(context.recentItemIDs)
            let fresh = candidates.filter { !recent.contains($0.id) }
            if !fresh.isEmpty {
                candidates = fresh
            }
        }
        if policy.shuffle.preferUnwatched {
            let watched = Set(context.watchedItemIDs)
            let unwatched = candidates.filter { !watched.contains($0.id) }
            if !unwatched.isEmpty {
                candidates = unwatched
            }
        }
        return candidates
    }

    /// Operational report only. Seeks, pauses and buffering cannot mint viewing time.
    public static func playingInterval(
        previousPosition: Double,
        position: Double,
        elapsedSeconds: Double,
        playing: Bool,
        paused: Bool,
        buffering: Bool
    ) -> Double {
        guard previousPosition.isFinite, position.isFinite, elapsedSeconds.isFinite,
              previousPosition >= 0, elapsedSeconds > 0, elapsedSeconds <= 5,
              playing, !paused, !buffering else { return 0 }
        let advance = position - previousPosition
        guard advance > 0, advance <= elapsedSeconds * 1.5 + 0.5 else { return 0 }
        return min(advance, elapsedSeconds)
    }
}
