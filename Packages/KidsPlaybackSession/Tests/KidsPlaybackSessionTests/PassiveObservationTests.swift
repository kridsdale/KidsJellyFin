//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

// SPDX-License-Identifier: MPL-2.0
import Combine
import Foundation
import KidsDomain
@testable import KidsPlaybackSession
import Testing

@MainActor
private final class PassiveDriver: KidsPlaybackDriver {
    var frame = KidsPlaybackFrame()
    let subject = PassthroughSubject<KidsPlaybackDriverEvent, Never>()
    var events: AnyPublisher<KidsPlaybackDriverEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    var starts = 0
    var reports = 0
    var stops = 0
    var seeks: [Double] = []
    var action: ((String) -> Void)?
    var stopWait: (@MainActor () async -> Void)?
    func start() {
        action?("start")
        starts += 1
        subject.send(.updated)
    }

    func beginReporting() {
        action?("reporting")
        reports += 1
    }

    func togglePlayPause() {
        action?("toggle")
    }

    func pause() {
        action?("pause")
    }

    func seek(seconds: Double) {
        action?("seek")
        seeks.append(seconds)
    }

    func stop() async {
        action?("stop")
        stops += 1
        await stopWait?()
        action?("drained")
    }

    func advance(_ position: Double, output: Int = 1) {
        frame.seconds = position
        frame.playing = true
        frame.displayedPictures = output
        subject.send(.updated)
    }
}

@MainActor
private final class PassiveDelegate: KidsPlaybackSessionDelegate {
    let isPreview = false
    var failures: [KidsPlaybackFailure] = []
    func playbackBegan(_ session: KidsPlaybackController) {}
    func playbackCheckpoint(_ session: KidsPlaybackController, seconds: Double) {}
    func completed(_ session: KidsPlaybackController) async {}
    func continuePlayback(_ session: KidsPlaybackController) async {}
    func stopPlaybackFromSession(_ session: KidsPlaybackController) async {}
    func retryPlayback(_ session: KidsPlaybackController, position: Double) {}
    func playbackFailed(_ session: KidsPlaybackController, error: KidsPlaybackFailure) {
        failures.append(error)
    }
}

@MainActor
private final class PassiveFixture {
    let driver = PassiveDriver()
    let delegate = PassiveDelegate()
    var clockReads = 0
    var date = Date(timeIntervalSince1970: 1000)
    var observations: [KidsSessionObservation] = []
    var timeline: [String] = []
    lazy var session = KidsPlaybackController(
        item: KidsItem(id: "fixture", name: "Fixture", kind: .movie, libraryID: "fixture", runtime: 300),
        title: KidsItem(id: "fixture", name: "Fixture", kind: .movie, libraryID: "fixture", runtime: 300),
        mode: .movie,
        position: 120,
        episodes: [],
        driver: driver,
        delegate: delegate,
        now: { [unowned self] in self.date },
        monotonicNow: { [unowned self] in
            self.clockReads += 1
            return UInt64(self.clockReads) * 10
        }
    )

    func enable() {
        session.onPassiveObservation = { [unowned self] in
            self.observations.append($0)
            self.timeline.append("event:\($0.kind.rawValue)")
        }
        driver.action = { [unowned self] in self.timeline.append("driver:\($0)") }
    }

    var kinds: [KidsSessionObservation.Kind] {
        observations.map(\.kind)
    }
}

@Test @MainActor
func `disabled observations never read the monotonic clock or change driver behavior`() async {
    let fixture = PassiveFixture()
    #expect(fixture.session.onPassiveObservation == nil)
    fixture.session.start()
    fixture.driver.advance(121)
    fixture.driver.frame.paused = true
    fixture.driver.frame.seekable = true
    fixture.driver.subject.send(.updated)
    fixture.session.seek(15)
    await fixture.session.stop()
    #expect(fixture.clockReads == 0)
    #expect(fixture.driver.starts == 1 && fixture.driver.reports == 1 && fixture.driver.stops == 1)
    #expect(fixture.driver.seeks == [136])
    #expect(fixture.session.seconds == 136)
}

