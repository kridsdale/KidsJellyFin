//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
@testable import SwiftfinVLC
import SwiftUI
import XCTest

@MainActor
final class VLCPassiveObservationTests: XCTestCase {
    private final class Engine: VLCNativeEngine {
        var frame = VLCPlaybackFrame()
        var subtitleTracks: [VLCSubtitleTrack] = []
        var statistics: VLCNativeCounterSnapshot?
        var statisticsReads = 0
        var passiveStatistics: VLCNativeCounterSnapshot? {
            statisticsReads += 1
            return statistics
        }

        var nativeTimeObservation: VLCNativeTimeObservation?
        var rejectSeek = false
        var rejectOpen = false
        var update: (@MainActor () -> Void)?
        func surface(controller: VLCPlaybackController, generation: UUID) -> AnyView {
            AnyView(Color.clear)
        }

        func observeUpdates(_ update: @escaping @MainActor () -> Void) {
            self.update = update
        }

        func cancelUpdates() {
            update = nil
        }

        func open(_ request: VLCPlaybackRequest) throws {
            if rejectOpen {
                throw NSError(domain: "not emitted private fixture", code: 1)
            }
        }

        func play() throws {}
        func pause() {}
        func stop() {}
        func seek(_ time: Duration) throws {
            if rejectSeek {
                throw NSError(domain: "not emitted private fixture", code: 2)
            }
            // Reproduce the SDK's optimistic UI clock, without any native clock receipt.
            frame.time = time
        }

        func jump(_ offset: Duration) {}
        func rate(_ value: Float) throws {}
        func audioTrack(_ index: Int?) {}
        func subtitleTrack(_ index: Int?) {}
        func aspectFill(_ value: Bool) {}
        func audioDelay(_ value: Duration) throws {}
        func subtitleDelay(_ value: Duration) throws {}
        func subtitleStyle(_ value: VLCSubtitleStyle) {}
        func shutdown() async -> Bool {
            true
        }
    }

    private func request() -> VLCPlaybackRequest {
        .init(
            url: URL(string: "https://localhost.invalid/private-fixture?api_key=secret")!,
            start: .zero, runtime: .seconds(900), live: false, subtitleURLs: [],
            subtitleStyle: .init(fontName: "system", colorRGB: nil, approximatePoints: 20)
        )
    }

    private func sample(
        _ tracker: inout VLCPassiveObservationTracker,
        displayed: UInt64? = nil, audio: UInt64? = nil, time: VLCNativeTimeObservation? = nil,
        now: UInt64 = 2_000_000_000
    ) -> [VLCPassiveObservation] {
        tracker.sample(
            frame: VLCPlaybackFrame(), statistics: .init(displayedPictures: displayed, playedAudioBuffers: audio),
            nativeTime: time, now: now
        )
    }

    func testMissingStatisticsRemainUnavailableAndMeasuredZeroIsDistinct() {
        var tracker = VLCPassiveObservationTracker(generation: UUID())
        let missing = tracker.sample(frame: .init(), statistics: nil, nativeTime: nil, now: 1)
        XCTAssertNil(missing.last?.statistics)
        XCTAssertNil(missing.last?.counterDelta)
        XCTAssertNil(missing.last?.positionSeconds)
        XCTAssertNil(missing.last?.nativeTime)
        let present = sample(&tracker, displayed: 0, audio: 0)
        XCTAssertEqual(present.last?.statistics?.displayedPictures, 0)
        XCTAssertNil(present.last?.statistics?.decodedVideo)
        XCTAssertNil(present.last?.counterDelta)
    }

