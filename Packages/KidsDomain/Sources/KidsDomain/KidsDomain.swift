//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum KidsCategory: String, Codable, CaseIterable, Sendable {
    case shows
    case movies
    public var title: String {
        self == .shows ? "Shows" : "Movies"
    }

    public var symbol: String {
        self == .shows ? "tv" : "film"
    }
}

public struct KidsBinding: Codable, Equatable, Hashable, Sendable {
    public var serverID: String
    public var userID: String
    public var showsID: String
    public var moviesID: String
    public init(serverID: String, userID: String, showsID: String, moviesID: String) {
        self.serverID = serverID
        self.userID = userID
        self.showsID = showsID
        self.moviesID = moviesID
    }

    public var libraryIDs: Set<String> {
        [showsID, moviesID]
    }

    public var isValid: Bool {
        !serverID.isEmpty && !userID.isEmpty && !showsID.isEmpty && !moviesID.isEmpty && showsID != moviesID
    }

    public func library(for category: KidsCategory) -> String {
        category == .shows ? showsID : moviesID
    }
}

public struct KidsAccessPolicy: Equatable, Sendable {
    public var administrator: Bool
    public var allLibraries: Bool
    public var deletion: Bool
    public var enabledLibraries: Set<String>
    public init(administrator: Bool, allLibraries: Bool, deletion: Bool, enabledLibraries: Set<String>) {
        self.administrator = administrator
        self.allLibraries = allLibraries
        self.deletion = deletion
        self.enabledLibraries = enabledLibraries
    }

    public func permits(_ binding: KidsBinding) -> Bool {
        binding.isValid && !administrator && !allLibraries && !deletion && enabledLibraries == binding.libraryIDs
    }
}

public struct KidsItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case series, movie, episode }
    public var id: String
    public var name: String
    public var kind: Kind
    public var libraryID: String
    public var seriesID: String?
    public var season: Int?
    public var episode: Int?
    public var runtime: Double?
    public var imageTag: String?
    public var imageOwnerID: String?
    public init(
        id: String,
        name: String,
        kind: Kind,
        libraryID: String,
        seriesID: String? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        runtime: Double? = nil,
        imageTag: String? = nil,
        imageOwnerID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.libraryID = libraryID
        self.seriesID = seriesID
        self.season = season
        self.episode = episode
        self.runtime = runtime
        self.imageTag = imageTag
        self.imageOwnerID = imageOwnerID
    }
}

public enum KidsContractError: Error, Equatable {
    case denied
    case unavailable
    case ambiguousEpisodes
    case missingCursor
    case invalidStateVersion
}

public enum KidsEligibility {
    public static func permits(_ item: KidsItem, binding: KidsBinding) -> Bool {
        guard binding.isValid, !item.id.isEmpty else { return false }
        switch item.kind {
        case .movie: return item.libraryID == binding.moviesID
        case .series: return item.libraryID == binding.showsID
        case .episode:
            guard let season = item.season, let episode = item.episode else { return false }
            return item.libraryID == binding.showsID && !(item.seriesID ?? "").isEmpty
                && season > 0 && episode >= 0
        }
    }

    public static func episodes(_ items: [KidsItem], showID: String, binding: KidsBinding) throws -> [KidsItem] {
        let eligible = items.filter { permits($0, binding: binding) && $0.kind == .episode && $0.seriesID == showID }
        guard !eligible.isEmpty else { throw KidsContractError.unavailable }
        var numbers = Set<String>()
        var ids = Set<String>()
        for item in eligible {
            guard numbers.insert("\(item.season!):\(item.episode!)").inserted,
                  ids.insert(item.id).inserted else { throw KidsContractError.ambiguousEpisodes }
        }
        // Explicit episode zero keeps its indexed order; missing/negative numbers need adult review.
        if items.contains(where: { $0.kind == .episode && $0.seriesID == showID && $0.libraryID == binding.showsID
                && ($0.season == nil || ($0.season ?? 0) < 0 || (($0.season ?? 0) > 0 && ($0.episode == nil || ($0.episode ?? 0) < 0)))
        }) {
            throw KidsContractError.ambiguousEpisodes
        }
        return eligible.sorted { ($0.season!, $0.episode!) < ($1.season!, $1.episode!) }
    }
}

