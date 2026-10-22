//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

@testable import KidsViewingControl

// SPDX-License-Identifier: MPL-2.0
import Testing

@Test
func `clock bursts can use preceding observed wall slack without exceeding it`() {
    var value = ViewingProgressAccumulator()
    value.start(position: 0, at: 0, playing: true)
    #expect(value.sample(position: 0.25, at: 1_000_000_000, playing: true) == 0.25)
    #expect(abs(value.sample(position: 1.78, at: 2_000_000_000, playing: true) - 1.53) < 0.0000001)
    #expect(value.creditedSeconds == 1.78)
    #expect(value.creditedSeconds <= value.observedWallSeconds)
    #expect(value.creditedSeconds <= value.observedMediaSeconds)
}

@Test
func `ten thousand phase shifted samples preserve time and every prefix is wall bounded`() {
    var value = ViewingProgressAccumulator()
    value.start(position: 0, at: 0, playing: true)
    var position = 0.0
    var total = 0.0
    for second in 1 ... 10000 {
        position += second.isMultiple(of: 2) ? 1.999 : 0.001
        total += value.sample(position: position, at: UInt64(second) * 1_000_000_000, playing: true)
        #expect(total <= Double(second) + 0.000000001)
        #expect(total <= position + 0.000000001)
    }
    #expect(abs(total - 10000) < 0.0000001)
}

@Test
func `repeated clocks keep wall time and small regressions cannot double count media`() {
    var value = ViewingProgressAccumulator()
    value.start(position: 10, at: 0, playing: true)
    #expect(value.sample(position: 10, at: 1_000_000_000, playing: true) == 0)
    #expect(value.sample(position: 11, at: 2_000_000_000, playing: true) == 1)
    #expect(value.sample(position: 10.995, at: 2_500_000_000, playing: true) == 0)
    #expect(value.sample(position: 11.5, at: 3_000_000_000, playing: true) == 0.5)
    #expect(value.creditedSeconds == 1.5)
    // An actual rewind rebases without counting the jump. Later real playback
    // of repeated content still consumes viewing time.
    #expect(value.sample(position: 2, at: 4_000_000_000, playing: true) == 0)
    #expect(value.sample(position: 3, at: 5_000_000_000, playing: true) == 1)
    #expect(value.creditedSeconds == 2.5)
}

@Test
func `held seeks and invalid forward jumps never become playing time`() {
    var value = ViewingProgressAccumulator()
    value.start(position: 0, at: 0, playing: true)
    #expect(value.sample(position: 10, at: 1_000_000_000, playing: true) == 0)
    #expect(value.sample(position: 11, at: 2_000_000_000, playing: true) == 1)
    #expect(value.sample(position: 11.5, at: 2_500_000_000, playing: false) == 0.5)
    #expect(value.sample(position: 511, at: 3_000_000_000, playing: false) == 0)
    #expect(value.sample(position: 512, at: 4_000_000_000, playing: true) == 0)
    #expect(value.sample(position: 513, at: 5_000_000_000, playing: true) == 1)
    #expect(value.creditedSeconds == 2.5)
}

@Test
func `stale nonfinite and unobservably long intervals cannot mint usage`() {
    var value = ViewingProgressAccumulator()
    value.start(position: 0, at: 1_000_000_000, playing: true)
    #expect(value.sample(position: 1, at: 0, playing: true) == 0)
    #expect(value.sample(position: 1, at: 2_000_000_000, playing: true) == 1)
    #expect(value.sample(position: .nan, at: 3_000_000_000, playing: true) == 0)
    #expect(value.sample(position: .infinity, at: 4_000_000_000, playing: true) == 0)
    #expect(value.sample(position: 1, at: 5_000_000_000, playing: true) == 0)
    #expect(value.sample(position: 7, at: 11_000_000_000, playing: true) == 0)
    #expect(value.creditedSeconds == 1)
    #expect(value.observedWallSeconds.isFinite)
    #expect(value.observedMediaSeconds.isFinite)
    value.start(position: 7, at: 12_000_000_000, playing: true)
    #expect(value.creditedSeconds == 0)
    #expect(value.sample(position: 8, at: 13_000_000_000, playing: true) == 1)
}

