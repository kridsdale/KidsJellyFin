//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation

public extension ParentControlAPI {
    func profileSettings(childUserID: String) async throws -> ParentProfileSettings {
        try requireConnected()
        let value: ParentProfileSettings = try await http.request(
            "api/parent/v1/profiles/\(ParentHTTP.identifier(childUserID))/settings",
            headers: headers
        )
        guard value.childUserID == childUserID, value.revision >= 0,
              TimeZone(identifier: value.timeZone) != nil,
              (0 ... 1440).contains(value.budget.dailyMinutes), value.budget.usedSeconds >= 0, value.budget.bonusSeconds >= 0,
              (value.budget.reservedSeconds ?? 0) >= 0, (value.budget.unconfirmedSeconds ?? 0) >= 0,
              (value.budget.serverRemainingSeconds ?? 0) >= 0,
              value.routines.count <= 32, Set(value.routines.map(\.id)).count == value.routines.count
        else { throw ParentControlError.malformedResponse }
        for routine in value.routines {
            try routine.validate()
        }
        try value.shuffle.validate()
        return value
    }

    func finishEpisode(
        tv: ControlledTV,
        birdItemID: String,
        maximumMinutes: Int,
        commandID: UUID = UUID()
    ) async throws -> ParentCommandReceipt {
        try require("finish-episode-v1")
        guard tv.online, tv.canEnforceDeadline, (1 ... 240).contains(maximumMinutes) else { throw ParentControlError.invalidSelection }
        _ = try ParentHTTP.identifier(birdItemID)
        struct Request: Encodable {
            let commandID: UUID
            let deviceID: String
            let childUserID: String
            let maxDurationSeconds: Int
            let birdItemID: String
            let expectedRevision: Int
        }
        return try await command("finish-episode", value: Request(
            commandID: commandID,
            deviceID: tv.id,
            childUserID: tv.childUserID,
            maxDurationSeconds: maximumMinutes * 60,
            birdItemID: birdItemID,
            expectedRevision: tv.revision
        ), id: commandID)
    }

    func saveRoutines(
        profile: ParentProfileSettings,
        routines: [ViewingRoutine],
        timeZone: String,
        commandID: UUID = UUID()
    ) async throws -> ParentCommandReceipt {
        try require("routines-v1")
        guard TimeZone(identifier: timeZone) != nil, routines.count <= 32,
              Set(routines.map(\.id)).count == routines.count else { throw ParentControlError.invalidRoutine }
        for routine in routines {
            try routine.validate()
        }
        struct Request: Encodable {
            let commandID: UUID
            let childUserID: String
            let expectedRevision: Int
            let timeZone: String
            let routines: [ViewingRoutine]
        }
        return try await command(
            "routines",
            value: Request(
                commandID: commandID,
                childUserID: profile.childUserID,
                expectedRevision: profile.revision,
                timeZone: timeZone,
                routines: routines
            ),
            id: commandID
        )
    }

    func saveBudget(
        profile: ParentProfileSettings,
        enabled: Bool,
        dailyMinutes: Int,
        commandID: UUID = UUID()
    ) async throws -> ParentCommandReceipt {
        try require("daily-budget-v1")
        guard (0 ... 1440).contains(dailyMinutes) else { throw ParentControlError.invalidBudget }
        struct Request: Encodable { let commandID: UUID
            let childUserID: String
            let expectedRevision: Int
            let enabled: Bool
            let dailyMinutes: Int
        }
        return try await command(
            "budgets",
            value: Request(
                commandID: commandID,
                childUserID: profile.childUserID,
                expectedRevision: profile.revision,
                enabled: enabled,
                dailyMinutes: dailyMinutes
            ),
            id: commandID
        )
    }

    func bonusTime(
        childUserID: String,
        tv: ControlledTV?,
        target: ParentBonusTarget,
        minutes: Int,
        profileRevision: Int,
        commandID: UUID = UUID()
    ) async throws -> ParentCommandReceipt {
        try require("bonus-time-v1")
        guard (1 ... 60).contains(minutes) else { throw ParentControlError.invalidBudget }
        if target == .countdown {
            guard let tv, tv.childUserID == childUserID, tv.countdown != nil, tv.online else { throw ParentControlError.invalidSelection }
        }
        if target == .budget, profileRevision < 0 {
            throw ParentControlError.invalidSelection
        }
        struct Request: Encodable {
            let commandID: UUID
            let childUserID: String
            let deviceID: String?
            let target: ParentBonusTarget
            let seconds: Int
            let expectedRevision: Int
            enum CodingKeys: String, CodingKey { case commandID, childUserID, deviceID, target, seconds, expectedRevision }
            func encode(to encoder: any Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                try values.encode(commandID, forKey: .commandID)
                try values.encode(childUserID, forKey: .childUserID)
                try values.encode(deviceID, forKey: .deviceID)
                try values.encode(target, forKey: .target)
                try values.encode(seconds, forKey: .seconds)
                try values.encode(expectedRevision, forKey: .expectedRevision)
            }
        }
        return try await command(
            "bonuses",
            value: Request(
                commandID: commandID,
                childUserID: childUserID,
                deviceID: target == .countdown ? tv?.id : nil,
                target: target,
                seconds: minutes * 60,
                expectedRevision: target == .countdown ? tv!.revision : profileRevision
            ),
            id: commandID
        )
    }

