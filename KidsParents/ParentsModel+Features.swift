//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation
import KidsParentControl

struct ParentServiceConnection: Codable {
    let server: ParentServer
    let serverID: String
    let adultUserID: String
    let token: String
}

extension ParentsModel {
    func supports(_ feature: String) -> Bool {
        capabilities?.supports(feature) == true
    }

    func canUse(_ feature: String) -> Bool {
        !demo && !busy && !locked && !needsRefresh && supports(feature)
    }

    func clearFamilyState() {
        profile = nil
        reviewEntries = []
        reviewCursor = nil
        historyEntries = []
        historyCursor = nil
        episodes = []
        episodeCursor = nil
        episodeEditingProfile = nil
        serverHealth = nil
        needsRefresh = false
        lastCommand = nil
    }

    func restoreControlConnection() async throws {
        guard !locked, controls == nil, let credential,
              let saved = try credentialStore.read("parentService", as: ParentServiceConnection.self),
              saved.serverID == credential.serverID, saved.adultUserID == credential.userID else { return }
        let api = ParentControlAPI(server: saved.server, serverID: saved.serverID, token: saved.token, transport: transport)
        try await loadControls(api)
        controls = api
        try await loadProfileState(api)
        controlStatus = "Parent service connected."
    }

    func pollControls() async {
        guard !demo, !locked, !busy, let controls else { return }
        busy = true
        defer { busy = false }
        do {
            try await loadControls(controls)
            try await loadProfileState(controls)
            if let previous = lastCommand, !["applied", "birds", "cancelled", "failed"].contains(previous.status) {
                let current = try await controls.commandStatus(id: previous.commandID)
                lastCommand = current
                notice = "Server command status: \(current.status)."
            }
            needsRefresh = false
            controlStatus = "Parent service connected."
        } catch {
            needsRefresh = true
            controlStatus = "Parent service unavailable. Changes are paused until fresh state is available."
            if let failure = error as? ParentControlError, [.unauthorized, .serverMismatch].contains(failure) {
                self.controls = nil
                capabilities = nil
                clearFamilyState()
            }
        }
    }

    func loadProfileState(_ api: ParentControlAPI) async throws {
        let features = ["routines-v1", "daily-budget-v1", "bonus-time-v1", "episode-exclusions-v1", "shuffle-preferences-v1"]
        guard features.contains(where: supports), !selectedChild.isEmpty else { return }
        let child = selectedChild
        let state = try await api.profileSettings(childUserID: child)
        guard selectedChild == child else { return }
        profile = state
    }

    func loadProfile() async {
        guard let controls else { return }
        await perform {
            try await self.loadProfileState(controls)
            self.needsRefresh = false
        }
    }

    func finishCurrentEpisode() async {
        guard canUse("finish-episode-v1"), let controls, let tv = chosenTV,
              dashboard?.birdVideos.contains(where: { $0.id == selectedBird }) == true else { return }
        await mutate {
            try await controls.finishEpisode(tv: tv, birdItemID: self.selectedBird, maximumMinutes: self.minutes)
        }
    }

    func giveExtraTime(_ target: ParentBonusTarget, minutes: Int = 10) async {
        guard canUse("bonus-time-v1"), let controls else { return }
        let tv = target == .countdown ? chosenTV : nil
        guard let child = target == .countdown ? tv?.childUserID : profile?.childUserID else { return }
        let revision = target == .budget ? profile?.revision ?? -1 : 0
        await mutate {
            try await controls.bonusTime(childUserID: child, tv: tv, target: target, minutes: minutes, profileRevision: revision)
        }
    }

    func remote(_ action: ParentRemoteAction) async {
        guard canUse("remote-control-v1"), let controls, let tv = chosenTV else { return }
        await mutate { try await controls.remote(tv: tv, action: action) }
    }

    func saveRoutines(_ routines: [ViewingRoutine], timeZone: String, profile: ParentProfileSettings) async {
        guard canUse("routines-v1"), let controls, profile.childUserID == selectedChild else { return }
        await mutate { try await controls.saveRoutines(profile: profile, routines: routines, timeZone: timeZone) }
    }

    func saveBudget(enabled: Bool, minutes: Int, profile: ParentProfileSettings) async {
        guard canUse("daily-budget-v1"), let controls, profile.childUserID == selectedChild else { return }
        await mutate { try await controls.saveBudget(profile: profile, enabled: enabled, dailyMinutes: minutes) }
    }

    func saveShuffle(_ preferences: ParentShufflePreferences, profile: ParentProfileSettings) async {
        guard canUse("shuffle-preferences-v1"), let controls, profile.childUserID == selectedChild else { return }
        let allowed = Set(dashboard?.shows.filter { $0.childUserID == selectedChild }.map(\.id) ?? [])
        guard Set(preferences.preferredShowIDs).isSubset(of: allowed) else { error = "Refresh and choose available Kid TV shows."
            return
        }
        await mutate { try await controls.saveShuffle(profile: profile, preferences: preferences) }
    }