@Test
func `interleaved policy flush and native clock burst preserve real progress`() {
    var value = ViewingProgressAccumulator()
    value.start(position: 0.888, at: 0, playing: true)
    // Anonymous observations captured after real playback stopped. Policy flush
    // and timer samples can straddle the independently updated native clock.
    let samples: [(UInt64, Double)] = [
        (432_315_208, 0.894),
        (685_691_291, 0.894),
        (1_452_103_416, 1.911),
        (2_456_122_458, 2.904),
        (3_493_728_375, 3.88),
        (4_523_701_250, 4.908),
        (5_549_490_750, 5.872),
        (6_593_779_916, 6.904),
        (7_652_238_750, 7.892),
        (8_227_281_000, 8.879),
        (8_693_786_666, 8.873),
        (9_694_521_750, 9.896),
        (10_712_428_041, 10.914),
        (11_766_670_791, 11.9),
        (12_793_706_250, 12.883000000000001),
        (13_853_583_375, 13.906),
        (14_769_940_750, 14.888),
        (14_885_542_333, 15.917),
        (15_893_823_750, 16.894),
    ]
    var previousReport = 0.888
    var pending = 0.0
    for (index, sample) in samples.enumerated() {
        pending += value.sample(position: sample.1, at: sample.0, playing: true)
        #expect(value.creditedSeconds <= value.observedWallSeconds + 0.000000001)
        #expect(value.creditedSeconds <= value.observedMediaSeconds + 0.000000001)
        if [0, 5, 9, 16, 18].contains(index) {
            #expect(abs(sample.1 - previousReport - pending) <= 0.5)
            previousReport = sample.1
            pending = 0
        }
    }
    #expect(value.creditedSeconds > 15.5)
}

@Test
func `clock lead cannot accumulate tolerance on successive updates`() {
    var value = ViewingProgressAccumulator()
    value.start(position: 0, at: 0, playing: true)
    #expect(value.sample(position: 1.4, at: 1_000_000_000, playing: true) == 1)
    // A second 1.4-second advance would leave an unexplained .8-second lead.
    #expect(abs(value.sample(position: 2.8, at: 2_000_000_000, playing: true) - 0.4) < 0.0000001)
    #expect(value.observedMediaSeconds == 1.4)
    #expect(value.sample(position: 3.8, at: 3_000_000_000, playing: true) == 1)
}

@Test
func `clock slack is bounded and cannot cross pause seek or unobserved gap`() {
    var value = ViewingProgressAccumulator()
    value.start(position: 0, at: 0, playing: true)
    for second in 1 ... 10 {
        #expect(value.sample(position: 0, at: UInt64(second) * 1_000_000_000, playing: true) == 0)
    }
    #expect(value.sample(position: 10, at: 11_000_000_000, playing: true) == 0)
    #expect(value.sample(position: 11, at: 12_000_000_000, playing: true) == 1)
    #expect(value.sample(position: 11, at: 13_000_000_000, playing: false) == 0)
    #expect(value.sample(position: 11, at: 14_000_000_000, playing: true) == 0)
    #expect(value.sample(position: 13, at: 15_000_000_000, playing: true) == 0)
    #expect(value.sample(position: 14, at: 16_000_000_000, playing: true) == 1)
    #expect(value.sample(position: 14, at: 17_000_000_000, playing: true) == 0)
    #expect(value.sample(position: 14, at: 23_000_000_000, playing: true) == 0)
    #expect(value.sample(position: 16, at: 24_000_000_000, playing: true) == 0)
    #expect(value.creditedSeconds == 2)
}

@Test
func `subsecond flushes preserve wall bounded progress for phase shifted quantized clocks`() {
    var value = ViewingProgressAccumulator()
    value.start(position: 0, at: 0, playing: true)
    var pending = 0.0
    var previousReport = 0.0
    for tick in 1 ... 20000 {
        let wall = Double(tick) * 0.1
        let position = (wall + 0.4).rounded(.down)
        pending += value.sample(position: position, at: UInt64(tick) * 100_000_000, playing: true)
        #expect(value.creditedSeconds <= wall + 0.0000001)
        #expect(value.creditedSeconds <= position + 0.0000001)
        if tick.isMultiple(of: 37) {
            #expect(abs(position - previousReport - pending) <= 0.5 + 0.0000001)
            previousReport = position
            pending = 0
        }
    }
    #expect(abs(value.creditedSeconds - 2000) < 0.0000001)
}