    func remote(tv: ControlledTV, action: ParentRemoteAction, commandID: UUID = UUID()) async throws -> ParentCommandReceipt {
        try require("remote-control-v1")
        guard tv.online else { throw ParentControlError.invalidSelection }
        struct Request: Encodable { let commandID: UUID
            let deviceID: String
            let childUserID: String
            let action: ParentRemoteAction
            let expectedRevision: Int
        }
        return try await command("remote", value: Request(
            commandID: commandID,
            deviceID: tv.id,
            childUserID: tv.childUserID,
            action: action,
            expectedRevision: tv.revision
        ), id: commandID)
    }

    func episodes(childUserID: String, showID: String, cursor: String? = nil) async throws -> ParentPage<ParentEpisode> {
        try require("episode-exclusions-v1")
        var query = try pageQuery(cursor)
        try query.append(.init(name: "showID", value: ParentHTTP.identifier(showID)))
        let page: ParentPage<ParentEpisode> = try await http.request(
            "api/parent/v1/profiles/\(ParentHTTP.identifier(childUserID))/episodes",
            headers: headers,
            query: query
        )
        guard page.childUserID == childUserID, page.showID == showID,
              page.items.allSatisfy({ $0.showID == showID }) else { throw ParentControlError.serverMismatch }
        return page
    }

    func setEpisode(
        profile: ParentProfileSettings,
        episode: ParentEpisode,
        excluded: Bool,
        commandID: UUID = UUID()
    ) async throws -> ParentCommandReceipt {
        try require("episode-exclusions-v1")
        _ = try ParentHTTP.identifier(episode.id)
        struct Request: Encodable { let commandID: UUID
            let childUserID: String
            let episodeID: String
            let excluded: Bool
            let expectedRevision: Int
        }
        return try await command("episodes/availability", value: Request(
            commandID: commandID,
            childUserID: profile.childUserID,
            episodeID: episode.id,
            excluded: excluded,
            expectedRevision: profile.revision
        ), id: commandID)
    }

    func saveShuffle(
        profile: ParentProfileSettings,
        preferences: ParentShufflePreferences,
        commandID: UUID = UUID()
    ) async throws -> ParentCommandReceipt {
        try require("shuffle-preferences-v1")
        try preferences.validate()
        struct Request: Encodable {
            let commandID: UUID
            let childUserID: String
            let expectedRevision: Int
            let preferUnwatched: Bool
            let repeatCooldownDays: Int
            let preferredShowIDs: [String]
        }
        return try await command("shuffle", value: Request(
            commandID: commandID,
            childUserID: profile.childUserID,
            expectedRevision: profile.revision,
            preferUnwatched: preferences.preferUnwatched,
            repeatCooldownDays: preferences.repeatCooldownDays,
            preferredShowIDs: preferences.preferredShowIDs
        ), id: commandID)
    }

    func reviewInbox(cursor: String? = nil) async throws -> ParentPage<PlaylistReviewEntry> {
        try require("review-inbox-v1")
        let page: ParentPage<PlaylistReviewEntry> = try await http.request(
            "api/parent/v1/review-inbox",
            headers: headers,
            query: pageQuery(cursor)
        )
        guard page.items.allSatisfy({ $0.newVideoCount >= 0 }) else { throw ParentControlError.malformedResponse }
        return page
    }

    func history(childUserID: String, cursor: String? = nil) async throws -> ParentPage<ViewingHistoryEntry> {
        try require("viewing-history-v1")
        let page: ParentPage<ViewingHistoryEntry> = try await http.request(
            "api/parent/v1/profiles/\(ParentHTTP.identifier(childUserID))/history",
            headers: headers,
            query: pageQuery(cursor)
        )
        guard page.childUserID == childUserID,
              page.items.allSatisfy({ $0.watchedSeconds >= 0 }) else { throw ParentControlError.malformedResponse }
        return page
    }

    func health() async throws -> ParentServerHealth {
        try require("health-v1")
        let value: ParentServerHealth = try await http.request("api/parent/v1/health", headers: headers)
        guard (value.storageFreeBytes ?? 0) >= 0, (value.pendingJobs ?? 0) >= 0,
              (value.failedJobs ?? 0) >= 0 else { throw ParentControlError.malformedResponse }
        return value
    }

    func commandStatus(id: UUID) async throws -> ParentCommandReceipt {
        try requireConnected()
        let receipt: ParentCommandReceipt = try await http.request("api/parent/v1/commands/\(id.uuidString)", headers: headers)
        guard receipt.commandID == id else { throw ParentControlError.malformedResponse }
        return receipt
    }

    private func pageQuery(_ cursor: String?) throws -> [URLQueryItem] {
        guard let cursor else { return [] }
        guard !cursor.isEmpty, cursor.utf8.count <= 512 else { throw ParentControlError.invalidSelection }
        return [.init(name: "cursor", value: cursor)]
    }
}
