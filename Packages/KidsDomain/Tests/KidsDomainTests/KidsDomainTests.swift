//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
@testable import KidsDomain
import Testing

private let binding = KidsBinding(serverID: "server", userID: "kid", showsID: "tv", moviesID: "movies")
private func episode(_ id: String, season: Int = 1, number: Int = 1, library: String = "tv") -> KidsItem {
    KidsItem(id: id, name: id, kind: .episode, libraryID: library, seriesID: "show", season: season, episode: number)
}

private let episodes = [episode("a"), episode("b", number: 2), episode("c", season: 2)]

@Test
func `permission boundary rejects every broad policy`() {
    #expect(KidsAccessPolicy(administrator: false, allLibraries: false, deletion: false, enabledLibraries: ["tv", "movies"])
        .permits(binding))
    for policy in [
        KidsAccessPolicy(administrator: true, allLibraries: false, deletion: false, enabledLibraries: binding.libraryIDs),
        .init(administrator: false, allLibraries: true, deletion: false, enabledLibraries: binding.libraryIDs),
        .init(administrator: false, allLibraries: false, deletion: true, enabledLibraries: binding.libraryIDs),
        .init(administrator: false, allLibraries: false, deletion: false, enabledLibraries: ["tv", "movies", "other"]),
        .init(administrator: false, allLibraries: false, deletion: false, enabledLibraries: ["tv"])
    ] {
        #expect(!policy.permits(binding))
    }
}

@Test
func `eligibility rejects wrong library type specials and extras`() throws {
    #expect(!KidsEligibility.permits(episode("denied", library: "other"), binding: binding))
    #expect(!KidsEligibility.permits(episode("special", season: 0), binding: binding))
    #expect(!KidsEligibility.permits(KidsItem(id: "m", name: "m", kind: .movie, libraryID: "tv"), binding: binding))
    #expect(try KidsEligibility.episodes(episodes.reversed() + [episode("special", season: 0)], showID: "show", binding: binding)
        .map(\.id) == [
            "a",
            "b",
            "c"
        ])
    #expect(throws: KidsContractError.ambiguousEpisodes) { try KidsEligibility.episodes(
        [episode("a"), episode("dup")],
        showID: "show",
        binding: binding
    ) }
    #expect(throws: KidsContractError.ambiguousEpisodes) { try KidsEligibility.episodes(
        [episode("a"), episode("bad", number: -1)],
        showID: "show",
        binding: binding
    ) }
}

@Test
func `ordered resume is independent of random and one off playback`() throws {
    var state = KidsState(binding: binding)
    #expect(try state.orderedNext(showID: "show", episodes: episodes).0.id == "a")
    try state.began(item: episodes[0], mode: .ordered, showID: "show")
    state.checkpoint(item: episodes[0], mode: .ordered, seconds: 123)
    try state.began(item: episodes[2], mode: .shuffle, showID: "show")
    state.checkpoint(item: episodes[2], mode: .shuffle, seconds: 900)
    #expect(try state.orderedNext(showID: "show", episodes: episodes).1 == 123)
    try state.began(item: episodes[2], mode: .once, showID: "show")
    #expect(try state.orderedNext(showID: "show", episodes: episodes).0.id == "a")
}

@Test
func `completion counts exactly once and honors budget and finale`() throws {
    var state = KidsState(binding: binding)
    try state.began(item: episodes[0], mode: .ordered, showID: "show")
    #expect(try state.finished(item: episodes[0], mode: .ordered, episodes: episodes))
    #expect(try !(state.finished(item: episodes[0], mode: .ordered, episodes: episodes)))
    #expect(state.session?.completed == 1)
    try state.began(item: episodes[1], mode: .ordered, showID: "show")
    #expect(try !(state.finished(item: episodes[1], mode: .ordered, episodes: episodes)))
    #expect(state.session?.completed == 2)
    try state.began(item: episodes[2], mode: .ordered, showID: "show")
    #expect(try !(state.finished(item: episodes[2], mode: .ordered, episodes: episodes)))
    #expect(try state.orderedNext(showID: "show", episodes: episodes).2)
}