public enum KidsPlaybackMode: String, Codable, Sendable { case ordered, shuffle, movie, once }
public struct KidsProgress: Codable, Equatable, Sendable {
    public var itemID: String?
    public var seconds: Double = 0
    public var complete = false
    public var season: Int?
    public var episode: Int?
    public var selectionID: String?
    public init(
        itemID: String? = nil,
        seconds: Double = 0,
        complete: Bool = false,
        season: Int? = nil,
        episode: Int? = nil,
        selectionID: String? = nil
    ) {
        self.itemID = itemID
        self.seconds = seconds
        self.complete = complete
        self.season = season
        self.episode = episode
        self.selectionID = selectionID
    }
}

public struct KidsShuffleBag: Codable, Equatable, Sendable {
    public var remaining: [String] = []
    public var cycleID: String?
    public var last: String?
    public init() {}
}

public struct KidsSession: Codable, Equatable, Sendable {
    public var showID: String
    public var mode: KidsPlaybackMode
    public var completed = 0
    public var limit: Int // 0 means continuous
    public var itemID: String?
    public var seconds: Double = 0
    public init(showID: String, mode: KidsPlaybackMode, limit: Int) {
        self.showID = showID
        self.mode = mode
        self.limit = limit
    }

    public var permitsAnother: Bool {
        limit == 0 || completed < limit
    }
}

public struct KidsPreferences: Codable, Equatable, Sendable {
    public var episodeLimit = 2
    public var spokenNavigation = false
    public init() {}
}

public struct KidsState: Codable, Equatable, Sendable {
    public var version = 1
    public var binding: KidsBinding
    public var preferences = KidsPreferences()
    public var ordered: [String: KidsProgress] = [:]
    public var movies: [String: KidsProgress] = [:]
    public var shuffle: [String: KidsShuffleBag] = [:]
    public var session: KidsSession?
    public init(binding: KidsBinding) {
        self.binding = binding
    }

    public func orderedNext(showID: String, episodes: [KidsItem]) throws -> (KidsItem, Double, Bool) {
        let episodes = try KidsEligibility.episodes(episodes, showID: showID, binding: binding)
        guard let progress = ordered[showID] else { return (episodes[0], 0, false) }
        if progress.complete {
            return (episodes[0], 0, true)
        }
        guard let index = episodes.firstIndex(where: { $0.id == progress.itemID }) else { throw KidsContractError.missingCursor }
        return (episodes[index], max(0, progress.seconds), false)
    }

    /// A missing cursor never moves implicitly. This candidate is offered for deliberate selection.
    public func missingSuccessor(showID: String, episodes: [KidsItem]) throws -> KidsItem? {
        let eligible = try KidsEligibility.episodes(episodes, showID: showID, binding: binding)
        guard let progress = ordered[showID], !progress.complete,
              !eligible.contains(where: { $0.id == progress.itemID }),
              let season = progress.season, let episode = progress.episode else { return nil }
        return eligible.first { ($0.season!, $0.episode!) > (season, episode) }
    }

    public mutating func nextShuffle(showID: String, episodes: [KidsItem], randomOrder: [String]? = nil) throws -> KidsItem {
        let eligible = try KidsEligibility.episodes(episodes, showID: showID, binding: binding)
        let ids = Set(eligible.map(\.id))
        var bag = shuffle[showID] ?? KidsShuffleBag()
        bag.remaining = bag.remaining.filter { ids.contains($0) }
        if bag.remaining.isEmpty {
            let proposed = randomOrder ?? eligible.map(\.id).shuffled()
            guard Set(proposed) == ids && proposed.count == ids.count else { throw KidsContractError.denied }
            bag.remaining = proposed
            bag.cycleID = UUID().uuidString
            if bag.remaining.count > 1 && bag.remaining.first == bag.last {
                bag.remaining.swapAt(0, 1)
            }
        }
        shuffle[showID] = bag
        guard let item = eligible.first(where: { $0.id == bag.remaining.first }) else { throw KidsContractError.unavailable }
        return item // reservation only: failed starts do not consume the bag
    }