    func testPositiveInitialCountersAreBaselineNotNewOutputAndSamplingContinues() {
        var tracker = VLCPassiveObservationTracker(generation: UUID())
        let initial = sample(&tracker, displayed: 100, audio: 200)
        XCTAssertFalse(initial.contains { $0.kind == .firstDisplayedPictureCounterObserved })
        XCTAssertFalse(initial.contains { $0.kind == .firstPlayedAudioBufferCounterObserved })
        let increment = sample(&tracker, displayed: 101, audio: 202)
        XCTAssertEqual(increment.filter { $0.kind == .firstDisplayedPictureCounterObserved }.count, 1)
        XCTAssertEqual(increment.filter { $0.kind == .firstPlayedAudioBufferCounterObserved }.count, 1)
        XCTAssertEqual(increment.first { $0.kind == .nativeCounterSample }?.counterDelta?.displayedPictures, 1)
        let sustained = sample(&tracker, displayed: 103, audio: 205)
        XCTAssertEqual(sustained.map(\.kind), [.nativeCounterSample])
        XCTAssertEqual(sustained.first?.counterDelta?.playedAudioBuffers, 3)
    }

    func testCounterResetCannotUnderflowOrBridgeEpochs() {
        var tracker = VLCPassiveObservationTracker(generation: UUID())
        _ = sample(&tracker, displayed: 100, audio: 200)
        let reset = sample(&tracker, displayed: 2, audio: 201)
        XCTAssertEqual(reset.map(\.kind), [.countersReset, .nativeCounterSample])
        XCTAssertEqual(reset.last?.counterEpoch, 1)
        XCTAssertNil(reset.last?.counterDelta)
        let resumed = sample(&tracker, displayed: 4, audio: 203)
        XCTAssertEqual(resumed.first?.counterDelta?.displayedPictures, 2)
    }

    func testStatisticsGapCannotCreateDeltaOrSettlePendingSeek() {
        var tracker = VLCPassiveObservationTracker(generation: UUID())
        _ = sample(&tracker, displayed: 20)
        _ = tracker.requestedSeek(
            id: UUID(), target: .seconds(100), frame: .init(), statistics: .init(displayedPictures: 20),
            nativeTime: nil, now: 1_000_000_000
        )
        let missing = tracker.sample(frame: .init(), statistics: nil, nativeTime: nil, now: 1_500_000_000)
        XCTAssertEqual(missing.map(\.kind), [.counterContinuityLost, .nativeCounterSample])
        let restored = sample(
            &tracker, displayed: 30,
            time: .init(sequence: 1, monotonicNanoseconds: 1_800_000_000, positionSeconds: 100)
        )
        XCTAssertNil(restored.last?.counterDelta)
        XCTAssertFalse(restored.contains { $0.kind == .seekSettledSupplementary })
    }

    func testSeekCannotSettleFromShadowClockOrUnqualifiedNativeClock() {
        var tracker = VLCPassiveObservationTracker(generation: UUID())
        _ = sample(&tracker, displayed: 20)
        let requestID = UUID()
        _ = tracker.requestedSeek(
            id: requestID, target: .seconds(100), frame: .init(), statistics: .init(displayedPictures: 20),
            nativeTime: .init(sequence: 4, monotonicNanoseconds: 900_000_000, positionSeconds: 10),
            now: 1_000_000_000
        )
        var shadow = VLCPlaybackFrame()
        shadow.time = .seconds(100)
        let noReceipt = tracker.sample(frame: shadow, statistics: .init(displayedPictures: 21), nativeTime: nil, now: 2_000_000_000)
        XCTAssertFalse(noReceipt.contains { $0.kind == .seekSettledSupplementary })
        for clock in [
            VLCNativeTimeObservation(sequence: 4, monotonicNanoseconds: 1_500_000_000, positionSeconds: 100),
            .init(sequence: 5, monotonicNanoseconds: 999_999_999, positionSeconds: 100),
            .init(sequence: 5, monotonicNanoseconds: 1_500_000_000, positionSeconds: 10),
            .init(sequence: 5, monotonicNanoseconds: 1_500_000_000, positionSeconds: .nan)
        ] {
            let unqualified = sample(&tracker, displayed: 22, time: clock)
            XCTAssertFalse(unqualified.contains { $0.kind == .seekSettledSupplementary })
        }
        let settled = sample(
            &tracker, displayed: 23,
            time: .init(sequence: 5, monotonicNanoseconds: 1_500_000_000, positionSeconds: 100.5)
        )
        XCTAssertEqual(settled.last?.kind, .seekSettledSupplementary)
        XCTAssertEqual(settled.last?.seekID, requestID)
        XCTAssertEqual(settled.last?.seekTargetSeconds, 100)
        XCTAssertEqual(settled.last?.nativeTime?.positionSeconds, 100.5)
        XCTAssertEqual(settled.last?.positionSeconds, 100.5)
        XCTAssertFalse(sample(&tracker, displayed: 24).contains { $0.kind == .seekSettledSupplementary })
    }