@Test
func `shuffle bag reservations failures and refills`() throws {
    var state = KidsState(binding: binding)
    for id in ["a", "b", "c"] {
        let item = try state.nextShuffle(showID: "show", episodes: episodes, randomOrder: ["a", "b", "c"])
        #expect(item.id == id)
        #expect(try state.nextShuffle(showID: "show", episodes: episodes).id == id) // failed start reserves, not consumes
        try state.began(item: item, mode: .shuffle, showID: "show")
    }
    #expect(try state.nextShuffle(showID: "show", episodes: episodes, randomOrder: ["c", "b", "a"]).id == "b")
    #expect(throws: KidsContractError.denied) {
        var fresh = KidsState(binding: binding)
        _ = try fresh.nextShuffle(showID: "show", episodes: episodes, randomOrder: ["denied"])
    }
}

@Test
func `one episode show and random finale`() throws {
    var state = KidsState(binding: binding)
    let e = [episodes[2]]
    let next = try state.nextShuffle(showID: "show", episodes: e)
    try state.began(item: next, mode: .shuffle, showID: "show")
    #expect(try state.finished(item: next, mode: .shuffle, episodes: e))
    #expect(try state.nextShuffle(showID: "show", episodes: e).id == next.id)
}

@Test
func `additions never rewind and missing cursor requires explicit recovery`() throws {
    var state = KidsState(binding: binding)
    try state.setNext(episodes[2])
    #expect(try state.orderedNext(showID: "show", episodes: episodes + [episode("earlier", season: 1, number: 3)]).0.id == "c")
    #expect(throws: KidsContractError.missingCursor) { try state.orderedNext(showID: "show", episodes: [episodes[0]]) }
}

@Test
func `movie and failed start never change ordered progress`() throws {
    var state = KidsState(binding: binding)
    let movie = KidsItem(id: "m", name: "Movie", kind: .movie, libraryID: "movies")
    state.checkpoint(item: movie, mode: .movie, seconds: 44)
    #expect(state.movies["m"]?.seconds == 44)
    #expect(try !(state.finished(item: movie, mode: .movie, episodes: [])))
    #expect(state.movies["m"]?.complete == true)
    #expect(state.ordered.isEmpty)
    #expect(throws: KidsContractError.denied) { try state.began(item: episode("bad", library: "other"), mode: .ordered, showID: "show") }
    #expect(state.session == nil)
}

@Test
func `parent gate backoff background and inactivity`() {
    let now = Date(timeIntervalSince1970: 1000)
    var gate = KidsGate()
    for _ in 0 ..< 5 {
        let ok = gate.attempt(correct: false, now: now)
        #expect(!ok)
    }
    let blocked = gate.attempt(correct: true, now: now)
    #expect(!blocked)
    let unlocked = gate.attempt(correct: true, now: now.addingTimeInterval(31))
    #expect(unlocked)
    #expect(gate.unlocked(at: now.addingTimeInterval(32)))
    #expect(!gate.unlocked(at: now.addingTimeInterval(152)))
    gate.lock()
    #expect(!gate.unlocked(at: now))
}

@Test
func `shuffle interrupted timeline and budget survive a crash`() throws {
    var state = KidsState(binding: binding)
    try state.began(item: episodes[0], mode: .ordered, showID: "show")
    state.checkpoint(item: episodes[0], mode: .ordered, seconds: 40)
    let random = try state.nextShuffle(showID: "show", episodes: episodes, randomOrder: ["b", "c", "a"])
    try state.began(item: random, mode: .shuffle, showID: "show")
    state.checkpoint(item: random, mode: .shuffle, seconds: 92)
    let restored = try JSONDecoder().decode(KidsState.self, from: JSONEncoder().encode(state))
    #expect(restored.session?.itemID == "b")
    #expect(restored.session?.seconds == 92)
    #expect(restored.session?.completed == 0)
    #expect(try restored.orderedNext(showID: "show", episodes: episodes).1 == 40)
    #expect(restored.shuffle["show"]?.remaining == ["c", "a"])
}

@Test
func `one episode cap continuous and wrong mode completion`() throws {
    var state = KidsState(binding: binding)
    state.preferences.episodeLimit = 1
    try state.began(item: episodes[0], mode: .shuffle, showID: "show")
    #expect(try !(state.finished(item: episodes[0], mode: .ordered, episodes: episodes)))
    #expect(state.session?.completed == 0)
    #expect(try !(state.finished(item: episodes[0], mode: .shuffle, episodes: episodes)))
    #expect(state.session?.completed == 1)
    state.endSession()
    state.preferences.episodeLimit = 0
    for item in episodes {
        try state.began(item: item, mode: .shuffle, showID: "show")
        #expect(try state.finished(item: item, mode: .shuffle, episodes: episodes))
    }
    #expect(state.session?.completed == 3)
    #expect(state.ordered.isEmpty)
}