    public mutating func began(item: KidsItem, mode: KidsPlaybackMode, showID: String) throws {
        guard KidsEligibility.permits(item, binding: binding) else { throw KidsContractError.denied }
        if mode == .movie {
            guard item.kind == .movie else { throw KidsContractError.denied }
        } else {
            guard item.kind == .episode, item.seriesID == showID else { throw KidsContractError.denied }
        }
        if mode == .movie || mode == .once {
            session = nil
            return
        }
        guard item.kind == .episode, item.seriesID == showID else { throw KidsContractError.denied }
        if session?.showID != showID || session?.mode != mode || session?.permitsAnother != true {
            session = KidsSession(showID: showID, mode: mode, limit: preferences.episodeLimit)
        }
        if session?.itemID != item.id {
            session?.seconds = 0
        }
        session?.itemID = item.id
        if mode == .ordered {
            let old = ordered[showID]
            ordered[showID] = KidsProgress(
                itemID: item.id,
                seconds: old?.itemID == item.id && old?.complete != true ? old!.seconds : 0,
                season: item.season,
                episode: item.episode,
                selectionID: old?.itemID == item.id ? old?.selectionID : UUID().uuidString
            )
        } else {
            var bag = shuffle[showID] ?? KidsShuffleBag()
            bag.remaining.removeAll { $0 == item.id }
            bag.last = item.id
            shuffle[showID] = bag
        }
    }

    public mutating func checkpoint(item: KidsItem, mode: KidsPlaybackMode, seconds: Double) {
        guard KidsEligibility.permits(item, binding: binding), seconds.isFinite, seconds >= 0 else { return }
        if session?.itemID == item.id && session?.mode == mode {
            session?.seconds = seconds
        }
        // A parent Set Next retires the ordered session, even when it chooses the same item.
        // Time reported by that old stream must not restore the previous resume position.
        if mode == .ordered, session?.mode == .ordered, session?.itemID == item.id,
           let show = item.seriesID, ordered[show]?.itemID == item.id
        {
            ordered[show]?.seconds = seconds
        } else if mode == .movie {
            movies[item.id] = KidsProgress(itemID: item.id, seconds: seconds)
        }
    }

    @discardableResult
    public mutating func finished(item: KidsItem, mode: KidsPlaybackMode, episodes: [KidsItem]) throws -> Bool {
        guard KidsEligibility.permits(item, binding: binding) else { throw KidsContractError.denied }
        if mode == .movie {
            movies[item.id] = KidsProgress(itemID: item.id, complete: true)
            return false
        }
        guard mode != .once, let showID = item.seriesID, session?.itemID == item.id, session?.mode == mode else { return false }
        session?.seconds = 0
        session?.itemID = nil // duplicate end notifications cannot count twice
        session?.completed += 1
        if mode == .ordered {
            let eligible = try KidsEligibility.episodes(episodes, showID: showID, binding: binding)
            guard let i = eligible.firstIndex(where: { $0.id == item.id }) else { throw KidsContractError.unavailable }
            if i + 1 < eligible.count {
                ordered[showID] = KidsProgress(
                    itemID: eligible[i + 1].id,
                    season: eligible[i + 1].season,
                    episode: eligible[i + 1].episode,
                    selectionID: UUID().uuidString
                )
            } else {
                ordered[showID] = KidsProgress(itemID: item.id, complete: true, season: item.season, episode: item.episode)
                return false
            }
        }
        return session?.permitsAnother == true
    }

    public mutating func endSession() {
        session = nil
    }

    public mutating func setNext(_ item: KidsItem) throws {
        guard KidsEligibility.permits(item, binding: binding), item.kind == .episode, let show = item.seriesID else {
            throw KidsContractError.denied
        }
        ordered[show] = KidsProgress(itemID: item.id, season: item.season, episode: item.episode, selectionID: UUID().uuidString)
        session = nil
    }
}

/// Testable parent-gate timing. The PIN itself stays in the platform Keychain.
public struct KidsGate: Codable, Equatable, Sendable {
    public var failures = 0
    public var blockedUntil: Date?
    public var unlockedUntil: Date?
    public init() {}
    public func unlocked(at now: Date) -> Bool {
        (unlockedUntil ?? .distantPast) > now
    }

    public func mayAttempt(at now: Date) -> Bool {
        (blockedUntil ?? .distantPast) <= now
    }

    public mutating func attempt(correct: Bool, now: Date) -> Bool {
        guard mayAttempt(at: now) else { return false }
        if correct {
            failures = 0
            blockedUntil = nil
            unlockedUntil = now.addingTimeInterval(120)
            return true
        }
        failures += 1
        if failures >= 5 {
            blockedUntil = now.addingTimeInterval(min(300, 30 * Double(failures - 4)))
        }
        return false
    }

    public mutating func touch(at now: Date) {
        if unlocked(at: now) {
            unlockedUntil = now.addingTimeInterval(120)
        }
    }

    public mutating func lock() {
        unlockedUntil = nil
    }
}