    func testPartialStatisticsLossBreaksContinuityAndCounterDeltas() {
        var tracker = VLCPassiveObservationTracker(generation: UUID())
        _ = sample(&tracker, displayed: 10, audio: 10)
        let missingAudio = sample(&tracker, displayed: 11)
        XCTAssertEqual(missingAudio.map(\.kind), [.counterContinuityLost, .nativeCounterSample])
        XCTAssertEqual(missingAudio.last?.counterEpoch, 1)
        XCTAssertNil(missingAudio.last?.counterDelta)
        XCTAssertNil(missingAudio.last?.statistics?.playedAudioBuffers)
    }

    func testSeekRequiresDisplayedIncrementAndAvailableBaseline() {
        for baseline: UInt64? in [nil, 20] {
            var tracker = VLCPassiveObservationTracker(generation: UUID())
            _ = tracker.requestedSeek(
                id: UUID(), target: .seconds(100), frame: .init(),
                statistics: baseline.map { .init(displayedPictures: $0) }, nativeTime: nil, now: 1_000_000_000
            )
            let records = sample(
                &tracker, displayed: baseline == nil ? 30 : 20,
                time: .init(sequence: 1, monotonicNanoseconds: 1_500_000_000, positionSeconds: 100)
            )
            XCTAssertFalse(records.contains { $0.kind == .seekSettledSupplementary })
        }
    }

    func testCounterResetInvalidatesSeekEvidenceAndTimeoutIsNotSuccess() {
        var tracker = VLCPassiveObservationTracker(generation: UUID())
        _ = sample(&tracker, displayed: 20)
        let id = UUID()
        _ = tracker.requestedSeek(
            id: id, target: .seconds(100), frame: .init(), statistics: .init(displayedPictures: 20),
            nativeTime: nil, now: 1_000_000_000
        )
        _ = sample(&tracker, displayed: 0)
        let reset = sample(
            &tracker, displayed: 30, time: .init(sequence: 1, monotonicNanoseconds: 2_000_000_000, positionSeconds: 100),
            now: 3_000_000_000
        )
        XCTAssertFalse(reset.contains { $0.kind == .seekSettledSupplementary })
        let timeout = sample(&tracker, displayed: 31, now: 11_000_000_000)
        XCTAssertEqual(timeout.last?.kind, .seekObservationTimedOut)
        XCTAssertEqual(timeout.last?.seekID, id)
        XCTAssertFalse(sample(&tracker, displayed: 32, now: 12_000_000_000).contains { $0.kind == .seekObservationTimedOut })
    }

    func testRetryHasFreshSeekIdentityAndPreservesRejectionAndSupersession() {
        var tracker = VLCPassiveObservationTracker(generation: UUID())
        let old = UUID(), retry = UUID()
        _ = tracker.requestedSeek(id: old, target: .seconds(10), frame: .init(), statistics: nil, nativeTime: nil, now: 1)
        let superseded = tracker.requestedSeek(id: retry, target: .seconds(20), frame: .init(), statistics: nil, nativeTime: nil, now: 2)
        XCTAssertEqual(superseded.map(\.kind), [.seekSuperseded, .seekRequested])
        XCTAssertEqual(superseded.first?.seekID, old)
        XCTAssertEqual(superseded.last?.seekID, retry)
        let rejected = tracker.rejectedSeek(frame: .init(), now: 3)
        XCTAssertEqual(rejected?.kind, .seekRejected)
        XCTAssertEqual(rejected?.seekID, retry)
        XCTAssertNil(tracker.rejectedSeek(frame: .init(), now: 4))
    }

