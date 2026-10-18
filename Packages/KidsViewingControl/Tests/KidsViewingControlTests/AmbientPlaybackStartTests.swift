//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import KidsViewingControl
import Testing

private struct AmbientRandom: RandomNumberGenerator {
    var state: UInt64
    var draws = 0

    mutating func next() -> UInt64 {
        draws += 1
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private struct AmbientZeroRandom: RandomNumberGenerator {
    mutating func next() -> UInt64 {
        0
    }
}

@Test
func `ambient cannot start an unknown or intro-only duration`() {
    var random = AmbientRandom(state: 42)
    let durations: [Double?] = [nil, -.infinity, -1, 0, 9.9, 10, .nan, .infinity]
    for duration in durations {
        #expect(AmbientPlaybackStart.seconds(runtime: duration, using: &random) == nil)
    }
    #expect(random.draws == 0)
}

@Test
func `ambient lower endpoint skips all ten intro seconds`() {
    var random = AmbientZeroRandom()
    #expect(AmbientPlaybackStart.seconds(runtime: 36000, using: &random) == 10)
    #expect(AmbientPlaybackStart.seconds(runtime: Double(10).nextUp, using: &random) == 10)
}

@Test
func `ambient samples span the ten hour video uniformly without intro or EOF`() throws {
    var random = AmbientRandom(state: 0x1531)
    let duration = 36000.0
    var bins = [Int](repeating: 0, count: 10)
    var sum = 0.0
    var offsets = Set<Double>()
    for _ in 0 ..< 10000 {
        let position = try #require(AmbientPlaybackStart.seconds(runtime: duration, using: &random))
        #expect(position >= 10 && position < duration)
        let normalized = (position - 10) / (duration - 10)
        bins[Int(normalized * 10)] += 1
        sum += normalized
        offsets.insert(position)
    }
    // Fixed-seed coverage catches constant, front-loaded and endpoint-clamped selection.
    let evenlySpread = bins.allSatisfy { (800 ... 1200).contains($0) }
    #expect(evenlySpread)
    #expect((0.48 ... 0.52).contains(sum / 10000))
    #expect(offsets.count == 10000)
}

@Test
func `ambient uses actual metadata duration for each new selection`() throws {
    var random = AmbientRandom(state: 7)
    for runtime in [10.001, 30, 600, 36000, 50000] {
        let first = try #require(AmbientPlaybackStart.seconds(runtime: runtime, using: &random))
        let second = try #require(AmbientPlaybackStart.seconds(runtime: runtime, using: &random))
        #expect(first >= 10 && first < runtime)
        #expect(second >= 10 && second < runtime)
        #expect(first != second)
    }
}