@Test
func `missing season and mismatched playback type cannot guess or change state`() throws {
    let missing = KidsItem(id: "missing", name: "Missing number", kind: .episode, libraryID: "tv", seriesID: "show", episode: 1)
    #expect(throws: KidsContractError.ambiguousEpisodes) { try KidsEligibility.episodes(
        episodes + [missing],
        showID: "show",
        binding: binding
    ) }
    var state = KidsState(binding: binding)
    #expect(throws: KidsContractError.denied) { try state.began(item: episodes[0], mode: .movie, showID: "show") }
    #expect(state == KidsState(binding: binding))
    try state.began(item: episodes[0], mode: .ordered, showID: "show")
    state.checkpoint(item: episodes[0], mode: .ordered, seconds: .nan)
    state.checkpoint(item: episodes[0], mode: .ordered, seconds: -20)
    #expect(state.ordered["show"]?.seconds == 0)
}

@Test
func `missing episode offers explicit forward successor without altering saved progress`() throws {
    var state = KidsState(binding: binding)
    try state.began(item: episodes[1], mode: .ordered, showID: "show")
    state.checkpoint(item: episodes[1], mode: .ordered, seconds: 80)
    let retained = state
    #expect(try state.missingSuccessor(showID: "show", episodes: [episodes[0], episodes[2]])?.id == "c")
    #expect(state == retained)
    #expect(try state.missingSuccessor(showID: "show", episodes: [episodes[0]]) == nil)
    #expect(try state.missingSuccessor(showID: "show", episodes: episodes) == nil)
}

@Test
func `parent Set Next on the playing episode survives old checkpoints and completion`() throws {
    var state = KidsState(binding: binding)
    try state.began(item: episodes[0], mode: .ordered, showID: "show")
    state.checkpoint(item: episodes[0], mode: .ordered, seconds: 120)
    try state.setNext(episodes[0])
    // The currently paused stream can still report time after the parent chooses a fresh start.
    state.checkpoint(item: episodes[0], mode: .ordered, seconds: 120)
    #expect(try state.orderedNext(showID: "show", episodes: episodes).1 == 0)
    #expect(try !state.finished(item: episodes[0], mode: .ordered, episodes: episodes))
    #expect(try state.orderedNext(showID: "show", episodes: episodes).0.id == "a")
    #expect(try state.orderedNext(showID: "show", episodes: episodes).1 == 0)
    // A new explicit Next session owns progress again.
    try state.began(item: episodes[0], mode: .ordered, showID: "show")
    state.checkpoint(item: episodes[0], mode: .ordered, seconds: 10)
    #expect(try state.orderedNext(showID: "show", episodes: episodes).1 == 10)
}

@Test
func `explicit episode zero stays in indexed order and can be the sole episode`() throws {
    let zero = episode("zero", number: 0)
    #expect(KidsEligibility.permits(zero, binding: binding))
    #expect(try KidsEligibility.episodes([episode("one"), zero], showID: "show", binding: binding).map(\.id) == ["zero", "one"])
    #expect(try KidsEligibility.episodes([zero], showID: "show", binding: binding) == [zero])
    var state = KidsState(binding: binding)
    let ordered = try KidsEligibility.episodes([zero, episode("one")], showID: "show", binding: binding)
    #expect(try state.orderedNext(showID: "show", episodes: ordered).0.id == "zero")
    try state.began(item: zero, mode: .ordered, showID: "show")
    state.checkpoint(item: zero, mode: .ordered, seconds: 20)
    #expect(try state.orderedNext(showID: "show", episodes: ordered).1 == 20)
    #expect(try state.finished(item: zero, mode: .ordered, episodes: ordered))
    #expect(try state.orderedNext(showID: "show", episodes: ordered).0.id == "one")
}

@Test
func `episode zero does not admit missing numbering specials duplicates or other libraries`() throws {
    var missing = episode("missing")
    missing.episode = nil
    let zero = episode("zero", number: 0)
    #expect(!KidsEligibility.permits(missing, binding: binding))
    #expect(!KidsEligibility.permits(episode("special", season: 0, number: 0), binding: binding))
    #expect(!KidsEligibility.permits(episode("other", number: 0, library: "other"), binding: binding))
    for rejected in [[zero, missing], [zero, episode("duplicate", number: 0)], [zero, episode("negative", number: -1)]] {
        #expect(throws: KidsContractError.ambiguousEpisodes) { try KidsEligibility.episodes(rejected, showID: "show", binding: binding) }
    }
}