    func testOptOutPerformsNoCounterReadsAndDetachingStopsSampling() async throws {
        let engine = Engine(), player = VLCPlaybackController(engine: engine), generation = UUID()
        player.open(request(), generation: generation)
        await Task.yield()
        player.samplePassiveObservations(generation: generation)
        XCTAssertEqual(engine.statisticsReads, 0)
        var observations: [VLCPassiveObservation] = []
        player.onPassiveObservation = { observations.append($0) }
        await Task.yield()
        player.samplePassiveObservations(generation: generation)
        XCTAssertGreaterThan(engine.statisticsReads, 0)
        player.onPassiveObservation = nil
        let reads = engine.statisticsReads, count = observations.count
        player.samplePassiveObservations(generation: generation)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(engine.statisticsReads, reads)
        XCTAssertEqual(observations.count, count)
        player.stop()
    }

    func testSamplerContinuesAfterFirstCountersAndStopsWithGeneration() async throws {
        let engine = Engine(), player = VLCPlaybackController(engine: engine), old = UUID(), current = UUID()
        var observations: [VLCPassiveObservation] = []
        player.onPassiveObservation = { observations.append($0) }
        engine.statistics = .init(displayedPictures: 0, playedAudioBuffers: 0)
        player.open(request(), generation: old)
        player.samplePassiveObservations(generation: old)
        engine.statistics = .init(displayedPictures: 1, playedAudioBuffers: 1)
        player.samplePassiveObservations(generation: old)
        let reads = engine.statisticsReads
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertGreaterThan(engine.statisticsReads, reads)
        player.open(request(), generation: current)
        observations.removeAll()
        let replacementReads = engine.statisticsReads
        player.samplePassiveObservations(generation: old)
        player.observed(.state, generation: old)
        XCTAssertEqual(engine.statisticsReads, replacementReads)
        XCTAssertTrue(observations.isEmpty)
        player.samplePassiveObservations(generation: current)
        XCTAssertTrue(observations.allSatisfy { $0.generation == current })
        player.stop()
        let stoppedCount = observations.count, stoppedReads = engine.statisticsReads
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(observations.count, stoppedCount)
        XCTAssertEqual(engine.statisticsReads, stoppedReads)
        XCTAssertEqual(observations.last?.terminalReason, .requestedStop)
    }

    func testSeekRejectionAndTerminalAreTypedAndPrivacySafeCodable() throws {
        let engine = Engine(), player = VLCPlaybackController(engine: engine), generation = UUID()
        var observations: [VLCPassiveObservation] = []
        player.onPassiveObservation = { observations.append($0) }
        player.open(request(), generation: generation)
        engine.frame.seekable = true
        engine.rejectSeek = true
        player.seek(.seconds(10))
        XCTAssertEqual(observations.suffix(2).map(\.kind), [.seekRequested, .seekRejected])
        XCTAssertEqual(observations.last?.seekID, observations.dropLast().last?.seekID)
        player.stop()
        let data = try JSONEncoder().encode(observations)
        XCTAssertEqual(try JSONDecoder().decode([VLCPassiveObservation].self, from: data), observations)
        let json = String(decoding: data, as: UTF8.self)
        for prohibited in ["localhost", "private-fixture", "api_key", "secret", "not emitted"] {
            XCTAssertFalse(json.contains(prohibited))
        }
        XCTAssertEqual(observations.last?.kind, .terminal)
        XCTAssertEqual(observations.last?.terminalReason, .requestedStop)
    }

    func testOpenRejectionTerminatesEvidenceAndDoesNotRestartOnObserverReplacement() async {
        let engine = Engine(), player = VLCPlaybackController(engine: engine)
        engine.rejectOpen = true
        var observations: [VLCPassiveObservation] = []
        player.onPassiveObservation = { observations.append($0) }
        player.open(request(), generation: UUID())
        XCTAssertEqual(observations.map(\.kind), [.observationStarted, .terminal])
        XCTAssertEqual(observations.last?.terminalReason, .openRejected)
        let readsAtRejection = engine.statisticsReads
        player.onPassiveObservation = { observations.append($0) }
        await Task.yield()
        XCTAssertEqual(engine.statisticsReads, readsAtRejection)
        player.stop()
    }
}
