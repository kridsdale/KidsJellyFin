//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import Foundation
import KidsDomain
@testable import KidsPlaybackSession
import Testing

@MainActor
private final class Driver: KidsPlaybackDriver {
    var frame = KidsPlaybackFrame()
    let subject = PassthroughSubject<KidsPlaybackDriverEvent, Never>()
    var events: AnyPublisher<KidsPlaybackDriverEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    var starts = 0
    var reports = 0
    var pauses = 0
    var stops = 0
    var toggles = 0
    var stopWait: (@MainActor () async -> Void)?
    var seeks: [Double] = []
    func start() {
        starts += 1
        subject.send(.updated)
    }

    func beginReporting() {
        reports += 1
    }

    func togglePlayPause() {
        toggles += 1
    }

    func pause() {
        pauses += 1
    }

    func seek(seconds: Double) {
        seeks.append(seconds)
    }

    func stop() async {
        stops += 1
        await stopWait?()
    }

    func advance(_ seconds: Double, output: Int = 1) {
        frame.seconds = seconds
        frame.playing = true
        frame.displayedPictures = output
        subject.send(.updated)
    }
}

@MainActor
private final class Delegate: KidsPlaybackSessionDelegate {
    let isPreview = false
    var began = 0
    var checkpoints: [Double] = []
    var completions = 0
    var continuations = 0
    var stopRequests = 0
    var stopOrigins: [ObjectIdentifier] = []
    var retries: [Double] = []
    var failures: [KidsPlaybackFailure] = []
    func playbackBegan(_ session: KidsPlaybackController) {
        began += 1
    }

    func playbackCheckpoint(_ session: KidsPlaybackController, seconds: Double) {
        checkpoints.append(seconds)
    }

    func completed(_ session: KidsPlaybackController) async {
        completions += 1
    }

    func continuePlayback(_ session: KidsPlaybackController) async {
        continuations += 1
    }

    func stopPlaybackFromSession(_ session: KidsPlaybackController) async {
        stopRequests += 1
        stopOrigins.append(ObjectIdentifier(session))
    }

    func retryPlayback(_ session: KidsPlaybackController, position: Double) {
        retries.append(position)
    }

    func playbackFailed(_ session: KidsPlaybackController, error: KidsPlaybackFailure) {
        failures.append(error)
    }
}

@MainActor
private final class Fixture {
    let driver = Driver()
    let delegate = Delegate()
    var date = Date(timeIntervalSince1970: 1000)
    lazy var session = KidsPlaybackController(
        item: item,
        title: item,
        mode: .movie,
        position: 120,
        episodes: [],
        driver: driver,
        delegate: delegate,
        now: { [unowned self] in self.date }
    )
    let item = KidsItem(id: "approved-movie", name: "Movie", kind: .movie, libraryID: "kids-movies", runtime: 300)
}

@Test @MainActor
func `reports begin only after decoded output beyond durable resume`() async {
    let f = Fixture()
    f.session.start()
    f.driver.advance(120.5, output: 0)
    #expect(f.delegate.began == 0)
    f.driver.advance(120.5)
    f.driver.advance(121)
    #expect(f.delegate.began == 1)
    #expect(f.driver.reports == 1)
    await f.session.stop()
}

@Test @MainActor
func `host resume admission does not change paused transport before approval`() async {
    let f = Fixture()
    f.driver.frame.paused = true
    var requests: [UUID] = []
    f.session.onResumeRequested = { requests.append($0.id) }
    f.session.toggle()
    #expect(requests == [f.session.id])
    #expect(f.driver.toggles == 0)
    #expect(f.driver.frame.paused)
    #expect(f.delegate.began == 0)
    await f.session.stop()
    f.session.toggle()
    #expect(requests == [f.session.id])
    #expect(f.driver.toggles == 0)
}

@Test @MainActor
func `resume admission preserves unconfigured transport and ordinary pause requests`() async {
    let f = Fixture()
    f.driver.frame.paused = true
    f.session.toggle()
    #expect(f.driver.toggles == 1)
    var admissionRequests = 0
    f.session.onResumeRequested = { _ in admissionRequests += 1 }
    f.driver.frame.paused = false
    f.session.toggle()
    #expect(f.driver.toggles == 2)
    #expect(admissionRequests == 0)
    await f.session.stop()
}

@Test @MainActor
func `failed open retry retains durable requested position`() async {
    let f = Fixture()
    f.session.start()
    f.driver.frame.terminal = true
    f.driver.frame.seconds = 0
    f.driver.frame.failed = true
    f.driver.subject.send(.updated)
    #expect(f.session.failed && f.session.recovery)
    await f.session.retry()
    #expect(f.delegate.retries == [120])
    #expect(f.delegate.checkpoints.last == 120)
    #expect(f.driver.stops == 1)
}

