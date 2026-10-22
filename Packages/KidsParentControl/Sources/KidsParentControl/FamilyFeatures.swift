//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct ViewingRoutine: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// ISO weekdays: Monday = 1, Sunday = 7.
    public var weekdays: [Int]
    public var startMinute: Int
    public var endMinute: Int
    public var enabled: Bool
    public init(
        id: UUID = UUID(),
        name: String = "After school",
        weekdays: [Int] = [1, 2, 3, 4, 5],
        startMinute: Int = 900,
        endMinute: Int = 1080,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.weekdays = weekdays
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case weekdays
        case startMinute
        case endMinute
        case enabled
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        // The backend validates nested routine IDs as canonical UUID strings.
        try values.encode(id.uuidString.lowercased(), forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(weekdays, forKey: .weekdays)
        try values.encode(startMinute, forKey: .startMinute)
        try values.encode(endMinute, forKey: .endMinute)
        try values.encode(enabled, forKey: .enabled)
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
              !weekdays.isEmpty, Set(weekdays).count == weekdays.count,
              weekdays.allSatisfy({ (1 ... 7).contains($0) }),
              (0 ... 1439).contains(startMinute), (0 ... 1439).contains(endMinute), startMinute < endMinute
        else { throw ParentControlError.invalidRoutine }
    }
}

public struct DailyViewingBudget: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var dailyMinutes: Int
    public let usedSeconds: Int
    public let bonusSeconds: Int
    public let localDate: String
    public let reservedSeconds: Int?
    public let unconfirmedSeconds: Int?
    public let serverRemainingSeconds: Int?
    enum CodingKeys: String, CodingKey {
        case enabled
        case dailyMinutes
        case usedSeconds
        case bonusSeconds
        case localDate
        case reservedSeconds
        case unconfirmedSeconds
        case serverRemainingSeconds = "remainingSeconds"
    }

    /// Public debit fields are rounded for display. Only the server's calculation
    /// retains fractional accounting; never reconstruct permission from those fields.
    public var remainingSeconds: Int? {
        serverRemainingSeconds.map { max(0, $0) }
    }

    public init(
        enabled: Bool,
        dailyMinutes: Int,
        usedSeconds: Int,
        bonusSeconds: Int,
        localDate: String,
        reservedSeconds: Int? = nil,
        unconfirmedSeconds: Int? = nil,
        serverRemainingSeconds: Int? = nil
    ) {
        self.enabled = enabled
        self.dailyMinutes = dailyMinutes
        self.usedSeconds = usedSeconds
        self.bonusSeconds = bonusSeconds
        self.localDate = localDate
        self.reservedSeconds = reservedSeconds
        self.unconfirmedSeconds = unconfirmedSeconds
        self.serverRemainingSeconds = serverRemainingSeconds
    }
}

public struct ParentShufflePreferences: Codable, Equatable, Sendable {
    public var preferUnwatched: Bool
    public var repeatCooldownDays: Int
    public var preferredShowIDs: [String]
    public init(preferUnwatched: Bool = false, repeatCooldownDays: Int = 0, preferredShowIDs: [String] = []) {
        self.preferUnwatched = preferUnwatched
        self.repeatCooldownDays = repeatCooldownDays
        self.preferredShowIDs = preferredShowIDs
    }

    public func validate() throws {
        guard (0 ... 30).contains(repeatCooldownDays), preferredShowIDs.count <= 100,
              Set(preferredShowIDs).count == preferredShowIDs.count else { throw ParentControlError.invalidPreferences }
        for id in preferredShowIDs {
            _ = try ParentHTTP.identifier(id)
        }
    }
}

public struct ParentProfileSettings: Codable, Equatable, Sendable {
    public let childUserID: String
    public let revision: Int
    public var timeZone: String
    public var routines: [ViewingRoutine]
    public var budget: DailyViewingBudget
    public var shuffle: ParentShufflePreferences
    public let excludedEpisodeIDs: [String]
    public init(
        childUserID: String,
        revision: Int,
        timeZone: String,
        routines: [ViewingRoutine],
        budget: DailyViewingBudget,
        shuffle: ParentShufflePreferences,
        excludedEpisodeIDs: [String]
    ) {
        self.childUserID = childUserID
        self.revision = revision
        self.timeZone = timeZone
        self.routines = routines
        self.budget = budget
        self.shuffle = shuffle
        self.excludedEpisodeIDs = excludedEpisodeIDs
    }
}

public struct ParentEpisode: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let showID: String
    public let season: Int?
    public let episode: Int?
    public let excluded: Bool
}

public struct PlaylistReviewEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let collectionID: String
    public let snapshotID: String
    public let title: String
    public let newVideoCount: Int
    public let createdAt: Date
    public let status: String
}

public struct ViewingHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let itemID: String
    public let title: String
    public let deviceName: String
    public let startedAt: Date
    public let watchedSeconds: Int
    public let evidence: String
}

public struct ParentPage<Item: Codable & Sendable>: Codable, Sendable {
    public let childUserID: String?
    public let showID: String?
    public let items: [Item]
    public let nextCursor: String?
}

public struct ParentServerHealth: Codable, Sendable {
    public struct Television: Codable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let online: Bool
        public let lastSeen: Date?
    }

    public let observedAt: Date
    public let jellyfin: String
    public let worker: String
    public let storageFreeBytes: Int64?
    public let pendingJobs: Int?
    public let failedJobs: Int?
    public let televisions: [Television]
    public let issues: [String]
}

public enum ParentRemoteAction: String, Codable, CaseIterable, Sendable { case pause, resume, skip }
public enum ParentBonusTarget: String, Codable, CaseIterable, Sendable { case countdown, budget }