@Test
func `real native prefix repays timing lag without creating playing time`() {
    var value = ViewingProgressAccumulator()
    let initialPosition = 0.977
    value.start(position: initialPosition, at: 0, playing: true)
    // Anonymous clock/position observations from an unperturbed native run.
    // No account, device, media, credential or absolute timestamp is retained.
    let samples: [(UInt64, Double)] = [
        (261_560_833, 0.9790000000000001),
        (1_293_325_166, 2.004),
        (2_313_467_083, 3.027),
        (3_330_834_375, 4.007),
        (4_361_379_458, 4.991),
        (5_244_164_833, 6.001),
        (5_374_113_375, 6.005),
        (6_382_216_083, 6.995),
        (7_437_507_833, 8.019),
        (8_441_148_375, 8.999),
        (9_461_862_250, 10.021),
        (10_488_909_041, 11.01),
        (11_532_236_458, 11.98),
        (12_135_236_416, 13.016),
        (12_557_787_875, 13.011),
        (13_561_842_291, 13.983),
        (14_571_068_708, 15.016),
        (15_576_284_125, 15.989),
        (16_608_768_458, 16.987000000000002),
        (17_624_381_000, 17.992),
        (18_638_605_708, 18.982),
        (18_779_682_750, 18.982),
        (19_661_524_041, 20.99),
        (20_672_612_458, 20.978),
        (21_709_732_625, 22.013),
        (22_728_651_833, 22.994),
        (23_741_077_291, 24.993),
        (24_744_980_500, 25.006),
        (25_368_255_958, 26.02),
        (25_745_942_833, 26.026),
        (26_761_698_041, 27.98),
        (27_764_119_250, 29.012),
        (28_775_062_958, 30),
        (29_804_938_791, 29.998),
        (30_844_104_625, 32),
        (31_861_594_458, 32.977),
        (32_308_763_125, 32.979),
        (32_863_227_500, 33.998),
        (33_864_706_250, 34.977),
        (34_869_793_500, 36.004),
        (35_918_827_708, 36.99),
        (36_961_640_583, 38.011),
        (38_021_970_625, 38.987),
        (38_810_746_541, 40.019),
        (39_061_537_916, 40.019),
        (40_088_734_750, 40.994),
        (41_099_983_916, 41.982),
        (42_161_576_958, 43.009),
        (43_182_383_041, 43.991),
        (44_249_438_916, 45.006),
        (45_262_756_000, 45.983),
        (45_399_911_291, 45.983),
        (46_318_999_208, 47.009),
        (47_325_840_583, 48.001),
        (48_332_348_833, 48.979),
        (49_361_849_708, 49.988),
        (50_390_992_500, 50.979),
        (51_459_816_375, 52.01),
        (51_959_782_625, 52.992),
        (52_461_734_375, 52.984),
        (53_462_567_041, 54.014),
        (54_520_791_833, 54.998),
        (55_523_493_750, 56.022),
        (56_528_256_666, 57),
        (57_562_912_083, 58.026),
        (58_565_850_791, 58.999),
        (58_872_741_750, 59.987),
        (59_596_031_791, 59.981),
        (60_633_678_416, 61.001),
        (61_654_196_625, 63.001),
        (62_661_918_708, 63.999),
        (63_670_463_125, 63.984),
        (64_686_262_958, 64.977),
        (65_470_060_333, 65.988),
        (65_752_654_291, 66.003),
        (66_762_726_333, 66.988),
        (67_775_421_000, 68.981),
        (68_777_114_458, 70.01),
        (69_834_422_500, 71.002),
        (70_846_284_125, 70.995),
        (71_862_806_333, 72.994),
        (71_864_658_416, 72.994),
    ]
    var credited = 0.0
    var highWater = initialPosition
    var totals: [Double] = []
    for sample in samples {
        let increment = value.sample(position: sample.1, at: sample.0, playing: true)
        #expect(increment >= 0)
        credited += increment
        highWater = max(highWater, sample.1)
        #expect(credited <= Double(sample.0) / 1_000_000_000 + 0.0000001)
        #expect(credited <= highWater - initialPosition + 0.0000001)
        let residual = sample.1 - initialPosition - credited
        #expect(residual >= -0.25 - 0.0000001)
        #expect(residual <= 0.5 + 0.0000001)
        totals.append(credited)
    }
    #expect(abs(totals[69] - 61.654196625) < 0.0000001)
    #expect(abs(totals[73] - 65.011) < 0.0000001)
    let reportCredit = totals[73] - totals[69]
    let reportCursorAdvance = samples[73].1 - samples[69].1
    // This packet catches up a prior lag. Its cumulative endpoint exactly
    // conserves media time; independently bounding each packet rejects it.
    #expect(reportCredit > reportCursorAdvance + 0.25)
    #expect(reportCredit < reportCursorAdvance + 0.5)
    #expect(abs(totals[73] - (samples[73].1 - initialPosition)) < 0.0000001)
    #expect(abs(credited - 71.864658416) < 0.0000001)
}