@Test @MainActor
func `seek requires pause and clamps runtime without accepting nonfinite input`() async {
    let f = Fixture()
    f.session.start()
    f.driver.advance(121)
    f.driver.frame.seekable = true
    f.session.seek(15)
    #expect(f.driver.seeks.isEmpty)
    f.driver.frame.paused = true
    f.driver.subject.send(.updated)
    f.session.seek(.infinity)
    f.session.seek(1000)
    f.session.seek(-1000)
    #expect(f.driver.seeks == [300, 0])
    await f.session.stop()
}

@Test @MainActor
func `terminal clock does not overwrite checkpoint and stop is idempotent`() async {
    let f = Fixture()
    f.session.start()
    f.driver.advance(200)
    f.driver.frame.terminal = true
    f.driver.frame.seconds = 0
    f.driver.subject.send(.updated)
    #expect(f.session.seconds == 200)
    await f.session.stop()
    await f.session.stop()
    #expect(f.driver.stops == 1)
    #expect(f.delegate.checkpoints.last == 200)
    f.driver.subject.send(.failure(.authentication))
    #expect(f.delegate.failures.isEmpty)
}

@Test @MainActor
func `natural end requires began and is delivered only once`() async {
    let f = Fixture()
    f.session.start()
    f.driver.subject.send(.naturalEnd)
    await Task.yield()
    #expect(f.delegate.completions == 0)
    f.driver.advance(121)
    f.driver.subject.send(.naturalEnd)
    f.driver.subject.send(.naturalEnd)
    for _ in 0 ..< 10 {
        await Task.yield()
    }
    #expect(f.delegate.completions == 1)
    await f.session.stop()
}

@Test @MainActor
func `stalled buffering recovers after fifteen seconds`() async {
    let f = Fixture()
    f.session.start()
    await f.session.tick()
    f.date += 14
    await f.session.tick()
    #expect(!f.session.recovery)
    f.date += 1
    await f.session.tick()
    #expect(f.session.recovery)
    #expect(f.driver.pauses == 1)
    await f.session.stop()
}

@Test @MainActor
func `countdown survives native stop and requests one next item`() async {
    let f = Fixture()
    f.session.start()
    f.driver.advance(121)
    f.session.showCountdown = true
    f.session.countdown = 10
    await f.session.stop()
    for _ in 0 ..< 10 {
        await f.session.tick()
    }
    #expect(f.delegate.continuations == 1)
    #expect(f.driver.stops == 1)
}

@Test @MainActor
func `failure classification and background checkpoint reach application port`() async {
    let f = Fixture()
    f.session.start()
    f.driver.advance(190)
    f.driver.subject.send(.failure(.authentication))
    f.session.pauseOnBackground()
    #expect(f.delegate.failures == [.authentication])
    #expect(f.delegate.checkpoints.last == 190)
    #expect(f.driver.pauses == 1)
    await f.session.stop()
}

@Test @MainActor
func `back hides controls before requesting application stop`() async {
    let f = Fixture()
    f.session.start()
    f.driver.advance(121)
    f.session.reveal()
    await f.session.handleBack()
    #expect(!f.session.controlsVisible)
    #expect(f.delegate.stopRequests == 0)
    await f.session.handleBack()
    #expect(f.delegate.stopRequests == 1)
    await f.session.stop()
}

@MainActor
struct SessionStopOriginContract {
    @Test
    func `back request identifies exactly the controller that originated it`() async {
        let fixture = Fixture()
        fixture.session.controlsVisible = false
        await fixture.session.handleBack()
        #expect(fixture.delegate.stopRequests == 1)
        #expect(fixture.delegate.stopOrigins == [ObjectIdentifier(fixture.session)])
    }
}

@Test @MainActor
func `overlapping stops both wait for one native teardown`() async {
    let fixture = Fixture()
    let entered = AsyncStream<Void>.makeStream()
    let resume = AsyncStream<Void>.makeStream()
    let secondEntered = AsyncStream<Void>.makeStream()
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
    var secondFinished = false
    let second = Task { @MainActor in
        secondEntered.continuation.yield(())
        await fixture.session.stop()
        secondFinished = true
    }
    for await _ in secondEntered.stream {
        break
    }
    #expect(!secondFinished && fixture.driver.stops == 1)
    resume.continuation.yield(())
    await first.value
    await second.value
    #expect(secondFinished && fixture.driver.stops == 1 && fixture.driver.pauses == 1)
    entered.continuation.finish()
    resume.continuation.finish()
    secondEntered.continuation.finish()
}

@Test @MainActor
func `starting is idempotent and a retired session cannot restart its driver`() async {
    let fixture = Fixture()
    fixture.session.start()
    fixture.session.start()
    #expect(fixture.driver.starts == 1)
    fixture.driver.advance(121)
    #expect(fixture.driver.reports == 1 && fixture.delegate.began == 1)
    await fixture.session.stop()
    fixture.session.start()
    fixture.driver.subject.send(.failure(.stream))
    #expect(fixture.driver.starts == 1 && fixture.driver.stops == 1)
    #expect(fixture.delegate.failures.isEmpty)
}