@Test @MainActor
func `session and readiness observations precede the corresponding driver actions`() async throws {
    let fixture = PassiveFixture()
    fixture.enable()
    fixture.session.start()
    fixture.session.start()
    #expect(fixture.timeline.prefix(2) == ["event:session_start", "driver:start"])
    fixture.driver.advance(120.5, output: 0)
    #expect(!fixture.kinds.contains(.readinessObserved))
    fixture.driver.advance(120.5)
    fixture.driver.advance(121)
    let readinessIndex = try #require(fixture.timeline.firstIndex(of: "event:readiness_observed"))
    #expect(fixture.timeline[readinessIndex + 1] == "driver:reporting")
    #expect(fixture.kinds.filter { $0 == .sessionStart }.count == 1)
    #expect(fixture.kinds.filter { $0 == .readinessObserved }.count == 1)
    #expect(fixture.observations.allSatisfy { $0.sessionID == fixture.session.id })
    #expect(fixture.observations.map(\.monotonicNS) == (1 ... fixture.clockReads).map { UInt64($0) * 10 })
    await fixture.session.stop()
}

@Test @MainActor
func `optimistic seek emits a request before dispatch and never a completed seek`() async throws {
    let fixture = PassiveFixture()
    fixture.enable()
    fixture.session.start()
    fixture.driver.advance(121)
    fixture.driver.frame.paused = true
    fixture.driver.frame.seekable = true
    fixture.driver.subject.send(.updated)
    let before = fixture.observations.count
    fixture.session.seek(.infinity)
    #expect(fixture.observations.count == before)
    fixture.session.seek(15)
    #expect(Array(fixture.timeline.suffix(2)) == ["event:seek_requested", "driver:seek"])
    let request = try #require(fixture.observations.last)
    #expect(request.kind == .seekRequested)
    #expect(request.positionSeconds == 121 && request.requestedSeekTargetSeconds == 136)
    #expect(fixture.session.seconds == 136 && fixture.driver.frame.seconds == 121)
    fixture.driver.advance(136)
    #expect(Array(fixture.kinds.dropFirst(before)) == [.seekRequested])
    await fixture.session.stop()
}

@Test @MainActor
func `actual transport and buffering changes are deduplicated while commands remain requests`() async {
    let fixture = PassiveFixture()
    fixture.enable()
    fixture.session.start()
    fixture.driver.advance(121)
    let beforeCommands = fixture.observations.count
    fixture.session.toggle()
    fixture.session.pauseOnBackground()
    #expect(fixture.observations.count == beforeCommands)
    fixture.driver.frame.paused = true
    fixture.driver.subject.send(.transport(paused: true, seconds: 121, terminal: false))
    fixture.driver.subject.send(.updated)
    fixture.driver.subject.send(.updated)
    #expect(fixture.kinds.filter { $0 == .transportPausedObserved }.count == 1)
    fixture.driver.frame.paused = false
    fixture.driver.subject.send(.transport(paused: false, seconds: 122, terminal: false))
    fixture.driver.subject.send(.updated)
    #expect(fixture.kinds.filter { $0 == .transportResumedObserved }.count == 2)
    fixture.driver.frame.buffering = true
    fixture.driver.subject.send(.updated)
    fixture.driver.subject.send(.updated)
    await fixture.session.tick()
    fixture.date += 15
    await fixture.session.tick()
    await fixture.session.tick()
    #expect(fixture.kinds.filter { $0 == .bufferingStartedObserved }.count == 2)
    #expect(fixture.kinds.filter { $0 == .recoveryEntered }.count == 1)
    await fixture.session.stop()
}