    func loadEpisodes(showID: String, more: Bool = false) async {
        guard supports("episode-exclusions-v1"), let controls, !selectedChild.isEmpty,
              dashboard?.shows.contains(where: { $0.id == showID && $0.childUserID == selectedChild }) == true else { return }
        if !more {
            episodes = []
            episodeCursor = nil
            episodeShowID = showID
            episodeEditingProfile = profile
        }
        let child = selectedChild
        let cursor = more ? episodeCursor : nil
        if more && cursor == nil {
            return
        }
        await perform {
            let page = try await controls.episodes(childUserID: child, showID: showID, cursor: cursor)
            guard self.selectedChild == child, self.episodeShowID == showID else { return }
            try self.validatePage(
                existingIDs: more ? self.episodes.map(\.id) : [],
                ids: page.items.map(\.id),
                oldCursor: cursor,
                nextCursor: page.nextCursor
            )
            self.episodes = more ? self.episodes + page.items : page.items
            self.episodeCursor = page.nextCursor
        }
    }

    func excludeEpisode(_ episode: ParentEpisode, excluded: Bool) async {
        guard canUse("episode-exclusions-v1"), let controls, let profile = episodeEditingProfile, profile.childUserID == selectedChild,
              episodes.contains(where: { $0.id == episode.id && $0.showID == episode.showID }) else { return }
        await mutate { try await controls.setEpisode(profile: profile, episode: episode, excluded: excluded) }
        if !needsRefresh {
            await loadEpisodes(showID: episode.showID)
        }
    }

    func loadInbox(more: Bool = false) async {
        guard supports("review-inbox-v1"), let controls else { return }
        let cursor = more ? reviewCursor : nil
        if more && cursor == nil {
            return
        }
        await perform {
            let page = try await controls.reviewInbox(cursor: cursor)
            try self.validatePage(
                existingIDs: more ? self.reviewEntries.map(\.id) : [],
                ids: page.items.map(\.id),
                oldCursor: cursor,
                nextCursor: page.nextCursor
            )
            self.reviewEntries = more ? self.reviewEntries + page.items : page.items
            self.reviewCursor = page.nextCursor
        }
    }

    func loadHistory(more: Bool = false) async {
        guard supports("viewing-history-v1"), let controls, !selectedChild.isEmpty else { return }
        let child = selectedChild
        let cursor = more ? historyCursor : nil
        if more && cursor == nil {
            return
        }
        await perform {
            let page = try await controls.history(childUserID: child, cursor: cursor)
            guard self.selectedChild == child else { return }
            try self.validatePage(
                existingIDs: more ? self.historyEntries.map(\.id) : [],
                ids: page.items.map(\.id),
                oldCursor: cursor,
                nextCursor: page.nextCursor
            )
            self.historyEntries = more ? self.historyEntries + page.items : page.items
            self.historyCursor = page.nextCursor
        }
    }

    func loadHealth() async {
        guard supports("health-v1"), let controls else { return }
        await perform { self.serverHealth = try await controls.health() }
    }

    private func mutate(_ operation: () async throws -> ParentCommandReceipt) async {
        guard let controls else { return }
        await perform {
            let receipt = try await operation()
            self.lastCommand = receipt
            self.notice = "Server status: \(receipt.status). TV delivery is shown separately."
            try await self.loadControls(controls)
            try await self.loadProfileState(controls)
            self.needsRefresh = false
        }
    }

    private func validatePage(existingIDs: [String], ids: [String], oldCursor: String?, nextCursor: String?) throws {
        guard Set(existingIDs + ids).count == existingIDs.count + ids.count,
              oldCursor == nil || nextCursor != oldCursor else { throw ParentControlError.malformedResponse }
    }

    func loadFamilyPreview() {
        profile = ParentProfileSettings(
            childUserID: "kids",
            revision: 1,
            timeZone: "America/Los_Angeles",
            routines: [ViewingRoutine()],
            budget: .init(
                enabled: true,
                dailyMinutes: 60,
                usedSeconds: 1500,
                bonusSeconds: 0,
                localDate: "2026-10-17",
                reservedSeconds: 30,
                unconfirmedSeconds: 0,
                serverRemainingSeconds: 2070
            ),
            shuffle: .init(preferUnwatched: true, repeatCooldownDays: 7, preferredShowIDs: ["bear"]),
            excludedEpisodeIDs: []
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        reviewEntries = (try? decoder.decode(
            [PlaylistReviewEntry].self,
            from: Data(
                #"[{"id":"review","collectionID":"bear","snapshotID":"snapshot","title":"Little Bear playlist","newVideoCount":3,"createdAt":"2026-10-17T19:00:00Z","status":"needsReview"}]"#
                    .utf8
            )
        )) ?? []
        historyEntries = (try? decoder.decode(
            [ViewingHistoryEntry].self,
            from: Data(
                #"[{"id":"viewing","itemID":"snow","title":"A Snowy Day","deviceName":"Living room","startedAt":"2026-10-17T19:00:00Z","watchedSeconds":1320,"evidence":"clientReported"}]"#
                    .utf8
            )
        )) ?? []
        serverHealth = try? decoder.decode(
            ParentServerHealth.self,
            from: Data(
                #"{"observedAt":"2026-10-17T19:00:00Z","jellyfin":"healthy","worker":"idle","storageFreeBytes":1200000000000,"pendingJobs":2,"failedJobs":0,"televisions":[{"id":"living","name":"Living room","online":true,"lastSeen":"2026-10-17T18:59:58Z"}],"issues":[]}"#
                    .utf8
            )
        )
    }
}