@Test @MainActor
func `early native end is supplementary and failure observations preserve fixed classifications`() async {
    let fixture = PassiveFixture()
    fixture.enable()
    fixture.session.start()
    fixture.driver.subject.send(.naturalEnd)
    fixture.driver.subject.send(.naturalEnd)
    #expect(fixture.kinds.filter { $0 == .nativeEndObserved }.count == 1)
    #expect(!fixture.kinds.contains(.readinessObserved))
    fixture.driver.frame.failed = true
    fixture.driver.frame.terminal = true
    fixture.driver.subject.send(.updated)
    fixture.driver.subject.send(.updated)
    fixture.driver.subject.send(.failure(.authentication))
    fixture.driver.subject.send(.failure(.stream))
    #expect(!fixture.kinds.contains(.readinessObserved))
    #expect(fixture.observations.compactMap(\.failure) == [.nativeFrame, .authentication, .stream])
    #expect(fixture.kinds.filter { $0 == .recoveryEntered }.count == 1)
    #expect(fixture.delegate.failures.count == 2)
    await fixture.session.stop()
    let retiredCount = fixture.observations.count
    fixture.driver.subject.send(.updated)
    fixture.driver.subject.send(.transport(paused: false, seconds: 200, terminal: false))
    fixture.driver.subject.send(.failure(.stream))
    fixture.driver.subject.send(.naturalEnd)
    fixture.session.start()
    #expect(fixture.observations.count == retiredCount)
}

@Test @MainActor
func `native end and overlapping stop stages emit once and complete only after drain`() async throws {
    let fixture = PassiveFixture()
    fixture.enable()
    fixture.session.start()
    fixture.driver.advance(121)
    fixture.driver.subject.send(.naturalEnd)
    fixture.driver.subject.send(.naturalEnd)
    #expect(fixture.kinds.filter { $0 == .nativeEndObserved }.count == 1)
    fixture.driver.subject.send(.failure(.stream))
    #expect(fixture.observations.last?.kind == .failureObserved)
    #expect(fixture.observations.last?.failure == .stream)
    let entered = AsyncStream<Void>.makeStream()
    let resume = AsyncStream<Void>.makeStream()
    fixture.driver.stopWait = {
        entered.continuation.yield(())
        for await _ in resume.stream {
            break
        }
    }
    let first = Task { await fixture.session.stop() }
    for await _ in entered.stream {
        break
    }
    #expect(fixture.kinds.last == .stopRequested)
    let second = Task { await fixture.session.stop() }
    await Task.yield()
    #expect(!fixture.kinds.contains(.driverDrained) && !fixture.kinds.contains(.stopCompleted))
    first.cancel()
    resume.continuation.yield(())
    await first.value
    await second.value
    await fixture.session.stop()
    #expect(Array(fixture.kinds.suffix(3)) == [.stopRequested, .driverDrained, .stopCompleted])
    #expect(fixture.kinds.filter { $0 == .stopRequested }.count == 1)
    // Keep the rethrows call outside #expect: Swift Testing's key-path macro
    // expansion currently introduces a throwing function parameter.
    let cancelledTerminalStages = fixture.observations.suffix(2).allSatisfy(\.cancellationRequested)
    #expect(cancelledTerminalStages)
    #expect(try #require(fixture.timeline.firstIndex(of: "driver:drained")) < fixture.timeline.firstIndex(of: "event:driver_drained")!)
    #expect(fixture.driver.stops == 1)
    entered.continuation.finish()
    resume.continuation.finish()
}

@Test
func `observation envelope omits nonfinite positions and round trips fixed fields`() throws {
    let observation = KidsSessionObservation(
        sessionID: UUID(),
        kind: .seekRequested,
        monotonicNS: 123,
        positionSeconds: .nan,
        requestedSeekTargetSeconds: .infinity
    )
    #expect(observation.positionSeconds == nil && observation.requestedSeekTargetSeconds == nil)
    let data = try JSONEncoder().encode(observation)
    #expect(try JSONDecoder().decode(KidsSessionObservation.self, from: data) == observation)
    let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(fields.keys) == ["sessionID", "kind", "monotonicNS", "cancellationRequested"])
    #expect(fields["kind"] as? String == "seek_requested")
}
